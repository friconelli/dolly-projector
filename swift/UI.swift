import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: utilità
func confirm(_ message: String, ok: String = "OK", _ action: @escaping () -> Void) {
    let a = NSAlert(); a.messageText = message; a.addButton(withTitle: ok); a.addButton(withTitle: "Annulla")
    if let w = NSApp.keyWindow { a.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { action() } } }
    else if a.runModal() == .alertFirstButtonReturn { action() }
}
func showError(_ m: String) { let a = NSAlert(); a.messageText = "Errore"; a.informativeText = m; a.alertStyle = .warning; a.runModal() }
func fmt(_ s: Double) -> String {
    let t = max(0, Int(s.rounded())); let h = t / 3600, m = t % 3600 / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
func tc(_ s: Double) -> String { let t = max(0, Int(s)); return String(format: "%02d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) }
func pickFiles(folders: Bool = false, types: [String] = ["mp4", "avi", "mkv"], multiple: Bool = true, prompt: String) -> [String] {
    let p = NSOpenPanel(); p.canChooseFiles = !folders; p.canChooseDirectories = folders; p.allowsMultipleSelection = multiple; p.message = prompt
    if !folders { p.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) } }
    return p.runModal() == .OK ? p.urls.map { $0.path } : []
}
extension Color {
    /// "#RRGGBB" o "#AARRGGBB" (formato di mpv)
    init(mpv hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex; var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
        if h.count >= 8 { self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: Double((v >> 24) & 255) / 255) }
        else { self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: 1) }
    }
    func mpv(withAlpha: Bool) -> String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded()), a = Int((c.alphaComponent * 255).rounded())
        return withAlpha ? String(format: "#%02X%02X%02X%02X", a, r, g, b) : String(format: "#%02X%02X%02X", r, g, b)
    }
}
extension String { var noExt: String { (self as NSString).deletingPathExtension } }
let cueRed = Color(red: 0.88, green: 0.23, blue: 0.18)

// MARK: stile
struct Card<Content: View>: View {
    var title: String? = nil; var symbol: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = title { Label { Text(t).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).tracking(0.6) } icon: { if let s = symbol { Image(systemName: s) } }.foregroundStyle(.secondary) }
            content
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}
struct FieldLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).frame(width: 112, alignment: .leading) }
}
struct IconButton: View {
    let symbol: String; var help = ""; var size: CGFloat = 13; var tint: Color? = nil; let action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: symbol).font(.system(size: size, weight: .medium)).frame(width: 26, height: 24) }.buttonStyle(.borderless).foregroundStyle(tint ?? .secondary).help(help) }
}
struct PillToggle: View {
    let symbol: String; let label: String; @Binding var isOn: Bool; var help = ""
    var body: some View {
        Button { isOn.toggle() } label: {
            Label(label, systemImage: symbol).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08))).foregroundStyle(isOn ? Color.white : Color.primary)
        }.buttonStyle(.plain).help(help)
    }
}

/// Campo numerico opzionale: si conferma con Invio o uscendo dal campo; vuoto = valore generale.
struct OptField: View {
    let label: String; let value: Double?; let placeholder: String; var width: CGFloat = 76; let commit: (String) -> Void
    @State private var text = ""; @FocusState private var focus: Bool
    var body: some View {
        HStack { FieldLabel(label)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).frame(width: width).focused($focus).onSubmit { commit(text) } }
        .onChange(of: focus) { f in if !f { commit(text) } }
        .onAppear { text = show(value) }.onChange(of: value) { v in if !focus { text = show(v) } }
    }
    func show(_ v: Double?) -> String { v.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" }
}
struct TextRow: View {
    let label: String; let value: String; let placeholder: String; let commit: (String) -> Void
    @State private var text = ""; @FocusState private var focus: Bool
    var body: some View {
        HStack { FieldLabel(label)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).focused($focus).onSubmit { commit(text) } }
        .onChange(of: focus) { f in if !f { commit(text) } }
        .onAppear { text = value }.onChange(of: value) { v in if !focus { text = v } }
    }
}
struct PropSlider: View {
    @ObservedObject var engine: Engine
    let prop: String; let label: String; let range: ClosedRange<Double>; var step = 1.0; var reset: Double? = nil; var fmtv: (Double) -> String = { String(format: "%.2f", $0) }
    @State private var drag: Double?
    var body: some View {
        let cur = drag ?? engine.snap.d(prop, reset ?? range.lowerBound)
        HStack(spacing: 8) {
            FieldLabel(label)
            Slider(value: Binding(get: { cur }, set: { drag = $0; engine.send(["a": "set", "p": prop, "v": $0]) }), in: range, step: step) { e in if !e { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { drag = nil } } }.controlSize(.small)
            Text(fmtv(cur)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
            if let r = reset { IconButton(symbol: "arrow.counterclockwise", help: "Valore iniziale", size: 11) { engine.send(["a": "set", "p": prop, "v": r]) } }
        }
    }
}
/// Barra di avanzamento sottile in stile lettore professionale.
struct ScrubBar: View {
    let value: Double, total: Double, enabled: Bool; let commit: (Double) -> Void
    @State private var drag: Double?; @State private var hover = false
    var body: some View {
        GeometryReader { g in
            let frac = min(1, max(0, (drag ?? value) / max(1, total)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(enabled ? Color.accentColor : Color.secondary).frame(width: g.size.width * frac)
                Circle().fill(Color.white).shadow(radius: 1.5).frame(width: hover || drag != nil ? 13 : 0, height: 13).offset(x: g.size.width * frac - 6.5)
            }
            .frame(height: 5).frame(maxHeight: .infinity)
            .contentShape(Rectangle()).onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0).onChanged { if enabled { drag = Double(min(1, max(0, $0.location.x / g.size.width))) * total } }
                .onEnded { _ in if let d = drag { commit(d); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { drag = nil } } })
        }.frame(height: 20)
    }
}

