import Foundation
import Combine
import AppKit

func nowT() -> Double { Date().timeIntervalSince1970 }

/// La regia: sequenza della scena (film, neri, intervalli), controllo di mpv, riavvio se si pianta, salvataggio.
/// Tutto lo stato vive sulla coda `q`; l'interfaccia riceve un'istantanea aggiornata ogni secondo.
final class Engine: ObservableObject {
    @Published var snap = Snap()
    @Published var previewImage: NSImage?   // aggiornata dal motore, una volta al secondo, finché si proietta
    let q = DispatchQueue(label: "dolly.engine")
    let folder: String, home: String
    static var homePath: String { ProcessInfo.processInfo.environment["DOLLY_HOME"] ?? NSHomeDirectory() + "/Library/Application Support/Dolly" }
    private var mpv: Mpv
    private var timer: DispatchSourceTimer?
    private var caff: Process?
    private var tickCount = 0

    private var items: [Item] = [], name = tr("Scena"), defpre = 0.0, defpost = 0.0, auto = true, loop = false, defsub = "file"   // defsub: sottotitoli di tutta la scena
    private var prefs: [String: Any] = [:], resume: [String: Any]?
    private var mode = "idle", idx = -1, sel = 0, next = -1, until = 0.0, label = ""
    private var pos = 0.0, dur = 0.0, loadedAt = 0.0, shown = 0, retries = 0, fails = 0, restarts = 0, lastSave = 0.0
    private var err: String?, quitting = false, pvData: Data?, pvT = 0.0
    private var previewOn = UserDefaults.standard.object(forKey: "preview") as? Bool ?? true
    private var langPending = false, langTries = 0   // scelta di audio/sottotitoli del film appena partito
    private var loopFile = false   // "ripeti questo film": vale solo per il film in corso, al successivo si azzera

