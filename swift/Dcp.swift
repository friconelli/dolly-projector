import Foundation

/// DCP (Digital Cinema Package) non cifrati: dal CPL si costruisce un'unica "lista di montaggio" (EDL) per mpv, con un flusso video (JPEG 2000, XYZ) e uno audio (PCM)
/// che attraversano tutti i reel senza interruzioni. I sottotitoli di testo (Interop e SMPTE) diventano un file SRT con i tempi della sequenza intera.
/// Un elemento della scaletta che sia un DCP ha come percorso il file CPL (.xml): la cartella del pacchetto è quella che lo contiene.
enum Dcp {
    struct Prepared { let edl: String; let subs: String?; let duration: Double }

    private static let lock = NSLock()
    private static var cplCache: [String: (Date, [String])] = [:]   // cartella -> (data dell'ASSETMAP, CPL trovati)
    private static var titleCache: [String: String] = [:]

    // MARK: rilevamento
    /// Il file ASSETMAP di una cartella (Interop: ASSETMAP, SMPTE: ASSETMAP.xml).
    static func assetMapPath(in dir: String) -> String? {
        for n in ["ASSETMAP.xml", "ASSETMAP", "assetmap.xml", "assetmap"] {
            let p = dir + "/" + n; var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue { return p }
        }
        return nil
    }
    /// Un percorso che finisce in .xml dentro la scaletta è sempre un DCP (gli altri film sono mp4/avi/mkv).
    static func isCPLPath(_ p: String) -> Bool { p.lowercased().hasSuffix(".xml") }

    /// Il documento è davvero un CPL? (si guarda solo l'inizio del file)
    static func sniffCPL(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
        return head.contains("CompositionPlaylist")
    }

    private static func doc(_ path: String) -> XMLElement? {
        guard let d = try? XMLDocument(contentsOf: URL(fileURLWithPath: path), options: [.nodeLoadExternalEntitiesNever]) else { return nil }
        return d.rootElement()
    }

    /// Mappa id -> percorso assoluto dei file del pacchetto, letta dall'ASSETMAP.
    static func assetMap(in dir: String) -> [String: String] {
        guard let ap = assetMapPath(in: dir), let root = doc(ap) else { return [:] }
        var m: [String: String] = [:]
        for a in root.desc("Asset") {
            guard let id = a.text("Id"), var path = a.desc("Path").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
            if path.hasPrefix("file://") { path = URL(string: path)?.path ?? String(path.dropFirst(7)) }
            m[cleanId(id)] = path.hasPrefix("/") ? path : dir + "/" + path
        }
        return m
    }
    static func cleanId(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "urn:uuid:", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// I CPL (uno per ogni versione del film) di una cartella-DCP; vuoto se la cartella non è un DCP. Il risultato resta in cache finché l'ASSETMAP non cambia.
    static func cpls(inFolder dir: String) -> [String] {
        guard let ap = assetMapPath(in: dir) else { return [] }
        let mod = (try? FileManager.default.attributesOfItem(atPath: ap)[.modificationDate] as? Date) ?? Date.distantPast
        lock.lock(); if let c = cplCache[dir], c.0 == mod { lock.unlock(); return c.1 }; lock.unlock()
        var found = assetMap(in: dir).values.filter { $0.lowercased().hasSuffix(".xml") && FileManager.default.fileExists(atPath: $0) && sniffCPL($0) }.sorted()
        if found.isEmpty {   // ASSETMAP incompleto: si cercano comunque i CPL accanto ad esso
            found = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.lowercased().hasSuffix(".xml") }.map { dir + "/" + $0 }.filter { sniffCPL($0) }.sorted()
        }
        lock.lock(); cplCache[dir] = (mod, found); lock.unlock()
        return found
    }

    /// Titolo del film (ContentTitleText del CPL), in cache.
    static func title(_ cpl: String) -> String {
        lock.lock(); if let t = titleCache[cpl] { lock.unlock(); return t }; lock.unlock()
        var t = ""
        if let r = doc(cpl) { t = r.text("ContentTitleText") ?? r.text("AnnotationText") ?? "" }
        if t.isEmpty { t = ((cpl as NSString).deletingLastPathComponent as NSString).lastPathComponent }
        lock.lock(); titleCache[cpl] = t; lock.unlock()
        return t
    }

