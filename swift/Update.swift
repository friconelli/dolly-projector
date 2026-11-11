import Foundation
import AppKit
import CryptoKit

/// Un singolo tentativo di scarico: scrive sul file parziale man mano che arrivano i dati e, se il file esiste già, chiede solo il resto (Range).
final class Downloader: NSObject, URLSessionDataDelegate {
    enum Outcome { case done(Int64), retry(Error, Int64), fatal(Error) }
    let url: URL, part: String; var got: Int64; var total: Int64; let onProgress: (Int64, Int64) -> Void
    private var fh: FileHandle?, outcome: Outcome?, status = 0; private let sem = DispatchSemaphore(value: 0)
    private var lastReport = Date.distantPast
    init(url: URL, part: String, have: Int64, total: Int64, onProgress: @escaping (Int64, Int64) -> Void) { self.url = url; self.part = part; got = have; self.total = total; self.onProgress = onProgress }
    func run() -> Outcome {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60          // 60 s senza ricevere nemmeno un byte prima di arrendersi (rete lentissima ma viva)
        c.timeoutIntervalForResource = 6 * 3600   // l'intero scarico può durare ore
        c.waitsForConnectivity = true; c.networkServiceType = .background
        let s = URLSession(configuration: c, delegate: self, delegateQueue: nil)
        var rq = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        rq.setValue("DollyProjector/\(Updater.current)", forHTTPHeaderField: "User-Agent")
        if got > 0 { rq.setValue("bytes=\(got)-", forHTTPHeaderField: "Range"); rq.setValue("identity", forHTTPHeaderField: "Accept-Encoding") }
        s.dataTask(with: rq).resume(); onProgress(got, total)
        sem.wait(); try? fh?.close(); s.finishTasksAndInvalidate()
        return outcome ?? .retry(DollyError(tr("nessuna risposta")), total)
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let h = r as? HTTPURLResponse; status = h?.statusCode ?? 0
        switch status {
        case 206:   // riprende da dove era arrivato; Content-Range: bytes A-B/TOTALE
            if let cr = h?.value(forHTTPHeaderField: "Content-Range"), let t = cr.split(separator: "/").last.flatMap({ Int64($0) }) { total = t }
        case 200:   // il server ignora Range (o è il primo tentativo): si riparte da zero
            got = 0; total = r.expectedContentLength > 0 ? r.expectedContentLength : total; try? FileManager.default.removeItem(atPath: part)
        case 416:   // la parte che ho non combacia: da capo
            try? FileManager.default.removeItem(atPath: part); outcome = .retry(DollyError("HTTP 416"), 0); completionHandler(.cancel); sem.signal(); return
        case 500...599, 408, 429: outcome = .retry(DollyError("HTTP \(status)"), total); completionHandler(.cancel); sem.signal(); return
        default: outcome = .fatal(DollyError(trf("il sito ha risposto con errore %d", status))); completionHandler(.cancel); sem.signal(); return
        }
        if !FileManager.default.fileExists(atPath: part) { FileManager.default.createFile(atPath: part, contents: nil) }
        fh = FileHandle(forWritingAtPath: part); _ = try? fh?.seekToEnd()
        completionHandler(.allow)
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        fh?.write(data); got += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.1 { lastReport = Date(); onProgress(got, total) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        if outcome == nil {
            if let e = e { outcome = .retry(e, total) }
            else if total > 0 && got < total { outcome = .retry(DollyError(tr("connessione interrotta")), total) }
            else { onProgress(got, total); outcome = .done(total) }
        }
        sem.signal()
    }
}

/// Aggiornamento dell'app dal menu: legge version.json dal sito, confronta la versione, scarica lo zip, ne verifica lo SHA-256 e l'identità, poi sostituisce l'app e la riapre.
/// Contatta il sito solo quando l'utente sceglie "Controlla aggiornamenti…" (nessun controllo automatico in background).
struct UpdateInfo { let version: String, url: URL, sha256: String, bytes: Int, notes: String }

enum Updater {
    static var infoURL: URL { URL(string: ProcessInfo.processInfo.environment["DOLLY_UPDATE_URL"] ?? "https://www.dollyprojector.app/version.json")! }
    static var current: String { ProcessInfo.processInfo.environment["DOLLY_VERSION"] ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }   // (DOLLY_VERSION solo per i collaudi)

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
        return false
    }
    static func fetch() throws -> UpdateInfo {
        var rq = URLRequest(url: infoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        rq.setValue("DollyProjector/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try sync(rq)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let v = o["version"] as? String, let u = (o["url"] as? String).flatMap(URL.init(string:)), let h = o["sha256"] as? String, u.scheme == "https" || u.isFileURL || u.host == "127.0.0.1"
        else { throw DollyError(tr("risposta del sito non valida")) }
        return UpdateInfo(version: v, url: u, sha256: h.lowercased(), bytes: o["bytes"] as? Int ?? 0, notes: o["notes"] as? String ?? "")
    }
    private static func sync(_ rq: URLRequest) throws -> (Data, URLResponse) {
        var out: (Data, URLResponse)?, err: Error?; let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: rq) { d, r, e in if let d = d, let r = r { out = (d, r) } else { err = e ?? DollyError(tr("nessuna risposta")) }; sem.signal() }.resume()
        sem.wait(); if let o = out { return o }; throw err!
    }
    /// Avanzamento: byte scaricati, byte totali (0 se ignoti), numero del tentativo (1 = primo), pausa in secondi prima del prossimo tentativo (0 = in corso).
    typealias Progress = (_ got: Int64, _ total: Int64, _ attempt: Int, _ retryIn: Int) -> Void
    /// Scarica lo zip in un file parziale, riprendendo da dove si è interrotto (Range) a ogni errore di rete, con timeout lunghi e fino a 12 tentativi. Poi controlla lo SHA-256, lo apre e verifica che dentro ci sia davvero Dolly Projector alla versione annunciata. Ritorna il percorso della nuova app.
    static func download(_ i: UpdateInfo, progress: Progress? = nil) throws -> String {
        let dir = NSTemporaryDirectory() + "dolly-update-\(getpid())"; try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let part = dir + "/app.zip.part", zip = URL(fileURLWithPath: dir + "/app.zip")
        let maxAttempts = Int(ProcessInfo.processInfo.environment["DOLLY_UPDATE_RETRIES"] ?? "") ?? 12
        var attempt = 0, lastError: Error = DollyError(tr("download non riuscito")), total = Int64(i.bytes)
        while attempt < maxAttempts {
            attempt += 1
            let have = (try? FileManager.default.attributesOfItem(atPath: part)[.size] as? Int64) ?? 0
            if total > 0 && have == total { break }   // già tutto
            let d = Downloader(url: i.url, part: part, have: have, total: total) { g, t in progress?(g, t, attempt, 0) }
            switch d.run() {
            case .done(let t): if t > 0 { total = t }; lastError = DollyError(""); attempt = maxAttempts + 1   // finito
            case .retry(let e, let t): lastError = e; if t > 0 { total = t }
                if attempt < maxAttempts { for left in stride(from: min(15, 2 * attempt), to: 0, by: -1) { progress?(d.got, total, attempt + 1, left); Thread.sleep(forTimeInterval: 1) } }
            case .fatal(let e): throw e
            }
        }
        guard attempt > maxAttempts else { throw DollyError(trf("download non riuscito dopo %d tentativi (%@)", maxAttempts, "\(lastError)")) }
        try? FileManager.default.removeItem(at: zip); try FileManager.default.moveItem(atPath: part, toPath: zip.path)
        let h = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard h == i.sha256 else { throw DollyError(tr("il file scaricato non corrisponde (SHA-256 diverso): aggiornamento annullato")) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip.path, dir + "/x"]; try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, let app = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/x"))?.first(where: { $0.hasSuffix(".app") }) else { throw DollyError(tr("archivio non valido")) }
        let path = dir + "/x/" + app
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        guard info?["CFBundleIdentifier"] as? String == "app.dollyprojector.Dolly", info?["CFBundleShortVersionString"] as? String == i.version else { throw DollyError(trf("l'archivio non contiene Dolly Projector %@", i.version)) }
        return path
    }
    /// Sostituisce l'app in esecuzione dopo la sua chiusura e la riapre. Se la cartella non è scrivibile, apre la nuova app dove si trova.
    static func installAndRelaunch(newApp: String) {
        let dest = Bundle.main.bundlePath, pid = getpid()
        let writable = FileManager.default.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent)
        let script = writable
            ? "while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done; rm -rf \"$2\" && ditto \"$1\" \"$2\" && open \"$2\" || open \"$1\""
            : "while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done; open \"$1\""
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script, "sh", newApp, dest]
        try? p.run()
    }
}

