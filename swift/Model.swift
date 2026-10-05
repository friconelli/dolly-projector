import Foundation

let VIDEO_EXT: Set<String> = ["mp4", "avi", "mkv"]   // gli unici formati supportati

/// Proprietà impostabili dal telecomando: nome -> (tipo, min, max). Tutto il resto viene rifiutato.
let PROPS: [String: (kind: Character, lo: Double, hi: Double)] = [
    "sub-font": ("s", 0, 0), "sub-font-size": ("f", 10, 150), "sub-color": ("s", 0, 0), "sub-border-color": ("s", 0, 0), "sub-border-size": ("f", 0, 15),
    "sub-back-color": ("s", 0, 0), "sub-shadow-offset": ("f", 0, 15), "sub-bold": ("b", 0, 0), "sub-italic": ("b", 0, 0), "sub-ass-override": ("s", 0, 0),
    "audio-device": ("s", 0, 0), "volume": ("f", 0, 130), "mute": ("b", 0, 0), "speed": ("f", 0.25, 4), "audio-delay": ("f", -10, 10), "sub-delay": ("f", -30, 30),
    "sub-scale": ("f", 0.3, 3), "sub-pos": ("f", 0, 100), "sub-visibility": ("b", 0, 0), "video-zoom": ("f", -1, 2), "video-pan-x": ("f", -1, 1),
    "video-pan-y": ("f", -1, 1), "panscan": ("f", 0, 1), "brightness": ("f", -100, 100), "contrast": ("f", -100, 100), "saturation": ("f", -100, 100),
    "gamma": ("f", -100, 100), "hue": ("f", -100, 100), "video-aspect-override": ("s", 0, 0), "deinterlace": ("b", 0, 0), "loop-file": ("s", 0, 0),
    "audio-channels": ("s", 0, 0), "ontop": ("b", 0, 0)]
let READ_PROPS = Array(PROPS.keys)

/// Elemento di scaletta: film (mp4/avi/mkv) | pausa (intervallo con testo e conto alla rovescia) | nero (schermo nero per N secondi, senza scritte).
struct Item: Equatable {
    var kind = "film"
    var path = ""
    var pre: Double? = nil
    var post: Double? = nil
    var vol: Double? = nil
    var alang = ""
    var slang = ""
    var secs = 600.0
    var text = ""
    var loop = 0            // ripetizioni di questo film: 0 nessuna, -1 all'infinito, N volte in più
    var submode: String? = nil   // sottotitoli di questo film: nil = predefinito della scena; "file" | "none" | "forced" | "full"

    init(path: String = "", kind: String = "film", secs: Double = 600, text: String = "") { self.path = path; self.kind = kind; self.secs = secs; self.text = text }
    init(dict d: [String: Any]) {
        kind = asString(d["kind"]) ?? "film"; path = asString(d["path"]) ?? ""
        pre = asDouble(d["pre"]); post = asDouble(d["post"]); vol = asDouble(d["vol"])
        alang = asString(d["alang"]) ?? ""; slang = asString(d["slang"]) ?? ""; secs = asDouble(d["secs"]) ?? 600; text = asString(d["text"]) ?? ""
        loop = asInt(d["loop"]) ?? 0; submode = asString(d["submode"]).flatMap { $0.isEmpty ? nil : $0 }
    }
    var dict: [String: Any] {
        ["kind": kind, "path": path, "pre": pre as Any? ?? NSNull(), "post": post as Any? ?? NSNull(), "vol": vol as Any? ?? NSNull(),
         "alang": alang, "slang": slang, "secs": secs, "text": text, "loop": loop, "submode": submode as Any? ?? NSNull()]
    }
    var title: String { kind == "pausa" ? (text.isEmpty ? tr("Pausa") : text) : kind == "nero" ? trf("Nero (%@ s)", secs == secs.rounded() ? String(Int(secs)) : String(secs)) : (path as NSString).lastPathComponent }
}

func videosIn(_ path: String) -> [String] {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
    if isDir.boolValue {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
        return names.filter { !$0.hasPrefix(".") && VIDEO_EXT.contains(($0 as NSString).pathExtension.lowercased()) }.map { (path as NSString).appendingPathComponent($0) }
    }
    return VIDEO_EXT.contains((path as NSString).pathExtension.lowercased()) ? [path] : []
}

/// Stato per l'interfaccia (decodificato dal JSON dello stato del motore).
struct Track: Decodable, Identifiable, Equatable { var id: Int; var t: String; var sel: Bool }
struct Chapter: Decodable, Equatable { var t: String; var s: Double }
struct AudioDev: Decodable, Equatable { var id: String; var t: String }
struct ItemState: Decodable, Equatable {
    var kind: String; var pre: Double?; var post: Double?; var vol: Double?; var alang: String; var slang: String; var secs: Double; var text: String; var name: String; var ok: Bool; var loop: Int; var submode: String?
    var label: String { kind == "film" ? (name as NSString).deletingPathExtension : name }   // i nomi di pausa/nero possono contenere un punto
}
struct Resume: Decodable, Equatable { var idx: Int; var pos: Double }
struct Info: Decodable, Equatable { var res: String?; var fps: Double?; var vcodec: String?; var acodec: String?; var dropped: Int? }
struct Snap: Decodable {
    var ok = true
    var name = tr("Scena"); var mode = "idle"; var idx = -1; var sel = 0; var next = -1; var label = ""; var left = 0.0
    var err: String?; var restarts = 0; var auto = true; var loop = false; var defpre = 0.0; var defpost = 0.0
    var resume: Resume?; var defsub = "file"; var pid = 0; var folder = ""; var items: [ItemState] = []; var lib: [String] = []; var saved: [String] = []
    var playing = false; var pause = false; var time = 0.0; var dur = 0.0
    var audio: [Track] = []; var sub: [Track] = []; var video: [Track] = []; var chapters: [Chapter] = []; var chapter: Int?
    var ab: [Double?] = [nil, nil]; var props: [String: JSONValue] = [:]; var adevs: [AudioDev] = []; var info = Info()
    init() {}
    func p(_ k: String) -> JSONValue { props[k] ?? .null }
    func d(_ k: String, _ def: Double = 0) -> Double { props[k]?.d ?? def }
    func b(_ k: String) -> Bool { props[k]?.b ?? false }
    func s(_ k: String) -> String { props[k]?.s ?? "" }
}