    // MARK: preparazione della riproduzione
    private struct Asset { let id: String; let rate: Double; let entry: Double; let dur: Double; let encrypted: Bool; let path: String?
        var start: Double { entry / rate }; var length: Double { dur / rate } }
    private struct Cue { var t0: Double; var t1: Double; var text: String }

    private static func rate(_ s: String?) -> Double {
        let p = (s ?? "").split(whereSeparator: { $0 == " " || $0 == "/" }).compactMap { Double($0) }
        guard let n = p.first, n > 0 else { return 24 }
        return p.count > 1 && p[1] > 0 ? n / p[1] : n
    }
    private static func asset(_ e: XMLElement, _ amap: [String: String]) -> Asset {
        let id = cleanId(e.text("Id") ?? ""); let r = rate(e.text("EditRate") ?? e.text("FrameRate"))
        let entry = Double(e.text("EntryPoint") ?? "") ?? 0
        let intr = Double(e.text("IntrinsicDuration") ?? "") ?? 0
        let dur = Double(e.text("Duration") ?? "") ?? max(0, intr - entry)
        return Asset(id: id, rate: r, entry: entry, dur: dur, encrypted: e.kid("KeyId") != nil, path: amap[id])
    }

    /// Legge il CPL e prepara la lista di montaggio per mpv. Lancia con un messaggio chiaro se il DCP è cifrato, 3D, incompleto o non valido.
    static func prepare(cpl: String, cacheDir: String) throws -> Prepared {
        let dir = (cpl as NSString).deletingLastPathComponent
        guard let root = doc(cpl), root.ln == "CompositionPlaylist" else { throw DollyError(trf("DCP non valido: %@", (cpl as NSString).lastPathComponent)) }
        let amap = assetMap(in: dir)
        if amap.isEmpty { throw DollyError(tr("DCP incompleto: manca il file ASSETMAP")) }
        var pics: [Asset] = [], snds: [Asset?] = [], subs: [Asset?] = []
        for reel in root.desc("Reel") {
            guard let list = reel.kid("AssetList") else { continue }
            if list.kid("MainStereoscopicPicture") != nil { throw DollyError(tr("DCP 3D: non supportato")) }
            guard let p = list.kid("MainPicture") else { continue }
            pics.append(asset(p, amap)); snds.append(list.kid("MainSound").map { asset($0, amap) }); subs.append(list.kid("MainSubtitle").map { asset($0, amap) })
        }
        if pics.isEmpty { throw DollyError(tr("il DCP non contiene immagini")) }
        if pics.contains(where: { $0.encrypted }) || snds.contains(where: { $0?.encrypted == true }) { throw DollyError(tr("il DCP è cifrato: serve una KDM e Dolly non può proiettarlo")) }
        func file(_ a: Asset) throws -> String {
            guard let p = a.path, FileManager.default.fileExists(atPath: p) else { throw DollyError(trf("DCP incompleto: manca il file %@", a.path.map { ($0 as NSString).lastPathComponent } ?? a.id)) }
            return p
        }
        func seg(_ a: Asset) throws -> String {
            let p = try file(a)
            return "%\(p.utf8.count)%\(p),\(String(format: "%.6f", a.start)),\(String(format: "%.6f", a.length))"
        }
        let v = try pics.map(seg).joined(separator: ";")
        var edl = "edl://!new_stream;!no_chapters;" + v
        if snds.allSatisfy({ $0 != nil }) { edl += ";!new_stream;!no_chapters;" + (try snds.map { try seg($0!) }.joined(separator: ";")) }   // audio solo se ce l'hanno tutti i reel
        let total = pics.reduce(0) { $0 + $1.length }

        // sottotitoli di testo: un unico SRT con i tempi della sequenza intera
        var cues: [Cue] = []; var offset = 0.0
        for (i, p) in pics.enumerated() {
            if let s = subs[i], !s.encrypted, let sp = s.path, FileManager.default.fileExists(atPath: sp) { cues += parseSubtitles(sp, offset: offset - s.start) }
            offset += p.length
        }
        var srt: String?
        if !cues.isEmpty {
            try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            let path = cacheDir + "/dcp-" + hash(cpl) + ".srt"
            if (try? srtText(cues).write(toFile: path, atomically: true, encoding: .utf8)) != nil { srt = path }
        }
        return Prepared(edl: edl, subs: srt, duration: total)
    }
    private static func hash(_ s: String) -> String { var h: UInt64 = 5381; for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }; return String(h, radix: 16) }

    // MARK: sottotitoli
    /// L'XML dei sottotitoli: un file .xml (Interop) oppure incorporato in un MXF (SMPTE, non cifrato).
    private static func subtitleDoc(_ path: String) -> XMLElement? {
        guard var data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        if !path.lowercased().hasSuffix(".xml") {
            guard let a = data.range(of: Data("<?xml".utf8)) else { return nil }
            var end: Range<Data.Index>?
            for tag in ["</SubtitleReel>", "</DCSubtitle>"] { if let r = data.range(of: Data(tag.utf8), in: a.lowerBound..<data.endIndex) { end = r; break } }
            guard let e = end else { return nil }
            data = Data(data[a.lowerBound..<e.upperBound])
        }
        return (try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]))?.rootElement()
    }
    /// "HH:MM:SS:FF" (SMPTE: fotogrammi), "HH:MM:SS:TTT" (Interop: 1/250 di secondo) o "HH:MM:SS.mmm".
    private static func timecode(_ s: String, rate: Double, interop: Bool) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let dot = t.lastIndex(of: "."), t.filter({ $0 == ":" }).count == 2 {
            let p = t[..<dot].split(separator: ":").compactMap { Double($0) }; guard p.count == 3, let f = Double("0" + t[dot...]) else { return nil }
            return p[0] * 3600 + p[1] * 60 + p[2] + f
        }
        let p = t.split(separator: ":").compactMap { Double($0) }
        guard p.count == 4 else { return nil }
        return p[0] * 3600 + p[1] * 60 + p[2] + p[3] / (interop ? 250 : max(1, rate))
    }
    private static func parseSubtitles(_ path: String, offset: Double) -> [Cue] {
        guard let root = subtitleDoc(path) else { return [] }
        let interop = root.ln == "DCSubtitle"
        let r = Double(root.text("TimeCodeRate") ?? "") ?? rate(root.text("EditRate"))
        var out: [Cue] = []
        for s in root.desc("Subtitle") {
            guard let a = s.attribute(forName: "TimeIn")?.stringValue, let b = s.attribute(forName: "TimeOut")?.stringValue,
                  let t0 = timecode(a, rate: r, interop: interop), let t1 = timecode(b, rate: r, interop: interop) else { continue }
            let lines = s.desc("Text").map { ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if lines.isEmpty { continue }   // (sottotitoli a immagini PNG: non supportati)
            out.append(Cue(t0: max(0, t0 + offset), t1: max(0, t1 + offset), text: lines.joined(separator: "\n")))
        }
        return out
    }
    private static func srtText(_ cues: [Cue]) -> String {
        func ts(_ x: Double) -> String { let ms = Int((x * 1000).rounded()); return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000) }
        return cues.sorted { $0.t0 < $1.t0 }.enumerated().map { "\($0.offset + 1)\n\(ts($0.element.t0)) --> \(ts($0.element.t1))\n\($0.element.text)\n" }.joined(separator: "\n")
    }
}

extension XMLElement {
    /// Nome senza prefisso di namespace.
    var ln: String { localName ?? name ?? "" }
    func kids(_ n: String) -> [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.ln == n } }
    func kid(_ n: String) -> XMLElement? { kids(n).first }
    func text(_ n: String) -> String? { kid(n)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Tutti i discendenti con quel nome (in ordine di documento).
    func desc(_ n: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for c in (children ?? []).compactMap({ $0 as? XMLElement }) { if c.ln == n { out.append(c) }; out += c.desc(n) }
        return out
    }
}
