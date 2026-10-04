import Foundation
import AppKit
import CryptoKit

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
        else { throw DollyError("risposta del sito non valida") }
        return UpdateInfo(version: v, url: u, sha256: h.lowercased(), bytes: o["bytes"] as? Int ?? 0, notes: o["notes"] as? String ?? "")
    }
    private static func sync(_ rq: URLRequest) throws -> (Data, URLResponse) {
        var out: (Data, URLResponse)?, err: Error?; let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: rq) { d, r, e in if let d = d, let r = r { out = (d, r) } else { err = e ?? DollyError("nessuna risposta") }; sem.signal() }.resume()
        sem.wait(); if let o = out { return o }; throw err!
    }
    /// Scarica lo zip, controlla lo SHA-256, lo apre e verifica che dentro ci sia davvero Dolly Projector alla versione annunciata. Ritorna il percorso della nuova app.
    static func download(_ i: UpdateInfo) throws -> String {
        let dir = NSTemporaryDirectory() + "dolly-update-\(getpid())"; try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var got: URL?, err: Error?; let sem = DispatchSemaphore(value: 0)
        URLSession.shared.downloadTask(with: i.url) { u, r, e in
            if let u = u, (r as? HTTPURLResponse)?.statusCode ?? 200 == 200 { let d = URL(fileURLWithPath: dir + "/app.zip"); try? FileManager.default.moveItem(at: u, to: d); got = d } else { err = e ?? DollyError("download non riuscito") }
            sem.signal() }.resume()
        sem.wait(); guard let zip = got else { throw err! }
        let h = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard h == i.sha256 else { throw DollyError("il file scaricato non corrisponde (SHA-256 diverso): aggiornamento annullato") }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip.path, dir + "/x"]; try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, let app = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/x"))?.first(where: { $0.hasSuffix(".app") }) else { throw DollyError("archivio non valido") }
        let path = dir + "/x/" + app
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        guard info?["CFBundleIdentifier"] as? String == "app.dollyprojector.Dolly", info?["CFBundleShortVersionString"] as? String == i.version else { throw DollyError("l'archivio non contiene Dolly Projector \(i.version)") }
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
                case .failure(let e): self.updateAlert("Non riesco a controllare gli aggiornamenti", "Verifica la connessione a internet.\n(\(e))")
                case .success(let i):
                    guard Updater.isNewer(i.version, than: Updater.current) else { self.updateAlert("Dolly Projector è aggiornato", "Hai già l'ultima versione (\(Updater.current))."); return }
                    let busy = (self.model.engine?.snap.mode ?? "idle") != "idle"
                    let a = NSAlert(); a.messageText = "È disponibile la versione \(i.version)"
                    a.informativeText = "Hai la \(Updater.current). \(i.notes)\(i.notes.isEmpty ? "" : "\n\n")L'app viene scaricata (\(i.bytes / 1_000_000) MB), controllata e riaperta."
                        + (busy ? "\n\n⚠︎ È in corso una proiezione: aggiornare la interromperà." : "")
                    a.addButton(withTitle: "Aggiorna e riavvia"); a.addButton(withTitle: "Più tardi")
                    if a.runModal() == .alertFirstButtonReturn { self.applyUpdate(i) }
                }
            }
        }
    }
    func applyUpdate(_ i: UpdateInfo) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Aggiornamento"; let bar = NSProgressIndicator(frame: NSRect(x: 24, y: 28, width: 272, height: 16)); bar.style = .bar; bar.isIndeterminate = true; bar.startAnimation(nil)
        let l = NSTextField(labelWithString: "Scarico Dolly Projector \(i.version)…"); l.frame = NSRect(x: 24, y: 52, width: 272, height: 20)
        w.contentView?.addSubview(bar); w.contentView?.addSubview(l); w.center(); w.makeKeyAndOrderFront(nil)
        DispatchQueue.global().async {
            let r = Result { try Updater.download(i) }
            DispatchQueue.main.async {
                w.close()
                switch r {
                case .failure(let e): self.updateAlert("Aggiornamento non riuscito", "\(e)")
                case .success(let path): self.stopEngine(); Updater.installAndRelaunch(newApp: path); NSApp.terminate(nil)
                }
            }
        }
    }
    func updateAlert(_ t: String, _ m: String) { let a = NSAlert(); a.messageText = t; a.informativeText = m; a.runModal() }
}
