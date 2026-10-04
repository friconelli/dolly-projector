import Foundation
import AppKit
import SwiftUI
import Security

/// Ricerca e scarico dei sottotitoli da OpenSubtitles (API ufficiale v1). Serve un account gratuito: ognuno inserisce la propria chiave API e le proprie credenziali (la password sta nel Portachiavi).
/// Si contatta internet solo quando l'utente preme "Cerca" o "Scarica". Il file va accanto al film, solo dopo conferma, e non sovrascrive nulla.
struct SubResult: Identifiable, Equatable {
    let id: Int; let name: String; let lang: String; let downloads: Int; let rating: Double; let exact: Bool; let hearing: Bool; let release: String
}

enum Subtitles {
    static let env = ProcessInfo.processInfo.environment
    static var base: String { env["DOLLY_SUBS_URL"] ?? "https://api.opensubtitles.com/api/v1" }
    static var ua: String { "DollyProjector v\(Updater.current)" }
    static var apiKey: String { get { env["DOLLY_OS_KEY"] ?? UserDefaults.standard.string(forKey: "os.key") ?? "" } set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "os.key") } }
    static var user: String { get { env["DOLLY_OS_USER"] ?? UserDefaults.standard.string(forKey: "os.user") ?? "" } set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "os.user") } }
    static var password: String { get { env["DOLLY_OS_PASS"] ?? Keychain.get("os.password") ?? "" } set { Keychain.set("os.password", newValue) } }
    static var configured: Bool { !apiKey.isEmpty && !user.isEmpty && !password.isEmpty }
    static var token: String?

    // MARK: titolo e anno dal nome del file
    /// "Titolo (Anno - Regista).mkv" (convenzione della cineteca) oppure nomi "alla scene": Titolo.Anno.1080p.x264…
    static func guess(_ file: String) -> (title: String, year: Int?) {
        let base = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        if let r = base.range(of: #" \((\d{4})"#, options: .regularExpression) {
            let title = String(base[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let year = Int(base[r].filter(\.isNumber))
            if !title.isEmpty { return (title, year) }
        }
        var s = base.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        var year: Int?
        if let r = s.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) { year = Int(s[r]); s = String(s[..<r.lowerBound]) }
        s = s.replacingOccurrences(of: #"\b(480p|720p|1080p|2160p|4k|bluray|brrip|webrip|web-dl|dvdrip|x264|x265|hevc|h264|aac|ac3|dts)\b.*"#, with: "", options: [.regularExpression, .caseInsensitive])
        return (s.trimmingCharacters(in: CharacterSet(charactersIn: " -")), year)
    }

    /// Hash di OpenSubtitles: dimensione + somma di parole da 64 bit dei primi e degli ultimi 64 KB. Identifica il file esatto, quindi i sottotitoli sono sincronizzati.
    static func movieHash(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64, size >= 131072 else { return nil }
        var hash = size
        func add(_ d: Data) { d.withUnsafeBytes { raw in for i in 0..<(raw.count / 8) { hash = hash &+ raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) } } }
        guard let a = try? fh.read(upToCount: 65536) else { return nil }; add(a)
        try? fh.seek(toOffset: size - 65536)
        guard let b = try? fh.read(upToCount: 65536) else { return nil }; add(b)
        return String(format: "%016llx", hash)
    }

    // MARK: rete
    static func send(_ rq: URLRequest) throws -> (Data, Int) {
        var out: (Data, Int)?, err: Error?; let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: rq) { d, r, e in if let d = d, let r = r as? HTTPURLResponse { out = (d, r.statusCode) } else { err = e ?? DollyError("nessuna risposta") }; sem.signal() }.resume()
        sem.wait(); if let o = out { return o }; throw err!
    }
    static func request(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, auth: Bool = false) -> URLRequest {
        var c = URLComponents(string: base + path)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var rq = URLRequest(url: c.url!, timeoutInterval: 20)
        rq.setValue(apiKey, forHTTPHeaderField: "Api-Key"); rq.setValue(ua, forHTTPHeaderField: "User-Agent"); rq.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth, let t = token { rq.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        if let b = body { rq.httpMethod = "POST"; rq.setValue("application/json", forHTTPHeaderField: "Content-Type"); rq.httpBody = try? JSONSerialization.data(withJSONObject: b) }
        return rq
    }
    static func explain(_ code: Int, _ data: Data) -> DollyError {
        let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? ""
        switch code {
        case 401: return DollyError("Utente o password di OpenSubtitles non validi, oppure chiave API errata.")
        case 403: return DollyError("Chiave API di OpenSubtitles non valida.")
        case 406: return DollyError("Limite di scaricamenti giornalieri raggiunto: riprova domani. \(msg)")
        case 429: return DollyError("Troppe richieste a OpenSubtitles: aspetta un momento e riprova.")
        default: return DollyError("OpenSubtitles ha risposto con errore \(code). \(msg)")
        }
    }

    static func search(path: String, lang: String) throws -> [SubResult] {
        guard !apiKey.isEmpty else { throw DollyError("Inserisci la chiave API di OpenSubtitles.") }
        let g = guess(path); var q = ["languages": lang, "query": g.title, "order_by": "download_count", "order_direction": "desc"]
        if let y = g.year { q["year"] = String(y) }
        if let h = movieHash(path) { q["moviehash"] = h }
        let (d, code) = try send(request("/subtitles", query: q))
        guard code == 200 else { throw explain(code, d) }
        let arr = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        let res: [SubResult] = arr.compactMap { it in
            guard let a = it["attributes"] as? [String: Any], let f = (a["files"] as? [[String: Any]])?.first, let fid = asInt(f["file_id"]) else { return nil }
            return SubResult(id: fid, name: asString(f["file_name"]) ?? asString(a["release"]) ?? "sottotitoli", lang: asString(a["language"]) ?? lang, downloads: asInt(a["download_count"]) ?? 0,
                             rating: asDouble(a["ratings"]) ?? 0, exact: asBool(a["moviehash_match"]) ?? false, hearing: asBool(a["hearing_impaired"]) ?? false, release: asString(a["release"]) ?? "")
        }
        return Array(res.sorted { ($0.exact ? 1 : 0, $0.downloads) > ($1.exact ? 1 : 0, $1.downloads) }.prefix(20))   // prima quelli per questo file esatto
    }

    static func login() throws {
        let (d, code) = try send(request("/login", body: ["username": user, "password": password]))
        guard code == 200, let t = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["token"] as? String else { throw explain(code == 200 ? 401 : code, d) }
        token = t
    }
    /// Scarica il file (srt) e lo restituisce in UTF-8.
    static func download(_ id: Int) throws -> String {
        if token == nil { try login() }
        func ask() throws -> (Data, Int) { try send(request("/download", body: ["file_id": id, "sub_format": "srt"], auth: true)) }
        var (d, code) = try ask()
        if code == 401 { token = nil; try login(); (d, code) = try ask() }
        guard code == 200, let link = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["link"] as? String, let u = URL(string: link) else { throw explain(code, d) }
        var rq = URLRequest(url: u, timeoutInterval: 30); rq.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, c2) = try send(rq)
        guard c2 == 200, !data.isEmpty else { throw DollyError("Download del file non riuscito (\(c2)).") }
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        if let s = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) { return s }   // molti .srt sono in codifiche vecchie: mpv li vuole in UTF-8
        throw DollyError("Codifica del file non riconosciuta.")
    }

    /// Dove salvarlo: accanto al film, "Film.it.srt"; se esiste già, "Film.it.2.srt" (mai sovrascrivere).
    static func destination(film: String, lang: String) -> String {
        let dir = (film as NSString).deletingLastPathComponent, base = ((film as NSString).lastPathComponent as NSString).deletingPathExtension
        var p = "\(dir)/\(base).\(lang).srt", n = 2
        while FileManager.default.fileExists(atPath: p) { p = "\(dir)/\(base).\(lang).\(n).srt"; n += 1 }
        return p
    }
}