// MARK: vista principale
struct RootView: View {
    @ObservedObject var engine: Engine
    @StateObject private var live = LivePreview()
    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(engine: engine)
            Divider()
            HStack(spacing: 0) {
                ScalettaPanel(engine: engine).frame(width: 340).background(.regularMaterial)
                Divider()
                MonitorPanel(engine: engine, live: live).frame(minWidth: 520)
                Divider()
                Inspector(engine: engine).frame(width: 360).background(.regularMaterial)
            }
        }
        .frame(minWidth: 1240, minHeight: 720).background(Color(nsColor: .windowBackgroundColor))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refreshLive() }
        .onAppear { refreshLive() }
        .onChange(of: engine.snap.pid) { _ in refreshLive() }
    }
    func refreshLive() {
        let on = UserDefaults.standard.object(forKey: "preview") as? Bool ?? true
        live.update(pid: engine.snap.pid, enabled: on)
        engine.setPreview(on && live.status != .live)   // le immagini a scatti servono solo se la cattura fluida non è attiva
    }
}

struct HeaderBar: View {
    @ObservedObject var engine: Engine
    var s: Snap { engine.snap }
    var current: String { s.items.indices.contains(s.idx) ? s.items[s.idx].label : "" }
    var body: some View {
        HStack(spacing: 12) {
            Circle().strokeBorder(cueRed, lineWidth: 3.5).frame(width: 15, height: 15)
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer()
            if let e = s.err { Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).lineLimit(1) }
            else if s.restarts > 0 { Text("player riavviato \(s.restarts)×").font(.callout).foregroundStyle(.secondary) }
            if let r = s.resume, s.mode == "idle", s.items.indices.contains(r.idx) {
                Button { engine.send(["a": "resume"]) } label: { Label("Riprendi \(s.items[r.idx].label) da \(fmt(r.pos))", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
            }
            HStack(spacing: 6) { Circle().fill(color).frame(width: 8, height: 8); Text(pill).font(.system(size: 12, weight: .semibold)) }
                .padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(color.opacity(0.14))).foregroundStyle(color)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
    var title: String {
        switch s.mode {
        case "gap": return s.label.isEmpty ? "Nero" : s.label
        case "playing", "wait": return current
        default: return s.items.indices.contains(s.sel) ? "Prossimo: " + s.items[s.sel].label : "Nessun elemento"
        }
    }
    var looping: Bool { let v = s.s("loop-file"); return !v.isEmpty && v != "no" }
    var pill: String {
        if !s.ok { return "player non risponde" }
        switch s.mode {
        case "gap": return "NERO \(Int(s.left))″"
        case "wait": return "INTERVALLO \(fmt(s.left))"
        case "playing": return s.pause ? "IN PAUSA" : (looping ? "IN ONDA · RIPETE" : "IN ONDA")
        default: return "PRONTO"
        }
    }
    var color: Color { !s.ok ? .red : s.mode == "playing" ? (s.pause ? .orange : cueRed) : (s.mode == "gap" || s.mode == "wait") ? .orange : .secondary }
}

// MARK: scaletta
struct ScalettaPanel: View {
    @ObservedObject var engine: Engine
    var s: Snap { engine.snap }
    @State private var nameText = ""; @FocusState private var nameFocus: Bool
    @State private var gear: Int?
    @State private var showPause = false; @State private var showBlack = false
    @State private var pmin = "10"; @State private var ptxt = "Intervallo"; @State private var bsec = "5"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                TextField("Nome della scena", text: $nameText).textFieldStyle(.plain).font(.system(size: 14, weight: .semibold)).focused($nameFocus).onSubmit { engine.send(["a": "rename", "v": nameText]) }
                Menu {
                    Button("Salva la scena") { engine.send(["a": "rename", "v": nameText]); engine.send(["a": "pl_save", "name": nameText]) }
                    Menu("Apri una scena salvata") { ForEach(s.saved, id: \.self) { n in Button(n) { confirmIf(!s.items.isEmpty, "Sostituire la scaletta corrente con “\(n)”?") { engine.send(["a": "pl_load", "name": n]) } } } }.disabled(s.saved.isEmpty)
                    Menu("Elimina una scena salvata") { ForEach(s.saved, id: \.self) { n in Button(n) { confirm("Eliminare la scena salvata “\(n)”?") { engine.send(["a": "pl_delete", "name": n]) } } } }.disabled(s.saved.isEmpty)
                    Divider()
                    Button("Importa una playlist .m3u…") { if let p = pickFiles(types: ["m3u", "m3u8"], multiple: false, prompt: "Scegli una scaletta (.m3u)").first { engine.send(["a": "pl_import", "path": p]) } }
                    Button("Svuota la scaletta") { confirm("Svuotare la scaletta?") { engine.send(["a": "clear"]) } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if s.items.isEmpty {
                VStack(spacing: 8) { Image(systemName: "film.stack").font(.system(size: 30)).foregroundStyle(.tertiary); Text("Scaletta vuota").foregroundStyle(.secondary)
                    Text("Aggiungi film con il pulsante + qui sotto.").font(.caption).foregroundStyle(.tertiary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(s.items.enumerated()), id: \.offset) { i, it in
                        ItemRow(engine: engine, i: i, it: it, gear: $gear).listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)).listRowSeparator(.hidden)
                    }.onMove { from, to in
                        guard let f = from.first else { return }
                        engine.send(["a": "reorder", "from": f, "to": to > f ? to - 1 : to])
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            Divider()
            HStack(spacing: 8) {
                Menu {
                    Button("Film (mp4, avi, mkv)…") { let p = pickFiles(prompt: "Aggiungi film (mp4, avi, mkv)"); if !p.isEmpty { engine.send(["a": "add", "paths": p]) } }
                    Button("Tutti i film di una cartella…") { let p = pickFiles(folders: true, multiple: false, prompt: "Aggiungi tutti i film di una cartella"); if !p.isEmpty { engine.send(["a": "add", "paths": p]) } }
                    Button("Tutta la libreria") { engine.send(["a": "addlib"]) }
                    Divider()
                    Button("Nero (secondi)…") { showBlack = true }
                    Button("Intervallo con conto alla rovescia…") { showPause = true }
                } label: { Label("Aggiungi", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Text("\(s.items.count) elementi").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
        .onAppear { nameText = s.name }.onChange(of: s.name) { if !nameFocus { nameText = $0 } }
        .popover(isPresented: $showBlack, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) { Text("Aggiungi un nero").font(.headline)
                HStack { TextField("5", text: $bsec).textFieldStyle(.roundedBorder).frame(width: 60); Text("secondi") }
                Text("Schermo nero tra due elementi, senza scritte.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Aggiungi") { engine.send(["a": "addblack", "secs": Double(bsec.replacingOccurrences(of: ",", with: ".")) ?? 5]); showBlack = false }.keyboardShortcut(.defaultAction) } }.padding(14).frame(width: 260)
        }
        .popover(isPresented: $showPause, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) { Text("Aggiungi un intervallo").font(.headline)
                HStack { TextField("10", text: $pmin).textFieldStyle(.roundedBorder).frame(width: 60); Text("minuti") }
                TextField("Testo sullo schermo", text: $ptxt).textFieldStyle(.roundedBorder)
                Text("Sullo schermo della sala compaiono il testo e il tempo che manca.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Aggiungi") { engine.send(["a": "addpause", "secs": (Double(pmin) ?? 10) * 60, "text": ptxt]); showPause = false }.keyboardShortcut(.defaultAction) } }.padding(14).frame(width: 300)
        }
    }
    func confirmIf(_ c: Bool, _ m: String, _ a: @escaping () -> Void) { if c { confirm(m, a) } else { a() } }
}

struct ItemRow: View {
    @ObservedObject var engine: Engine
    let i: Int; let it: ItemState; @Binding var gear: Int?
    var s: Snap { engine.snap }
    @State private var hover = false
    var body: some View {
        let cur = (s.mode == "playing" || s.mode == "wait") && s.idx == i, nxt = (s.mode == "gap" && s.next == i) || (s.mode == "idle" && s.sel == i)
        HStack(spacing: 10) {
            Button { play() } label: {
                ZStack { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(cur ? cueRed : Color.primary.opacity(0.10)).frame(width: 30, height: 30)
                    Image(systemName: cur ? "waveform" : (hover ? "play.fill" : icon)).font(.system(size: 12, weight: .semibold)).foregroundStyle(cur ? .white : .secondary) }
            }.buttonStyle(.plain).help("Avvia")
            VStack(alignment: .leading, spacing: 1) {
                Text(it.label).font(.system(size: 13, weight: .medium)).strikethrough(!it.ok).foregroundStyle(it.ok ? Color.primary : .red).lineLimit(1)
                if !caption.isEmpty { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if it.loop != 0 { Image(systemName: "repeat").font(.system(size: 11)).foregroundStyle(.secondary).help(it.loop < 0 ? "Si ripete all'infinito" : "Si ripete \(it.loop) volte") }
            IconButton(symbol: "slider.horizontal.3", help: "Impostazioni di questo elemento") { gear = gear == i ? nil : i }
                .popover(isPresented: Binding(get: { gear == i }, set: { if !$0 && gear == i { gear = nil } }), arrowEdge: .trailing) { ItemSettings(engine: engine, i: i, it: it).frame(width: 340) }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(cur ? cueRed.opacity(0.10) : (hover ? Color.primary.opacity(0.05) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(nxt ? Color.orange.opacity(0.7) : .clear, lineWidth: 1.2))
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { play() }
        .contextMenu {
            Button("Avvia") { play() }; Button("Impostazioni…") { gear = i }; Divider()
            Button("Sposta su") { engine.send(["a": "move", "i": i, "d": -1]) }.disabled(i == 0)
            Button("Sposta giù") { engine.send(["a": "move", "i": i, "d": 1]) }.disabled(i == s.items.count - 1)
            Divider(); Button("Rimuovi dalla scaletta") { confirm("Togliere dalla scaletta?") { engine.send(["a": "remove", "i": i]) } }
        }
    }
    var icon: String { it.kind == "pausa" ? "cup.and.saucer" : it.kind == "nero" ? "moon.zzz" : "film" }
    var caption: String {
        var p: [String] = []
        if it.kind == "pausa" || it.kind == "nero" { p.append(fmt(it.secs)) }
        if let a = it.pre { p.append("nero prima \(Int(a))″") }
        if let a = it.post { p.append("nero dopo \(Int(a))″") }
        if !it.alang.isEmpty || !it.slang.isEmpty { p.append((it.alang.isEmpty ? "—" : it.alang) + " → " + (it.slang.isEmpty ? "—" : it.slang)) }
        if let m = it.submode { p.append(["file": "sott. del file", "none": "senza sott.", "forced": "sott. forzati", "full": "sott. completi"][m] ?? "") }
        if let v = it.vol { p.append("vol \(Int(v))%") }
        return p.joined(separator: " · ")
    }
    func play() { if s.mode == "idle" { engine.send(["a": "play", "i": i]) } else { confirm("Cambiare? Quello in corso si interrompe.") { engine.send(["a": "play", "i": i]) } } }
}

/// Impostazioni di un singolo elemento (riquadro a comparsa, niente accordion).
struct ItemSettings: View {
    @ObservedObject var engine: Engine
    let i: Int; let it: ItemState
    var s: Snap { engine.snap }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(it.label).font(.headline).lineLimit(1)
            if it.kind == "pausa" || it.kind == "nero" {
                if it.kind == "pausa" { TextRow(label: "Testo", value: it.text, placeholder: "Intervallo") { engine.send(["a": "setitem", "i": i, "text": $0]) } }
                OptField(label: "Durata (s)", value: it.secs, placeholder: "") { engine.send(["a": "setitem", "i": i, "secs": $0]) }
            } else {
                Group {
                    OptField(label: "Nero prima (s)", value: it.pre, placeholder: n(s.defpre)) { engine.send(["a": "setitem", "i": i, "pre": $0]) }
                    OptField(label: "Nero dopo (s)", value: it.post, placeholder: n(s.defpost)) { engine.send(["a": "setitem", "i": i, "post": $0]) }
                    OptField(label: "Volume %", value: it.vol, placeholder: "invariato") { engine.send(["a": "setitem", "i": i, "vol": $0]) }
                }
                Divider()
                TextRow(label: "Audio (lingua)", value: it.alang, placeholder: "ita,it") { engine.send(["a": "setitem", "i": i, "alang": $0]) }
                TextRow(label: "Sott. (lingua)", value: it.slang, placeholder: "es. ita") { engine.send(["a": "setitem", "i": i, "slang": $0]) }
                HStack { FieldLabel("Sottotitoli")
                    Picker("", selection: Binding(get: { it.submode ?? "" }, set: { engine.send(["a": "setitem", "i": i, "submode": $0]) })) {
                        Text("Come la scena").tag(""); Text("Come nel file").tag("file"); Text("Nessuno").tag("none"); Text("Solo forzati").tag("forced"); Text("Completi").tag("full") }.labelsHidden() }
                Text("Lingue: codici a 3 lettere separati da virgola (ita, eng, fre…). Se il film è in corso, la modifica vale subito.").font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack { FieldLabel("Ripetizione")
                    Picker("", selection: Binding(get: { it.loop < 0 ? -1 : it.loop == 0 ? 0 : 1 }, set: { engine.send(["a": "setitem", "i": i, "loop": $0 == 1 ? 1 : $0]) })) {
                        Text("Nessuna").tag(0); Text("Infinita").tag(-1); Text("Un numero di volte").tag(1) }.labelsHidden() }
                if it.loop > 0 { OptField(label: "Volte in più", value: Double(it.loop), placeholder: "1") { engine.send(["a": "setitem", "i": i, "loop": Double($0) ?? 1]) } }
                Text("Un film in ripetizione continua finché non togli “Ripeti” dai controlli; poi la scaletta prosegue.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14)
    }
    func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
}

// MARK: monitor e trasporto
struct MonitorPanel: View {
    @ObservedObject var engine: Engine
    @ObservedObject var live: LivePreview
    var s: Snap { engine.snap }
    @AppStorage("preview") private var on = true
    let clean = ProcessInfo.processInfo.environment["DOLLY_CLEAN"] != nil   // solo per gli screenshot del sito
    var body: some View {
        VStack(spacing: 14) {
            monitor
            timecode
            transport
            Spacer(minLength: 0)
        }.padding(16)
    }
    var monitor: some View {
        ZStack {
            Rectangle().fill(.black)
            if on && live.status == .live { LiveLayerView(layer: live.layer) }
            else if on, s.mode == "playing", let im = engine.previewImage { Image(nsImage: im).resizable().scaledToFit() }
            else if s.mode == "wait" { Text(s.items.indices.contains(s.idx) && s.items[s.idx].kind == "pausa" ? (s.items[s.idx].text + "\n" + fmt(s.left)) : "").multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75)).font(.title2) }
            else { Text(s.mode == "playing" ? (on ? "Anteprima in arrivo…" : "Anteprima spenta") : "NERO").font(.system(size: 13, weight: .medium)).tracking(2).foregroundStyle(.white.opacity(0.35)) }
            VStack { HStack {
                Text(badge).font(.system(size: 10, weight: .bold)).tracking(1).padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(badgeColor)).foregroundStyle(.white)
                Spacer()
                if on && live.status != .live && !clean { Text(note).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)) }
            }; Spacer() }.padding(10)
        }
        .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
        .overlay(alignment: .bottomTrailing) { if on && live.status == .noPermission && !clean { permissionHint.padding(10) } }
        .contextMenu { Toggle("Anteprima attiva", isOn: $on) }
    }
    var badge: String { s.mode == "playing" ? "PROIETTORE" : s.mode == "wait" ? "INTERVALLO" : "NERO" }
    var badgeColor: Color { s.mode == "playing" ? cueRed.opacity(0.9) : Color.white.opacity(0.18) }
    var note: String { live.status == .noPermission ? "anteprima a scatti (manca il permesso)" : "anteprima a scatti" }
    var permissionHint: some View {
        Button { live.requestPermission() } label: { Label("Consenti l'anteprima fluida", systemImage: "play.rectangle.on.rectangle") }.buttonStyle(.borderedProminent).controlSize(.small)
            .help("Dolly Projector mostra la finestra del proiettore con la Registrazione schermo di macOS. Consenti Dolly Projector in Impostazioni → Privacy e sicurezza → Registrazione schermo e riapri l'app.")
    }
    var timecode: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if s.mode == "gap" || s.mode == "wait" {
                Text(fmt(s.left)).font(.system(size: 30, weight: .medium, design: .monospaced)).foregroundStyle(.orange)
                Text(s.mode == "gap" ? "nero prima di “\(s.items.indices.contains(s.next) ? s.items[s.next].label : "")”" : "intervallo").foregroundStyle(.secondary)
            } else {
                Text(tc(s.time)).font(.system(size: 30, weight: .medium, design: .monospaced))
                Text("−\(tc(max(0, s.dur - s.time)))").font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary)
                Text("/ \(tc(s.dur))").font(.system(size: 14, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { ScrubBar(value: s.time, total: max(1, s.dur), enabled: s.mode == "playing") { engine.send(["a": "seek", "v": $0]) }.offset(y: 30) }
        .padding(.bottom, 26)
    }
    var transport: some View {
        VStack(spacing: 14) {
            HStack(spacing: 22) {
                Button { engine.send(["a": "prev"]) } label: { Image(systemName: "backward.end.fill").font(.system(size: 17)) }.help("Inizio del film / precedente")
                Button { engine.send(["a": "toggle"]) } label: {
                    Image(systemName: s.mode == "playing" && !s.pause ? "pause.fill" : "play.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).frame(width: 54, height: 54).background(Circle().fill(Color.accentColor))
                }.help("Avvia / pausa (spazio)")
                Button { engine.send(["a": "next"]) } label: { Image(systemName: "forward.end.fill").font(.system(size: 17)) }.help("Successivo")
                Button { confirm("Fermare e tornare allo schermo nero?") { engine.send(["a": "stop"]) } } label: { Image(systemName: "stop.fill").font(.system(size: 15)) }.help("Ferma e schermo nero")
                if s.mode == "gap" || s.mode == "wait" { Button { engine.send(["a": "skipgap"]) } label: { Label("Salta", systemImage: "forward.fill") }.buttonStyle(.bordered) }
                if s.mode == "wait" { Button { engine.send(["a": "extend", "v": 60]) } label: { Label("+1 min", systemImage: "plus") }.buttonStyle(.bordered) }
            }.buttonStyle(.plain)
            HStack(spacing: 8) {
                PillToggle(symbol: "repeat", label: "Ripeti", isOn: Binding(get: { let v = s.s("loop-file"); return !v.isEmpty && v != "no" }, set: { engine.send(["a": "set", "p": "loop-file", "v": $0 ? "inf" : "no"]) }), help: "Il film in corso ricomincia da capo; togli per proseguire con la scaletta")
                PillToggle(symbol: "eye.slash", label: "Nero immagine", isOn: Binding(get: { s.video.count > 0 && !s.video.contains { $0.sel } }, set: { engine.send(["a": "vid", "v": $0 ? "no" : "auto"]) }), help: "Toglie l’immagine, l’audio continua")
                PillToggle(symbol: "speaker.slash", label: "Muto", isOn: Binding(get: { s.b("mute") }, set: { engine.send(["a": "set", "p": "mute", "v": $0]) }))
                Spacer()
                Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                VolumeSlider(engine: engine).frame(width: 130)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
struct VolumeSlider: View {
    @ObservedObject var engine: Engine
    @State private var drag: Double?
    var body: some View {
        let cur = drag ?? engine.snap.d("volume", 100)
        HStack(spacing: 6) {
            Slider(value: Binding(get: { cur }, set: { drag = $0; engine.send(["a": "set", "p": "volume", "v": $0]) }), in: 0...130) { e in if !e { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { drag = nil } } }.controlSize(.small)
            Text("\(Int(cur))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
        }
    }
}

// MARK: pannello destro a schede
struct Inspector: View {
    @ObservedObject var engine: Engine
    @State private var tab = Int(ProcessInfo.processInfo.environment["DOLLY_TAB"] ?? "") ?? 0   // (DOLLY_TAB serve solo per gli screenshot di verifica)
    let tabs: [(String, String)] = [("slider.horizontal.3", "Scena"), ("speaker.wave.2", "Audio"), ("captions.bubble", "Sottotitoli"), ("camera.filters", "Immagine"), ("ellipsis.circle", "Altro")]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                    Button { tab = i } label: {
                        VStack(spacing: 3) { Image(systemName: t.0).font(.system(size: 15)); Text(t.1).font(.system(size: 10, weight: .medium)) }
                            .frame(maxWidth: .infinity).padding(.vertical, 7).foregroundStyle(tab == i ? Color.accentColor : .secondary)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tab == i ? Color.accentColor.opacity(0.12) : .clear))
                    }.buttonStyle(.plain)
                }
            }.padding(8)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    switch tab {
                    case 0: SceneTab(engine: engine)
                    case 1: AudioTab(engine: engine)
                    case 2: SubsTab(engine: engine)
                    case 3: ImageTab(engine: engine)
                    default: MoreTab(engine: engine)
                    }
                }.padding(12)
            }
        }
    }
}

struct SceneTab: View {
    @ObservedObject var engine: Engine
    var s: Snap { engine.snap }
    @State private var libOpen = false
    var body: some View {
        Card(title: "Nero e avanzamento", symbol: "moon.zzz") {
            OptField(label: "Nero iniziale (s)", value: s.defpre, placeholder: "0") { engine.send(["a": "defaults", "defpre": Double($0) ?? 0]) }
            OptField(label: "Nero finale (s)", value: s.defpost, placeholder: "0") { engine.send(["a": "defaults", "defpost": Double($0) ?? 0]) }
            Text("Ogni elemento può avere il suo valore (icona delle impostazioni nella scaletta). Tra due elementi il nero è: finale del primo + iniziale del secondo.").font(.caption).foregroundStyle(.secondary)
            Toggle("Avanza automaticamente", isOn: Binding(get: { s.auto }, set: { engine.send(["a": "defaults", "auto": $0]) })).toggleStyle(.switch)
            Toggle("Ripeti la scaletta", isOn: Binding(get: { s.loop }, set: { engine.send(["a": "defaults", "loop": $0]) })).toggleStyle(.switch)
        }
        Card(title: "Sottotitoli della scena", symbol: "captions.bubble") {
            Picker("", selection: Binding(get: { s.defsub }, set: { engine.send(["a": "defaults", "defsub": $0]) })) {
                Text("Come nel file").tag("file"); Text("Nessuno").tag("none"); Text("Solo forzati").tag("forced"); Text("Completi").tag("full") }.pickerStyle(.segmented).labelsHidden()
            Text(["file": "Si accende la traccia che il file indica come predefinita.", "none": "Nessun sottotitolo, a meno che un film non ne chieda.", "forced": "Solo i sottotitoli “forzati”: le traduzioni dei dialoghi stranieri.", "full": "Sottotitoli completi nella lingua dell’audio."][s.defsub] ?? "")
                .font(.caption).foregroundStyle(.secondary)
        }
        Card(title: "Cartella dei film", symbol: "folder") {
            HStack { Text((s.folder as NSString).lastPathComponent).lineLimit(1); Spacer(); Button("Cambia…") { appDelegate.changeFolder() }.help("La scaletta riparte dai film della nuova cartella") }
            Button(libOpen ? "Nascondi l'elenco" : "Mostra l'elenco dei film") { libOpen.toggle() }.buttonStyle(.link)
            if libOpen {
                ForEach(Array(s.lib.enumerated()), id: \.offset) { i, n in HStack { Text(n.noExt).lineLimit(1).font(.callout); Spacer(); IconButton(symbol: "plus.circle", help: "Aggiungi alla scaletta") { engine.send(["a": "addlib", "i": i]) } } }
            }
        }
    }
}

struct AudioTab: View {
    @ObservedObject var engine: Engine
    var s: Snap { engine.snap }
    var body: some View {
        Card(title: "Uscita e tracce", symbol: "speaker.wave.2") {
            HStack { FieldLabel("Uscita")
                Picker("", selection: Binding(get: { s.s("audio-device") }, set: { engine.send(["a": "set", "p": "audio-device", "v": $0]) })) { ForEach(s.adevs, id: \.id) { Text($0.t).tag($0.id) } }.labelsHidden() }
            HStack { FieldLabel("Traccia")
                Picker("", selection: Binding(get: { s.audio.first { $0.sel }?.id ?? 0 }, set: { engine.send(["a": "aid", "v": $0]) })) { ForEach(s.audio) { Text($0.t).tag($0.id) } }.labelsHidden().disabled(s.audio.isEmpty) }
            HStack { FieldLabel("Canali")
                Picker("", selection: Binding(get: { s.s("audio-channels").isEmpty ? "auto-safe" : s.s("audio-channels") }, set: { engine.send(["a": "set", "p": "audio-channels", "v": $0]) })) {
                    Text("Originali").tag("auto-safe"); Text("Stereo (mix)").tag("stereo"); Text("Mono").tag("mono"); Text("5.1").tag("5.1") }.labelsHidden() }
            PropSlider(engine: engine, prop: "audio-delay", label: "Sincronia", range: -5...5, step: 0.05, reset: 0, fmtv: { String(format: "%.2f s", $0) })
        }
    }
}

struct SubsTab: View {
    @ObservedObject var engine: Engine
    var s: Snap { engine.snap }
    var body: some View {
        Card(title: "Traccia", symbol: "captions.bubble") {
            HStack { FieldLabel("Traccia")
                Picker("", selection: Binding(get: { s.sub.first { $0.sel }?.id ?? -1 }, set: { engine.send(["a": "sid", "v": $0 < 0 ? "no" : String($0)]) })) { Text("Nessuno").tag(-1); ForEach(s.sub) { Text($0.t).tag($0.id) } }.labelsHidden() }
            PropSlider(engine: engine, prop: "sub-delay", label: "Ritardo", range: -10...10, step: 0.1, reset: 0, fmtv: { String(format: "%.1f s", $0) })
            Toggle("Mostra sottotitoli", isOn: Binding(get: { s.props["sub-visibility"]?.b ?? true }, set: { engine.send(["a": "set", "p": "sub-visibility", "v": $0]) })).toggleStyle(.switch)
        }
        SubStyle(engine: engine)
    }
}

struct SubStyle: View {
    @ObservedObject var engine: Engine
    var s: Snap { engine.snap }
    static let presets: [String: [String: Any]] = [
        "classic": ["sub-font": "Helvetica Neue", "sub-font-size": 42, "sub-color": "#FFFFFF", "sub-border-color": "#000000", "sub-border-size": 2.2, "sub-back-color": "#00000000", "sub-shadow-offset": 1, "sub-bold": false, "sub-italic": false, "sub-pos": 96],
        "yellow": ["sub-font": "Arial", "sub-font-size": 44, "sub-color": "#FFE000", "sub-border-color": "#000000", "sub-border-size": 3.5, "sub-back-color": "#00000000", "sub-shadow-offset": 1.5, "sub-bold": true, "sub-italic": false, "sub-pos": 96],
        "big": ["sub-font": "Helvetica Neue", "sub-font-size": 58, "sub-color": "#FFFFFF", "sub-border-color": "#000000", "sub-border-size": 4, "sub-back-color": "#80000000", "sub-shadow-offset": 0, "sub-bold": true, "sub-italic": false, "sub-pos": 94]]
    static let fonts: [String] = NSFontManager.shared.availableFontFamilies.sorted()
    func color(_ k: String, alpha: Bool) -> Binding<Color> {
        Binding(get: { Color(mpv: s.s(k).isEmpty ? "#FFFFFF" : s.s(k)) }, set: { engine.send(["a": "set", "p": k, "v": $0.mpv(withAlpha: alpha)]) })
    }
    /// La traccia in uso è un'immagine (PGS/DVD): font e colori non si possono cambiare.
    var bitmapTrack: Bool { let t = s.sub.first { $0.sel }?.t.lowercased() ?? ""; return t.contains("pgs") || t.contains("dvd_sub") || t.contains("dvb") || t.contains("xsub") }
    func swatch(_ label: String, _ key: String, alpha: Bool) -> some View {
        VStack(spacing: 5) {
            ColorPicker("", selection: color(key, alpha: alpha), supportsOpacity: alpha).labelsHidden().frame(width: 52, height: 28)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
    var body: some View {
        Card(title: "Stile (salvato come predefinito)", symbol: "textformat") {
            if bitmapTrack {
                Label("Questa traccia è un’immagine (PGS/DVD): font e colori non si possono cambiare, valgono solo posizione e scala.", systemImage: "info.circle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach([("classic", "Classico"), ("yellow", "Giallo"), ("big", "Grande")], id: \.0) { p in
                    Button(p.1) { engine.send(["a": "setmany", "props": SubStyle.presets[p.0]!]) }.buttonStyle(.bordered).controlSize(.small) }
                Spacer()
                Button { confirm("Ripristinare lo stile iniziale dei sottotitoli (font, colori, dimensione, bordo, posizione)?", ok: "Ripristina") { engine.send(["a": "resetsubstyle"]) } } label: { Label("Ripristina", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.bordered).controlSize(.small).help("Riporta tutto lo stile dei sottotitoli allo stato iniziale")
            }
            HStack { FieldLabel("Font")
                Picker("", selection: Binding(get: { s.s("sub-font") }, set: { engine.send(["a": "set", "p": "sub-font", "v": $0]) })) {
                    if !SubStyle.fonts.contains(s.s("sub-font")) { Text(s.s("sub-font")).tag(s.s("sub-font")) }
                    ForEach(SubStyle.fonts, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                Toggle(isOn: Binding(get: { s.b("sub-bold") }, set: { engine.send(["a": "set", "p": "sub-bold", "v": $0]) })) { Image(systemName: "bold") }.toggleStyle(.button).help("Grassetto")
                Toggle(isOn: Binding(get: { s.b("sub-italic") }, set: { engine.send(["a": "set", "p": "sub-italic", "v": $0]) })) { Image(systemName: "italic") }.toggleStyle(.button).help("Corsivo") }
            PropSlider(engine: engine, prop: "sub-font-size", label: "Dimensione", range: 20...120, step: 1, fmtv: { "\(Int($0))" })
            HStack(alignment: .top, spacing: 0) {
                swatch("Testo", "sub-color", alpha: false)
                swatch("Bordo", "sub-border-color", alpha: false)
                swatch("Sfondo", "sub-back-color", alpha: true)
            }.padding(.vertical, 2)
            PropSlider(engine: engine, prop: "sub-border-size", label: "Bordo", range: 0...10, step: 0.25)
            PropSlider(engine: engine, prop: "sub-shadow-offset", label: "Ombra", range: 0...10, step: 0.25)
            PropSlider(engine: engine, prop: "sub-pos", label: "Posizione", range: 0...100, step: 1, fmtv: { "\(Int($0))" })
            PropSlider(engine: engine, prop: "sub-scale", label: "Scala", range: 0.3...3, step: 0.05, reset: 1)
            Toggle("Usa il mio stile anche sui sottotitoli già stilizzati (ASS)", isOn: Binding(get: { s.s("sub-ass-override") != "scale" && s.s("sub-ass-override") != "no" }, set: { engine.send(["a": "set", "p": "sub-ass-override", "v": $0 ? "force" : "scale"]) })).toggleStyle(.switch).font(.callout)
        }
    }
}

struct ImageTab: View {
    @ObservedObject var engine: Engine
    var s: Snap { engine.snap }
    var body: some View {
        Card(title: "Immagine", symbol: "camera.filters") {
            ForEach([("brightness", "Luminosità", -100.0...100.0, 1.0), ("contrast", "Contrasto", -100.0...100.0, 1.0), ("saturation", "Saturazione", -100.0...100.0, 1.0), ("gamma", "Gamma", -100.0...100.0, 1.0), ("hue", "Tonalità", -100.0...100.0, 1.0)], id: \.0) { p in
                PropSlider(engine: engine, prop: p.0, label: p.1, range: p.2, step: p.3, reset: 0, fmtv: { String(Int($0)) }) }
        }
        Card(title: "Inquadratura", symbol: "crop") {
            HStack { FieldLabel("Proporzioni")
                Picker("", selection: Binding(get: { aspectTag }, set: { engine.send(["a": "set", "p": "video-aspect-override", "v": $0]) })) {
                    ForEach([("-1", "Originali"), ("16:9", "16:9"), ("4:3", "4:3"), ("1.85:1", "1.85:1"), ("2.35:1", "2.35:1"), ("2.39:1", "2.39:1"), ("1:1", "1:1")], id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden() }
            ForEach([("video-zoom", "Zoom", -1.0...2.0, 0.01), ("video-pan-x", "Sposta ←→", -1.0...1.0, 0.01), ("video-pan-y", "Sposta ↑↓", -1.0...1.0, 0.01), ("panscan", "Riempi (taglia)", 0.0...1.0, 0.05)], id: \.0) { p in
                PropSlider(engine: engine, prop: p.0, label: p.1, range: p.2, step: p.3, reset: 0) }
            HStack { Toggle("Deinterlaccia", isOn: Binding(get: { s.b("deinterlace") }, set: { engine.send(["a": "set", "p": "deinterlace", "v": $0]) })).toggleStyle(.switch); Spacer()
                Button("Ripristina") { engine.send(["a": "resetvideo"]) }.buttonStyle(.bordered).controlSize(.small) }
        }
    }
    var aspectTag: String {
        let v = s.p("video-aspect-override"); guard let x = v.d ?? Double(v.s ?? "") else { return "-1" }
        for (t, r) in [("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1.85:1", 1.85), ("2.35:1", 2.35), ("2.39:1", 2.39), ("1:1", 1.0)] where abs(r - x) < 0.01 { return t }
        return "-1"
    }
}

struct MoreTab: View {
    @ObservedObject var engine: Engine
    var s: Snap { engine.snap }
    @State private var msg = ""
    var body: some View {
        Card(title: "Capitoli e fotogramma", symbol: "list.number") {
            HStack { FieldLabel("Capitolo")
                Picker("", selection: Binding(get: { s.chapter ?? 0 }, set: { engine.send(["a": "chapter", "v": $0]) })) {
                    ForEach(Array(s.chapters.enumerated()), id: \.offset) { i, c in Text("\(c.t) (\(fmt(c.s)))").tag(i) } }.labelsHidden().disabled(s.chapters.isEmpty) }
            HStack(spacing: 8) {
                Button { engine.send(["a": "abloop"]) } label: { Label(s.ab[0] != nil ? "Loop A-B attivo" : "Loop A-B", systemImage: "arrow.left.and.right") }.buttonStyle(.bordered).controlSize(.small)
                Button { engine.send(["a": "frameback"]) } label: { Image(systemName: "backward.frame") }.help("Un fotogramma indietro")
                Button { engine.send(["a": "frame"]) } label: { Image(systemName: "forward.frame") }.help("Un fotogramma avanti")
            }
        }
        Card(title: "Messaggio sullo schermo della sala", symbol: "text.bubble") {
            HStack { TextField("Es. Si prega di spegnere i cellulari", text: $msg).textFieldStyle(.roundedBorder); Button("Mostra 8″") { engine.send(["a": "text", "v": msg, "ms": 8000]) } }
        }
        Card(title: "Anteprima e informazioni", symbol: "info.circle") {
            Toggle("Anteprima del proiettore attiva", isOn: Binding(get: { UserDefaults.standard.object(forKey: "preview") as? Bool ?? true }, set: { UserDefaults.standard.set($0, forKey: "preview") })).toggleStyle(.switch)
            Text(s.playing ? "\(s.info.res ?? "") · \(s.info.fps.map { String(format: "%.3f fps", $0) } ?? "")\n\(s.info.vcodec ?? "")\naudio \(s.info.acodec ?? "")\nfotogrammi persi: \(s.info.dropped ?? 0)" : "—")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}