extension AppDelegate {
    @objc func checkForUpdates(_ sender: Any?) {
        DispatchQueue.global().async {
            let r = Result { try Updater.fetch() }
            DispatchQueue.main.async {
                switch r {
                case .failure(let e): self.updateAlert(tr("Non riesco a controllare gli aggiornamenti"), trf("Verifica la connessione a internet.\n(%@)", "\(e)"))
                case .success(let i):
                    guard Updater.isNewer(i.version, than: Updater.current) else { self.updateAlert(tr("Dolly Projector è aggiornato"), trf("Hai già l'ultima versione (%@).", Updater.current)); return }
                    let busy = (self.model.engine?.snap.mode ?? "idle") != "idle"
                    let a = NSAlert(); a.messageText = trf("È disponibile la versione %@", i.version)
                    a.informativeText = trf("Hai la %@. %@%@L'app viene scaricata (%d MB), controllata e riaperta.", Updater.current, i.notes, i.notes.isEmpty ? "" : "\n\n", i.bytes / 1_000_000)
                        + (busy ? tr("\n\n⚠︎ È in corso una proiezione: aggiornare la interromperà.") : "")
                    a.addButton(withTitle: tr("Aggiorna e riavvia")); a.addButton(withTitle: tr("Più tardi"))
                    if a.runModal() == .alertFirstButtonReturn { self.applyUpdate(i) }
                }
            }
        }
    }
    func applyUpdate(_ i: UpdateInfo) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = tr("Aggiornamento")
        let l = NSTextField(labelWithString: trf("Scarico Dolly Projector %@…", i.version)); l.frame = NSRect(x: 24, y: 80, width: 332, height: 20); l.font = .systemFont(ofSize: 13, weight: .semibold)
        let bar = NSProgressIndicator(frame: NSRect(x: 24, y: 56, width: 332, height: 16)); bar.style = .bar; bar.isIndeterminate = true; bar.minValue = 0; bar.maxValue = 1; bar.startAnimation(nil)
        let pct = NSTextField(labelWithString: "0%"); pct.frame = NSRect(x: 24, y: 30, width: 80, height: 18); pct.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let mb = NSTextField(labelWithString: ""); mb.frame = NSRect(x: 104, y: 30, width: 252, height: 18); mb.alignment = .right; mb.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); mb.textColor = .secondaryLabelColor
        let st = NSTextField(labelWithString: ""); st.frame = NSRect(x: 24, y: 8, width: 332, height: 16); st.font = .systemFont(ofSize: 11); st.textColor = .secondaryLabelColor
        for v in [l, bar, pct, mb, st] as [NSView] { w.contentView?.addSubview(v) }
        w.center(); w.makeKeyAndOrderFront(nil)
        DispatchQueue.global().async {
            let r = Result { try Updater.download(i) { got, total, attempt, retryIn in
                DispatchQueue.main.async {
                    func m(_ b: Int64) -> String { String(format: "%.1f", Double(b) / 1_000_000) }
                    if total > 0 {
                        bar.isIndeterminate = false; bar.doubleValue = min(1, Double(got) / Double(total))
                        pct.stringValue = "\(Int(min(100, Double(got) * 100 / Double(total))))%"
                        mb.stringValue = trf("%@ MB scaricati · %@ MB mancanti", m(got), m(max(0, total - got)))
                    } else { pct.stringValue = ""; mb.stringValue = trf("%@ MB scaricati", m(got)) }
                    st.stringValue = retryIn > 0 ? trf("Connessione debole: nuovo tentativo %d tra %d s (riprende da dove era arrivato)", attempt, retryIn) : (attempt > 1 ? trf("Tentativo %d: riprende da dove era arrivato", attempt) : "")
                } } }
            DispatchQueue.main.async {
                w.close()
                switch r {
                case .failure(let e): self.updateAlert(tr("Aggiornamento non riuscito"), "\(e)")
                case .success(let path): self.stopEngine(); Updater.installAndRelaunch(newApp: path); NSApp.terminate(nil)
                }
            }
        }
    }
    func updateAlert(_ t: String, _ m: String) { let a = NSAlert(); a.messageText = t; a.informativeText = m; a.runModal() }
}