enum Keychain {
    static let service = "app.dollyprojector.opensubtitles"
    static func get(_ k: String) -> String? {
        var out: CFTypeRef?; let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: k, kSecReturnData as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }; return String(data: d, encoding: .utf8)
    }
    static func set(_ k: String, _ v: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: k]
        SecItemDelete(q as CFDictionary)
        if !v.isEmpty { var a = q; a[kSecValueData as String] = Data(v.utf8); SecItemAdd(a as CFDictionary, nil) }
    }
}

// MARK: interfaccia
final class SubsModel: ObservableObject {
    @Published var results: [SubResult] = []
    @Published var status = ""
    @Published var busy = false
    @Published var key = Subtitles.apiKey
    @Published var user = Subtitles.user
    @Published var pass = Subtitles.password
    func save() { Subtitles.apiKey = key; Subtitles.user = user; Subtitles.password = pass; Subtitles.token = nil }
    func search(film: String, lang: String) {
        save(); busy = true; status = "Cerco…"; results = []
        DispatchQueue.global().async {
            let r = Result { try Subtitles.search(path: film, lang: lang) }
            DispatchQueue.main.async {
                self.busy = false
                switch r {
                case .failure(let e): self.status = "\(e)"
                case .success(let l): self.results = l; self.status = l.isEmpty ? "Nessun sottotitolo trovato per questo film." : "\(l.count) risultati" + (l.contains { $0.exact } ? " (prima quelli per questo file esatto)" : "")
                }
            }
        }
    }
    func download(_ r: SubResult, film: String, engine: Engine) {
        let dest = Subtitles.destination(film: film, lang: r.lang)
        let a = NSAlert(); a.messageText = "Salvare i sottotitoli accanto al film?"
        a.informativeText = "Verrà creato il file:\n\((dest as NSString).lastPathComponent)\nnella cartella del film. Nessun file esistente viene modificato."
        a.addButton(withTitle: "Salva"); a.addButton(withTitle: "Annulla")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        save(); busy = true; status = "Scarico…"
        DispatchQueue.global().async {
            let res = Result { () -> String in let s = try Subtitles.download(r.id); try s.write(toFile: dest, atomically: true, encoding: .utf8); return dest }
            DispatchQueue.main.async {
                self.busy = false
                switch res {
                case .failure(let e): self.status = "\(e)"
                case .success(let p): self.status = "Salvato: \((p as NSString).lastPathComponent)"; engine.send(["a": "subadd", "path": p, "film": film])
                }
            }
        }
    }
}