    init(folder: String, mpvBinary: String, extra: [String], windowed: Bool, screen: Int, autoresume: Bool, resetPlaylist: Bool = false) throws {
        self.folder = (folder as NSString).expandingTildeInPath
        home = Engine.homePath
        try FileManager.default.createDirectory(atPath: home + "/playlists", withIntermediateDirectories: true)
        mpv = Mpv(binary: mpvBinary, extra: extra, windowed: windowed, screen: screen)
        loadCurrent(); killOrphans()
        if resetPlaylist { items = videosIn(self.folder).map { Item(path: $0) }; idx = -1; sel = 0; resume = nil }   // cartella cambiata: la scaletta riparte dai suoi film
        try mpv.start(); applyPrefs()
        if autoresume, let r = resume, let i = asInt(r["idx"]), i < items.count, nowT() - (asDouble(r["t"]) ?? 0) < 60 {   // riavvio dopo un arresto imprevisto, a proiezione in corso
            log("riprendo da solo:", r); load(i, start: asDouble(r["pos"]) ?? 0)
        }
        let c = Process(); c.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate"); c.arguments = ["-dis", "-w", String(getpid())]   // il Mac non deve dormire durante la proiezione
        if (try? c.run()) != nil { caff = c }
        let t = DispatchSource.makeTimerSource(queue: q); t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.tickLoop() }; t.resume(); timer = t
    }

    // MARK: persistenza
    private var cfile: String { home + "/current.json" }
    private func dump() -> [String: Any] {
        ["name": name, "items": items.map { $0.dict }, "defpre": defpre, "defpost": defpost, "auto": auto, "loop": loop, "defsub": defsub, "prefs": prefs, "resume": resume as Any? ?? NSNull()]
    }
    private func writeJSON(_ obj: Any, to path: String) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let tmp = path + ".tmp"
        if (try? d.write(to: URL(fileURLWithPath: tmp))) != nil { _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp)) }
    }
    private func save() { writeJSON(dump(), to: cfile) }
    private func loadCurrent() {
        let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: cfile)))) as? [String: Any] ?? [:]
        name = asString(d["name"]) ?? tr("Scena"); defpre = asDouble(d["defpre"]) ?? 0; defpost = asDouble(d["defpost"]) ?? 0
        auto = asBool(d["auto"]) ?? true; loop = asBool(d["loop"]) ?? false; prefs = (d["prefs"] as? [String: Any] ?? [:]).filter { $0.key != "loop-file" && $0.key != "speed" }
        defsub = ["file", "none", "forced", "full"].contains(asString(d["defsub"]) ?? "") ? asString(d["defsub"])! : "file"
        resume = d["resume"] as? [String: Any]
        items = (d["items"] as? [[String: Any]] ?? []).map { Item(dict: $0) }
        if items.isEmpty { items = videosIn(folder).map { Item(path: $0) } }
    }
    private func plPath(_ n: String) -> String {
        let ok = n.filter { $0.isLetter || $0.isNumber || " -_()".contains($0) }.trimmingCharacters(in: .whitespaces)
        return home + "/playlists/" + ok + ".json"
    }
    private func savedLists() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home + "/playlists")) ?? []).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    // MARK: mpv
    private func killOrphans() {
        // se una copia precedente è stata uccisa di forza, il suo mpv resterebbe aperto sullo schermo: lo chiudiamo
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "pid=,args="]
        let pipe = Pipe(); p.standardOutput = pipe; guard (try? p.run()) != nil else { return }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit()
        let re = try! NSRegularExpression(pattern: "--input-ipc-server=\\S*dolly-(\\d+)-\\d+\\.sock")
        for line in out.split(separator: "\n") {
            let l = String(line)
            guard let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let r = Range(m.range(at: 1), in: l),
                  let owner = Int32(l[r]), owner != getpid(), let pid = Int32(l.split(separator: " ").first ?? "") else { continue }
            if Darwin.kill(owner, 0) != 0 && errno == ESRCH { log("chiudo un mpv rimasto aperto:", pid); Darwin.kill(pid, SIGKILL) }
        }
    }
    /// Stile iniziale dei sottotitoli. Lo stile di Dolly vale anche sui sottotitoli già stilizzati (ASS): altrimenti il cambio di font o colore non si vedrebbe su quei film.
    static let subStyleDefaults: [String: Any] = ["sub-font": "sans-serif", "sub-font-size": 38.0, "sub-color": "#FFFFFF", "sub-border-color": "#000000", "sub-border-size": 1.65,
        "sub-back-color": "#00000000", "sub-shadow-offset": 0.0, "sub-bold": false, "sub-italic": false, "sub-pos": 100.0, "sub-scale": 1.0, "sub-ass-override": "force"]
    private func applyPrefs() {
        var cmds: [[Any]] = [["set_property", "sub-ass-override", "force"]]
        cmds += prefs.map { ["set_property", $0.key, $0.value] }
        if !cmds.isEmpty { do { try mpv.ipc(cmds) } catch { log("prefs:", error) } }
    }
    private func respawn(_ why: String) {
        log("RIAVVIO mpv:", why); restarts += 1
        mpv.kill()
        do { try mpv.start() } catch { log("mpv non riparte:", error); return }
        fails = 0; applyPrefs()
        if mode == "playing" { load(idx, start: max(0, pos - 1)) } else if mode == "wait" { shown = 0 }
    }
    private func pre(_ i: Int) -> Double { items[i].pre ?? defpre }
    private func post(_ i: Int) -> Double { items[i].post ?? defpost }

    // MARK: sequenza
    private func load(_ i: Int, start: Double = 0) {
        guard items.indices.contains(i) else { return }
        let it = items[i]
        if it.kind == "pausa" || it.kind == "nero" {   // intervallo (testo e conto alla rovescia) o nero puro: schermo nero per un tempo
            _ = try? mpv.ipc([["stop"]]); mode = "wait"; idx = i; sel = i; until = nowT() + it.secs; shown = 0; err = nil; return
        }
        if !FileManager.default.fileExists(atPath: it.path) {
            err = trf("file mancante: %@", it.title); log(err!); advance(i); return
        }
        // lingue e livello di questo film (le opzioni valgono per il file che sta per essere aperto)
        let sm = subMode(it)
        var cmds: [[Any]] = [["set_property", "alang", it.alang.isEmpty ? "ita,it,eng,en" : it.alang], ["set_property", "slang", it.slang], ["set_property", "sid", sm == "none" ? "no" : "auto"],
                             ["set_property", "aid", "auto"], ["set_property", "vid", "auto"]]   // le scelte fatte su un film (traccia audio, "nero immagine") non devono passare al successivo
        if let v = it.vol { cmds.append(["set_property", "volume", v]); prefs["volume"] = v }
        langPending = it.kind == "film" && (!it.alang.isEmpty || !it.slang.isEmpty || sm == "forced" || sm == "full"); langTries = 0
        if start == 0 { loopFile = it.loop != 0 }   // un nuovo film parte con la sua ripetizione (nessuna, infinita o N volte); una ripresa dopo un blocco mantiene lo stato attuale
        cmds.append(["set_property", "loop-file", start == 0 ? (it.loop < 0 ? "inf" : it.loop > 0 ? String(it.loop) : "no") : (loopFile ? "inf" : "no")])
        let ld: [Any] = start > 0 ? ["loadfile", it.path, "replace", -1, "start=\(start)"] : ["loadfile", it.path, "replace"]
        do { try mpv.ipc(cmds + [ld, ["set_property", "pause", false]]) } catch { log("loadfile:", error); return }
        mode = "playing"; idx = i; sel = i; loadedAt = nowT(); pos = start; dur = 0; err = nil
        if start == 0 { retries = 0 }
    }
    private func gap(_ i: Int, _ secs: Double, _ lab: String) {
        if mode == "playing" || mode == "wait" { _ = try? mpv.ipc([["stop"]]) }
        mode = "gap"; next = i; sel = i; until = nowT() + secs; label = lab
        if secs <= 0 { load(i) }
    }
    private func stopAll() { _ = try? mpv.ipc([["stop"]]); mode = "idle"; resume = nil; save() }
    /// L'elemento i è finito (o saltato): passa al successivo con il nero tra i due.
    private func advance(_ i: Int) {
        var n = i + 1
        if n >= items.count {
            if !(loop && auto && !items.isEmpty) { mode = "idle"; resume = nil; sel = max(0, min(i, items.count - 1)); save(); return }
            n = 0
        }
        sel = n
        if !auto { mode = "idle"; resume = nil; save(); return }
        let secs = post(i) + pre(n)
        gap(n, secs, secs > 0 ? tr("Nero tra i film") : "")
    }
    private func tickLoop() {
        do { try tick() } catch { log("errore tick:", error) }
        tickCount += 1; if tickCount % 4 == 0 { publish(); refreshPreview() }
    }
    private func tick() throws {
        if quitting { return }
        if !mpv.alive { respawn(tr("processo terminato")); return }
        let now = nowT()
        if mode == "gap" && now >= until { load(next) }
        else if mode == "wait" {
            let left = until - now
            if left <= 0 { if items[idx].kind == "pausa" { _ = try? mpv.ipc([["show-text", "", 1]]) }; advance(idx); return }
            if Int(left) != shown && items[idx].kind == "pausa" {   // una volta al secondo: testo + tempo che manca, sullo schermo della sala
                shown = Int(left); let txt = items[idx].text
                _ = try? mpv.ipc([["show-text", (txt.isEmpty ? "" : txt + "\n") + String(format: "%d:%02d", Int(left) / 60, Int(left) % 60), 1500]])
            }
        } else if mode == "playing" {
            let r: [String: Any]
            do { r = try mpv.get(["idle-active", "time-pos", "duration"]); fails = 0 }
            catch { fails += 1; log(tr("mpv non risponde"), fails, error); if fails >= 3 { respawn(tr("non risponde")) }; return }
            if asBool(r["idle-active"]) == true {
                if now - loadedAt < 2 { return }   // caricamento in corso
                if dur > 0 && pos < dur - 5 && retries < 2 {   // fine anomala: riprova dal punto in cui era
                    retries += 1; let msg = trf("interrotto a %ds, riprendo", Int(pos)); log(msg); load(idx, start: max(0, pos - 1)); err = msg
                } else {
                    if dur == 0 { err = trf("%@: non riproducibile, passo oltre", items[idx].title) }
                    advance(idx)
                }
            } else {
                if let t = asDouble(r["time-pos"]), t != 0 { pos = t }
                if let d = asDouble(r["duration"]), d != 0 { dur = d }
                if langPending { applyLangs(items[idx]) }
                if now - lastSave > 2 { lastSave = now; resume = ["idx": idx, "pos": pos, "t": now]; save() }
            }
        }
    }

    // MARK: lingue
    private func langMatch(_ track: String, _ want: String) -> Bool {
        let t = track.lowercased(), w = want.lowercased().trimmingCharacters(in: .whitespaces)
        if t.isEmpty || w.isEmpty { return false }
        if t == w || t.hasPrefix(w) || w.hasPrefix(t) { return true }
        let alias: [String: Set<String>] = ["fre": ["fra", "fr"], "fra": ["fre", "fr"], "ger": ["deu", "de"], "deu": ["ger", "de"], "dut": ["nld", "nl"], "chi": ["zho", "zh"], "gre": ["ell", "el"]]
        return alias[t]?.contains(w) == true || alias[w]?.contains(t) == true
    }
    /// Modo sottotitoli effettivo di un film: il suo, altrimenti quello della scena (una lingua scritta sul film vale come "completi" se la scena dice "come nel file" o "nessuno").
    private func subMode(_ it: Item) -> String {
        if let m = it.submode { return m }
        if !it.slang.isEmpty && (defsub == "file" || defsub == "none") { return "full" }
        return defsub
    }
    private func isForced(_ t: [String: Any]) -> Bool {
        (asBool(t["forced"]) ?? false) || (asString(t["title"]) ?? "").range(of: "forz|forced|signs|songs|cartell", options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Sceglie audio e sottotitoli del film in corso secondo lingue e modo (come nel file / nessuno / solo forzati / completi).
    /// Tra tracce nella stessa lingua distingue le "forzate" (poche battute, solo dialoghi stranieri) da quelle complete.
    private func applyLangs(_ it: Item) {
        langTries += 1; if langTries > 20 { langPending = false; return }
        guard let r = try? mpv.get(["track-list"]), let tl = r["track-list"] as? [[String: Any]], tl.contains(where: { $0["type"] as? String == "audio" }) else { return }
        langPending = false
        var cmds: [[Any]] = []
        let audios = tl.filter { $0["type"] as? String == "audio" }
        var audioLang = asString(audios.first { asBool($0["selected"]) ?? false }?["lang"]) ?? ""
        let wantA = it.alang.split(separator: ",").map(String.init)
        outer: for w in wantA { for tr in audios { if langMatch(asString(tr["lang"]) ?? "", w), let id = asInt(tr["id"]) { cmds.append(["set_property", "aid", id]); audioLang = asString(tr["lang"]) ?? audioLang; break outer } } }
        let mode = subMode(it)
        let subs = tl.filter { $0["type"] as? String == "sub" }
        var wantS = it.slang.split(separator: ",").map(String.init)
        if wantS.isEmpty && (mode == "forced" || mode == "full") && !audioLang.isEmpty { wantS = [audioLang] }
        func pick(_ pool: [[String: Any]]) -> Int? {
            for w in wantS { if let tr = pool.first(where: { langMatch(asString($0["lang"]) ?? "", w) }), let id = asInt(tr["id"]) { return id } }
            return nil
        }
        switch mode {
        case "none": cmds.append(["set_property", "sid", "no"])
        case "forced":
            if let id = pick(subs.filter { isForced($0) }) ?? subs.first(where: { isForced($0) }).flatMap({ asInt($0["id"]) }) { cmds.append(["set_property", "sid", id]); cmds.append(["set_property", "sub-visibility", true]) }
            else { cmds.append(["set_property", "sid", "no"]) }
        case "full":
            let full = subs.filter { !isForced($0) }
            if let id = pick(full) ?? full.first.flatMap({ asInt($0["id"]) }) { cmds.append(["set_property", "sid", id]); cmds.append(["set_property", "sub-visibility", true]) }
            else { cmds.append(["set_property", "sid", "no"]) }
        default:   // "file": decide il file (traccia predefinita); se è scritta una lingua si prende la traccia completa in quella lingua
            if !it.slang.isEmpty, let id = pick(subs.filter { !isForced($0) }) ?? pick(subs) { cmds.append(["set_property", "sid", id]); cmds.append(["set_property", "sub-visibility", true]) }
            else { cmds.append(["set_property", "sid", "auto"]) }
        }
        if !cmds.isEmpty { _ = try? mpv.ipc(cmds) }
    }

    // MARK: comandi
    private func base() -> Int { (mode == "playing" || mode == "wait") ? idx : sel }
    private func startItem(_ i: Int) { if items.indices.contains(i) { gap(i, pre(i), pre(i) > 0 ? tr("Nero prima del film") : "") } }
    private func num(_ d: [String: Any], _ k: String) throws -> Double {
        guard let v = asDouble(d[k]) else { throw DollyError(trf("valore non valido per %@", k)) }
        return v
    }
    private func optNum(_ v: Any?) throws -> Double? {
        if v == nil || v is NSNull || (v as? String) == "" { return nil }
        guard let x = asDouble(v) else { throw DollyError(tr("valore non valido")) }
        return max(0, x)
    }
    private func setProp(_ p: String, _ v: Any?) throws {
        guard let k = PROPS[p] else { throw DollyError(trf("proprietà non ammessa: %@", p)) }
        let val: Any
        switch k.kind {
        case "b": val = asBool(v) ?? false
        case "f": guard let x = asDouble(v) else { throw DollyError(tr("numero non valido")) }; val = max(k.lo, min(k.hi, x))
        default: val = String((asString(v) ?? "").prefix(100))
        }
        if p.hasSuffix("color"), (val as! String).range(of: "^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$", options: .regularExpression) == nil { throw DollyError(trf("colore non valido: %@", "\(val)")) }
        if p == "sub-ass-override", !["no", "yes", "scale", "force", "strip"].contains(val as! String) { throw DollyError(trf("valore non valido: %@", "\(val)")) }
        if p == "loop-file" { loopFile = (val as? String) != "no"; try mpv.ipc([["set_property", p, val]]); return }
        prefs[p] = val; try mpv.ipc([["set_property", p, val]])
    }
    private func removeItem(_ i: Int) {
        guard items.indices.contains(i) else { return }
        items.remove(at: i)
        if idx == i && (mode == "playing" || mode == "wait") { stopAll() } else if idx > i { idx -= 1 }
        if mode == "gap" && next == i { stopAll() } else if next > i { next -= 1 }
        sel = min(sel <= i ? sel : sel - 1, max(0, items.count - 1))
    }
    private func moveItem(_ i: Int, _ dlt: Int) {
        let j = i + dlt
        guard items.indices.contains(i), items.indices.contains(j) else { return }
        items.swapAt(i, j)
        func fix(_ v: Int) -> Int { v == i ? j : v == j ? i : v }
        idx = fix(idx); next = fix(next); sel = fix(sel)
    }
    private func reorderItem(_ f: Int, _ t: Int) {   // trascinamento: l'elemento f va in posizione t
        guard items.indices.contains(f), items.indices.contains(t), f != t else { return }
        let it = items.remove(at: f); items.insert(it, at: t)
        func fix(_ k: Int) -> Int { k == f ? t : (f < t && k > f && k <= t) ? k - 1 : (f > t && k >= t && k < f) ? k + 1 : k }
        idx = fix(idx); next = fix(next); sel = fix(sel)
    }
    private func importM3U(_ path: String) {
        let baseDir = (path as NSString).deletingLastPathComponent
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let paths = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.hasPrefix("/") ? $0 : baseDir + "/" + $0 }
        if mode != "idle" { stopAll() }
        name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension; idx = -1; sel = 0
        items = paths.flatMap { videosIn($0) }.map { Item(path: $0) }
    }
    private func loadList(_ n: String) throws {
        guard let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: plPath(n))))) as? [String: Any] else { throw DollyError(tr("scaletta non trovata")) }
        if mode != "idle" { stopAll() }
        name = asString(d["name"]) ?? n; items = (d["items"] as? [[String: Any]] ?? []).map { Item(dict: $0) }
        defpre = asDouble(d["defpre"]) ?? 0; defpost = asDouble(d["defpost"]) ?? 0; auto = asBool(d["auto"]) ?? true; loop = asBool(d["loop"]) ?? false
        defsub = ["file", "none", "forced", "full"].contains(asString(d["defsub"]) ?? "") ? asString(d["defsub"])! : "file"; idx = -1; sel = 0
    }

    func act(_ d: [String: Any]) throws {
        guard let a = d["a"] as? String else { throw DollyError(tr("comando mancante")) }
        switch a {
        case "play": startItem(Int(try num(d, "i")))
        case "toggle":   // play/pausa: se non sta suonando niente parte l'elemento selezionato
            if mode == "playing" { try mpv.ipc([["cycle", "pause"]]) } else if mode == "idle" { startItem(sel) }
        case "skipgap":
            if mode == "gap" { load(next) } else if mode == "wait" { _ = try? mpv.ipc([["show-text", "", 1]]); advance(idx) }
        case "extend": if mode == "wait" { until += asDouble(d["v"]) ?? 60 }   // intervallo più lungo
        case "next": startItem(base() + 1)
        case "prev":   // va sempre all'elemento precedente; solo sul primo (non c'è un precedente) riporta il film all'inizio
            if base() == 0 { if mode == "playing" { try mpv.ipc([["seek", 0, "absolute"]]) } else { startItem(0) } } else { startItem(base() - 1) }
        case "stop": stopAll()
        case "resume":
            if let r = resume, let i = asInt(r["idx"]), i < items.count { load(i, start: asDouble(r["pos"]) ?? 0) }
        case "seek": try mpv.ipc([["seek", try num(d, "v"), asString(d["m"]) ?? "absolute"]])
        case "frame": try mpv.ipc([["frame-step"]])
        case "frameback": try mpv.ipc([["frame-back-step"]])
        case "abloop": try mpv.ipc([["ab-loop"]])
        case "chapter": try mpv.ipc([["set_property", "chapter", Int(try num(d, "v"))]])
        case "aid", "sid", "vid":
            let v = asString(d["v"]) ?? "no"
            try mpv.ipc([["set_property", a, (v == "no" || v == "auto") ? v : (Int(v) ?? 0)]])
        case "set": try setProp(d["p"] as? String ?? "", d["v"])
        case "resetsubstyle":   // torna allo stile iniziale e dimentica quello salvato
            for (p, v) in Engine.subStyleDefaults { prefs.removeValue(forKey: p); try mpv.ipc([["set_property", p, v]]) }
        case "setmany": for (p, v) in (d["props"] as? [String: Any] ?? [:]) { try setProp(p, v) }
        case "text": try mpv.ipc([["show-text", String((asString(d["v"]) ?? "").prefix(200)), asInt(d["ms"]) ?? 5000]])
        case "resetvideo":
            for p in ["brightness", "contrast", "saturation", "gamma", "hue", "video-zoom", "video-pan-x", "video-pan-y", "panscan"] { try setProp(p, 0) }
            try setProp("video-aspect-override", "-1")
        case "defaults":
            if let v = asDouble(d["defpre"]) { defpre = max(0, v) }
            if let v = asDouble(d["defpost"]) { defpost = max(0, v) }
            if let v = asBool(d["auto"]) { auto = v }
            if let v = asBool(d["loop"]) { loop = v }
            if let v = asString(d["defsub"]), ["file", "none", "forced", "full"].contains(v) { defsub = v; if mode == "playing" { langPending = true; langTries = 0 } }   // vale subito sul film in corso
        case "add":   // "at": posizione di inserimento (trascinamento dal Finder tra due righe); senza, in fondo
            let new = (d["paths"] as? [String] ?? []).flatMap { videosIn(($0 as NSString).expandingTildeInPath) }.map { Item(path: $0) }
            if let at = asInt(d["at"]), (0...items.count).contains(at), !new.isEmpty {
                items.insert(contentsOf: new, at: at)
                func shift(_ k: Int) -> Int { k >= at ? k + new.count : k }   // chi sta dopo il punto di inserimento scala in avanti
                if idx >= 0 { idx = shift(idx) }; if next >= 0 { next = shift(next) }; sel = shift(sel)
            } else { items += new }
        case "addblack": items.append(Item(path: "", kind: "nero", secs: max(0.5, asDouble(d["secs"]) ?? 5)))
        case "addpause": items.append(Item(path: "", kind: "pausa", secs: max(1, asDouble(d["secs"]) ?? 600), text: String((asString(d["text"]) ?? tr("Intervallo")).prefix(100))))
        case "addlib":
            let fs = videosIn(folder)
            if let i = asInt(d["i"]) { guard fs.indices.contains(i) else { throw DollyError(tr("indice fuori range")) }; items.append(Item(path: fs[i])) }
            else { items += fs.map { Item(path: $0) } }
        case "remove": removeItem(asInt(d["i"]) ?? -1)
        case "move": moveItem(asInt(d["i"]) ?? -1, asInt(d["d"]) ?? 0)
        case "reorder": reorderItem(asInt(d["from"]) ?? -1, asInt(d["to"]) ?? -1)
        case "clear": if mode != "idle" { stopAll() }; items = []; sel = 0; idx = -1
        case "setitem":
            guard let i = asInt(d["i"]), items.indices.contains(i) else { throw DollyError(tr("indice fuori range")) }
            if d.keys.contains("pre") { items[i].pre = try optNum(d["pre"]) }
            if d.keys.contains("post") { items[i].post = try optNum(d["post"]) }
            if d.keys.contains("vol") { items[i].vol = try optNum(d["vol"]) }
            if let v = asDouble(d["secs"]) { items[i].secs = max(items[i].kind == "nero" ? 0.5 : 1, v) }
            if d.keys.contains("loop") { items[i].loop = max(-1, min(99, Int(asDouble(d["loop"]) ?? 0))) }
            if d.keys.contains("submode") { let m = asString(d["submode"]) ?? ""; items[i].submode = ["file", "none", "forced", "full"].contains(m) ? m : nil
                if i == idx && mode == "playing" { langPending = true; langTries = 0 } }
            if (d.keys.contains("alang") || d.keys.contains("slang")) && i == idx && mode == "playing" { langPending = true; langTries = 0 }   // vale subito sul film in corso
            for k in ["alang", "slang", "text"] { if let v = d[k] { let s = String((asString(v) ?? "").prefix(100)); switch k { case "alang": items[i].alang = s; case "slang": items[i].slang = s; default: items[i].text = s } } }
        case "rename": name = String((asString(d["v"]) ?? "").prefix(60))
        case "pl_save":
            if let n = asString(d["name"]), !n.isEmpty { name = String(n.prefix(60)) }
            writeJSON(dump(), to: plPath(name))
        case "pl_load": try loadList(asString(d["name"]) ?? "")
        case "pl_delete": try? FileManager.default.removeItem(atPath: plPath(asString(d["name"]) ?? ""))
        case "pl_import": importM3U(asString(d["path"]) ?? "")
        default: break
        }
        save()
    }

    // MARK: stato e anteprima
    func state() -> [String: Any] {
        let now = nowT()
        var st: [String: Any] = [
            "ok": true, "name": name, "mode": mode, "idx": idx, "sel": sel, "next": next, "label": label,
            "left": (mode == "gap" || mode == "wait") ? max(0, (until - now) * 10).rounded() / 10 : 0.0, "err": err as Any? ?? NSNull(), "restarts": restarts,
            "auto": auto, "loop": loop, "defsub": defsub, "pid": Int(mpv.proc?.processIdentifier ?? 0), "defpre": defpre, "defpost": defpost, "resume": resume as Any? ?? NSNull(), "folder": folder,
            "items": items.map { i -> [String: Any] in
                ["kind": i.kind, "pre": i.pre as Any? ?? NSNull(), "post": i.post as Any? ?? NSNull(), "vol": i.vol as Any? ?? NSNull(), "alang": i.alang, "slang": i.slang,
                 "secs": i.secs, "text": i.text, "name": i.title, "ok": i.kind != "film" || FileManager.default.fileExists(atPath: i.path), "loop": i.loop, "submode": i.submode as Any? ?? NSNull()] },
            "lib": videosIn(folder).map { ($0 as NSString).lastPathComponent }, "saved": savedLists(),
            "playing": false, "pause": false, "time": 0.0, "dur": 0.0, "audio": [Any](), "sub": [Any](), "video": [Any](), "chapters": [Any](),
            "chapter": NSNull(), "ab": [NSNull(), NSNull()], "props": [String: Any](), "adevs": [Any](), "info": [String: Any]()]
        let extra = ["pause", "time-pos", "duration", "track-list", "chapter-list", "chapter", "ab-loop-a", "ab-loop-b", "video-params", "container-fps", "video-codec",
                     "audio-codec-name", "frame-drop-count", "decoder-frame-drop-count", "path", "audio-device-list"]
        let r: [String: Any]
        do { r = try mpv.get(extra + READ_PROPS) } catch { st["ok"] = false; st["err"] = trf("mpv non risponde: %@", "\(error)"); return st }
        let tl = r["track-list"] as? [[String: Any]] ?? []
        func tr(_ type: String) -> [[String: Any]] {
            tl.filter { $0["type"] as? String == type }.map { x in
                var parts: [String] = []
                for k in ["lang", "title", "codec"] { if let s = asString(x[k]), !s.isEmpty { parts.append(s) } }
                if let n = asInt(x["demux-channel-count"]), n > 0 { parts.append("\(n)ch") }
                let id = asInt(x["id"]) ?? 0
                return ["id": id, "t": parts.isEmpty ? trf("traccia %d", id) : parts.joined(separator: " · "), "sel": asBool(x["selected"]) ?? false]
            }
        }
        let vp = r["video-params"] as? [String: Any] ?? [:]
        let chs = (r["chapter-list"] as? [[String: Any]] ?? []).enumerated().map { (i, c) in ["t": asString(c["title"]) ?? trf("Capitolo %d", i + 1), "s": asDouble(c["time"]) ?? 0] as [String: Any] }
        st["playing"] = r["path"] != nil; st["pause"] = asBool(r["pause"]) ?? false; st["time"] = asDouble(r["time-pos"]) ?? 0.0; st["dur"] = asDouble(r["duration"]) ?? 0.0
        st["audio"] = tr("audio"); st["sub"] = tr("sub"); st["video"] = tr("video"); st["chapters"] = chs; st["chapter"] = r["chapter"] ?? NSNull()
        st["ab"] = [asDouble(r["ab-loop-a"]) as Any? ?? NSNull(), asDouble(r["ab-loop-b"]) as Any? ?? NSNull()]   // "no" quando non impostato
        var props: [String: Any] = [:]; for k in READ_PROPS { props[k] = r[k] ?? NSNull() }; st["props"] = props
        st["adevs"] = (r["audio-device-list"] as? [[String: Any]] ?? []).map { ["id": asString($0["name"]) ?? "", "t": asString($0["description"]) ?? asString($0["name"]) ?? ""] }
        st["info"] = ["res": vp.isEmpty ? "" : "\(asInt(vp["w"]) ?? 0)×\(asInt(vp["h"]) ?? 0)", "fps": r["container-fps"] ?? NSNull(), "vcodec": r["video-codec"] ?? NSNull(),
                      "acodec": r["audio-codec-name"] ?? NSNull(), "dropped": (asInt(r["frame-drop-count"]) ?? 0) + (asInt(r["decoder-frame-drop-count"]) ?? 0)]
        return st
    }
    private func stateData() -> Data { (try? JSONSerialization.data(withJSONObject: state())) ?? Data("{}".utf8) }
    private func publish() {
        let data = stateData()
        do { let s = try JSONDecoder().decode(Snap.self, from: data); DispatchQueue.main.async { self.snap = s } }
        catch { log("stato non leggibile dall'interfaccia:", error) }
    }
    private func refreshPreview() {
        guard previewOn, mode == "playing" else { if previewImage != nil { DispatchQueue.main.async { self.previewImage = nil } }; return }
        let img = preview().flatMap { NSImage(data: $0) }
        DispatchQueue.main.async { self.previewImage = img }
    }
    func setPreview(_ on: Bool) { q.async { self.previewOn = on } }
    /// JPEG di ciò che si vede ora sullo schermo della sala (nil se è nero). In cache per ~0,45 s.
    private func preview() -> Data? {
        guard mode == "playing" else { return nil }
        if nowT() - pvT < 0.45 { return pvData }
        let f = NSTemporaryDirectory() + "dolly-\(getpid())-preview.jpg"
        do { try mpv.ipc([["screenshot-to-file", f, "window"]], timeout: 8); pvData = try Data(contentsOf: URL(fileURLWithPath: f)) } catch { pvData = nil }
        pvT = nowT(); return pvData
    }

    // MARK: ingressi pubblici (da qualunque thread)
    private var pubPending = false
    private func schedulePublish() {   // trascinando uno slider arrivano decine di comandi: l'istantanea si aggiorna una volta ogni ~0,12 s
        if pubPending { return }; pubPending = true
        q.asyncAfter(deadline: .now() + 0.12) { self.pubPending = false; self.publish() }
    }
    func send(_ d: [String: Any], done: ((String?) -> Void)? = nil) {
        q.async {
            var e: String?
            do { try self.act(d) } catch { e = "\(error)"; log(tr("errore comando"), d, error) }
            self.schedulePublish()
            if let done = done { DispatchQueue.main.async { done(e) } }
        }
    }
    func actSync(_ d: [String: Any]) -> String? {
        q.sync { do { try act(d); return nil } catch { log(tr("errore comando"), d, error); return "\(error)" } }
    }
    func stateSync() -> Data { q.sync { stateData() } }
    func previewSync() -> Data? { q.sync { preview() } }
    func shutdown() {
        q.sync { quitting = true; timer?.cancel(); mpv.kill(); caff?.terminate() }
    }
}