struct SubsDownloadCard: View {
    @ObservedObject var engine: Engine
    @StateObject private var m = SubsModel()
    @State private var lang = UserDefaults.standard.string(forKey: "os.lang") ?? "it"
    @State private var editing = false
    static let langs: [(String, String)] = [("it", "Italiano"), ("en", "Inglese"), ("fr", "Francese"), ("es", "Spagnolo"), ("de", "Tedesco"), ("pt-PT", "Portoghese")]
    var film: (path: String, label: String)? {
        let s = engine.snap, i = (s.mode == "playing" || s.mode == "wait") ? s.idx : s.sel
        guard s.items.indices.contains(i), s.items[i].kind == "film", let p = s.items[i].path, !p.isEmpty else { return nil }
        return (p, s.items[i].label)
    }
    var body: some View {
        Card(title: "Scarica sottotitoli", symbol: "arrow.down.circle") {
            if let f = film {
                let g = Subtitles.guess(f.path)
                Text("\(g.title)\(g.year.map { " (\($0))" } ?? "")").font(.system(size: 13, weight: .semibold))
                HStack { FieldLabel("Lingua")
                    Picker("", selection: $lang) { ForEach(Self.langs, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().onChange(of: lang) { UserDefaults.standard.set($0, forKey: "os.lang") }
                    Button("Cerca") { m.search(film: f.path, lang: lang) }.disabled(m.busy) }
                ForEach(m.results.prefix(8)) { r in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.release.isEmpty ? r.name : r.release).font(.system(size: 12)).lineLimit(2)
                            Text("\(r.exact ? "✓ stesso file · " : "")\(r.downloads) scaricamenti\(r.hearing ? " · per non udenti" : "")").font(.system(size: 11)).foregroundStyle(r.exact ? Color.green : .secondary)
                        }
                        Spacer(minLength: 4)
                        Button("Scarica") { m.download(r, film: f.path, engine: engine) }.controlSize(.small).disabled(m.busy)
                    }
                }
            } else { Text("Seleziona un film nella scena per cercarne i sottotitoli.").font(.system(size: 12)).foregroundStyle(.secondary) }
            if !m.status.isEmpty { Text(m.status).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            if Subtitles.configured && !editing {
                HStack { Text("Account OpenSubtitles: \(m.user)").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); Button("Modifica") { editing = true }.controlSize(.small) }
            } else {
                Text("Account OpenSubtitles (gratuito)").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Chiave API", text: $m.key).textFieldStyle(.roundedBorder)
                TextField("Utente", text: $m.user).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $m.pass).textFieldStyle(.roundedBorder)
                HStack { Button("Come ottenerli") { NSWorkspace.shared.open(URL(string: "https://www.opensubtitles.com/consumers")!) }.controlSize(.small).buttonStyle(.link)
                    Spacer(); Button("Salva") { m.save(); m.status = "Credenziali salvate."; editing = false }.controlSize(.small) }
            }
            Text("Si collega a internet solo quando premi Cerca o Scarica. La password è nel Portachiavi del Mac.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
