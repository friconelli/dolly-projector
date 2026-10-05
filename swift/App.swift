import SwiftUI
import AppKit

final class AppModel: ObservableObject { @Published var engine: Engine?; @Published var starting = true; @Published var langRev = 0 }   // langRev: cambia quando si sceglie un'altra lingua e fa ridisegnare tutto
struct HostView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if let e = model.engine { RootView(engine: e) }
            else if model.starting { ProgressView(tr("Avvio del player…")).padding(60).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Text(tr("Scegli la cartella dei film dal menu Dolly Projector")).padding(60).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.id(model.langRev)
    }
}

func bundledMpv() -> String {
    // Apple Silicon usa l'mpv nativo arm64 (parte subito); i Mac Intel (e il ripiego) usano quello x86_64. Con un solo mpv Rosetta dovrebbe tradurlo ad ogni nuova installazione (~20 s).
    #if arch(arm64)
    let names = ["mpv-arm64.app", "mpv-x86_64.app"]
    #else
    let names = ["mpv-x86_64.app"]
    #endif
    for n in names {
        if let b = Bundle.main.resourceURL?.appendingPathComponent(n + "/Contents/MacOS/mpv").path, FileManager.default.isExecutableFile(atPath: b) { return b }
    }
    return mpvBinary
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let defaults = UserDefaults.standard
    let model = AppModel()
    var window: NSWindow!
    var activity: NSObjectProtocol?
    var confirmed = false
    var monitor: Any?
    let startGroup = DispatchGroup()   // l'avvio del player può durare qualche secondo: chiudendo l'app nel frattempo bisogna comunque fermarlo
    var live: Engine?
    let liveLock = NSLock()
    let marker = Engine.homePath + "/running"   // presente solo mentre l'app è aperta: se c'è all'avvio, la chiusura precedente è stata imprevista

    func applicationDidFinishLaunching(_ n: Notification) {
        // niente rallentamenti di App Nap né stop del Mac mentre l'app è aperta
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled, .latencyCritical], reason: tr("Proiezione"))
        buildMenu()
        if folder() == nil && !chooseFolder() { NSApp.terminate(nil); return }
        let unclean = FileManager.default.fileExists(atPath: marker)
        try? FileManager.default.createDirectory(atPath: Engine.homePath, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker, contents: nil)
        buildWindow()
        startEngine(autoresume: unclean)
        installKeys()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !confirmed, let e = model.engine, e.snap.mode == "playing" || e.snap.mode == "wait" {
            let a = NSAlert(); a.messageText = tr("Chiudere Dolly Projector?")
            a.informativeText = tr("Il film in proiezione si interrompe e lo schermo della sala torna al nero.")
            a.addButton(withTitle: tr("Chiudi")); a.addButton(withTitle: tr("Annulla")); a.alertStyle = .warning
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        stopEngine(); try? FileManager.default.removeItem(atPath: marker)
        return .terminateNow
    }

    // MARK: cartella, schermo, motore
    func folder() -> String? { defaults.string(forKey: "folder").flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } }
    @discardableResult func chooseFolder() -> Bool {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = tr("Scegli la cartella che contiene i film (mp4, avi, mkv)"); p.prompt = tr("Scegli")
        if let f = folder() { p.directoryURL = URL(fileURLWithPath: f) }
        guard p.runModal() == .OK, let u = p.url else { return false }
        defaults.set(u.path, forKey: "folder"); return true
    }
    /// Schermo della sala: quello scelto dal menu, altrimenti l'ultimo (con 2 schermi è l'altro rispetto a quello con la barra dei menu).
    /// Scegliendo uno schermo il player va a schermo intero su quello. Con "Finestra (per le prove)" (valore -1) resta in una finestra normale.
    var screenIndex: Int {
        let n = NSScreen.screens.count
        if let s = defaults.object(forKey: "screen") as? Int { return s < 0 ? 0 : min(s, n - 1) }
        return n - 1
    }
    var windowedMode: Bool {
        if let s = defaults.object(forKey: "screen") as? Int { return s < 0 }
        return NSScreen.screens.count <= 1   // prima scelta con un solo schermo: finestra, per non coprire i controlli
    }
    /// Il player può impiegare qualche secondo ad avviarsi (la prima volta su Apple Silicon, Rosetta lo prepara): la finestra c'è subito.
    func startEngine(autoresume: Bool, resetPlaylist: Bool = false) {
        guard let f = folder() else { model.starting = false; return }
        model.starting = true
        let windowed = windowedMode, screen = screenIndex, mpv = bundledMpv()
        startGroup.enter()
        DispatchQueue.global().async {
            let r = Result { try Engine(folder: f, mpvBinary: mpv, extra: [], windowed: windowed, screen: screen, autoresume: autoresume, resetPlaylist: resetPlaylist) }
            if case .success(let e) = r { self.liveLock.lock(); self.live = e; self.liveLock.unlock() }
            self.startGroup.leave()
            DispatchQueue.main.async {
                self.model.starting = false
                switch r { case .success(let e): self.model.engine = e; RemoteControl.shared.engine = e; self.moveControlsAway(); case .failure(let e): showError(trf("Non riesco ad avviare il player: %@", "\(e)")) }
            }
        }
    }
    func stopEngine() {
        _ = startGroup.wait(timeout: .now() + 30)
        liveLock.lock(); let e = live; live = nil; liveLock.unlock()
        RemoteControl.shared.engine = nil; e?.shutdown(); model.engine = nil
    }
    func restartEngine() {
        confirm(tr("Cambiare impostazione interrompe la proiezione in corso. Continuare?"), ok: tr("Continua")) {
            self.stopEngine()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.startEngine(autoresume: false) }
        }
    }
    @objc func changeFolder() {
        let go = {
            if self.chooseFolder() { self.stopEngine(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.startEngine(autoresume: false, resetPlaylist: true) } }
        }
        if let e = model.engine, e.snap.mode == "playing" || e.snap.mode == "wait" || e.snap.mode == "gap" {
            confirm(tr("Cambiare cartella interrompe la proiezione in corso e la scaletta riparte dai film della nuova cartella. Continuare?"), ok: tr("Continua"), go)
        } else { go() }
    }
    @objc func pickScreen(_ s: NSMenuItem) {
        let apply = { self.defaults.set(s.tag, forKey: "screen"); self.restartEngine() }
        if s.tag >= 0 && NSScreen.screens.count == 1 {
            confirm(tr("Con un solo schermo il player occuperà tutto lo schermo e coprirà i controlli (torni ai controlli con ⌘Tab). Continuare?"), ok: tr("Continua"), apply)
        } else { apply() }
    }
    /// Se il player va a schermo intero sullo stesso schermo dei controlli, la finestra dei controlli passa su un altro schermo (se c'è).
    func moveControlsAway() {
        guard !windowedMode, NSScreen.screens.count > 1, let w = window else { return }
        let target = NSScreen.screens[screenIndex]
        guard let cur = w.screen, cur == target, let other = NSScreen.screens.first(where: { $0 != target }) else { return }
        let f = other.visibleFrame; w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
    }

    // MARK: finestra, tastiera, menu
    func buildWindow() {
        let host = NSHostingView(rootView: HostView(model: model))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false, screen: NSScreen.screens.first)
        window.title = "Dolly Projector"; window.contentView = host; window.delegate = self; window.minSize = NSSize(width: 900, height: 600)
        window.setFrameAutosaveName("DollyMain"); if !window.setFrameUsingName("DollyMain") { window.center() }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.window.makeFirstResponder(nil) }   // nessun campo di testo selezionato all'avvio: la tastiera comanda subito il player
    }
    func installKeys() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, let en = self.model.engine, e.window === self.window else { return e }
            if NSApp.keyWindow?.firstResponder is NSText { return e }   // si sta scrivendo in un campo
            guard e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return e }
            let big = e.modifierFlags.contains(.shift)
            switch e.keyCode {
            case 49: en.send(["a": "toggle"])
            case 123: en.send(["a": "seek", "v": big ? -60 : -10, "m": "relative"])
            case 124: en.send(["a": "seek", "v": big ? 60 : 10, "m": "relative"])
            case 126: en.send(["a": "set", "p": "volume", "v": en.snap.d("volume", 100) + 5])
            case 125: en.send(["a": "set", "p": "volume", "v": en.snap.d("volume", 100) - 5])
            case 46: en.send(["a": "set", "p": "mute", "v": !en.snap.b("mute")])
            default: return e
            }
            return nil
        }
    }
    @objc func toggleRemote(_ s: NSMenuItem) {
        let r = RemoteControl.shared; r.setEnabled(!r.enabled)
        guard r.enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let a = NSAlert(); a.messageText = tr("Telecomando attivo")
            if let u = r.urls.first {
                a.informativeText = trf("Sul telefono (stessa rete del Mac, anche senza internet) inquadra il codice o apri:\n%@\n\nPIN: %@", u, r.pin)
                if let q = RemoteControl.qr(u) { q.size = NSSize(width: 150, height: 150); a.icon = q }
            } else { a.informativeText = r.problem ?? tr("Nessuna rete trovata: collega il Mac al Wi-Fi o a un router.") }
            a.runModal()
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleRemote(_:)) { item.state = RemoteControl.shared.enabled ? .on : .off }
        return true
    }
    @objc func setLang(_ s: NSMenuItem) {
        Lang.setting = ["auto", "it", "en"][s.tag]
        buildMenu(); model.langRev += 1
    }
    func buildMenu() {
        let main = NSMenu(); NSApp.mainMenu = main
        func top(_ title: String) -> NSMenu { let m = NSMenu(title: title); let i = NSMenuItem(); i.submenu = m; main.addItem(i); return m }
        let app = top("Dolly Projector")
        app.addItem(withTitle: tr("Cambia cartella dei film…"), action: #selector(changeFolder), keyEquivalent: "").target = self
        let sc = NSMenuItem(title: tr("Schermo della sala"), action: nil, keyEquivalent: ""); let sm = NSMenu(); sm.delegate = self; sc.submenu = sm; app.addItem(sc)
        app.addItem(withTitle: tr("Controlla aggiornamenti…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "").target = self
        let rm = NSMenuItem(title: tr("Telecomando dal telefono"), action: #selector(toggleRemote(_:)), keyEquivalent: ""); rm.target = self; app.addItem(rm)
        let lm = NSMenuItem(title: tr("Lingua"), action: nil, keyEquivalent: ""); let lsub = NSMenu()
        for (n, (title, code)) in [(tr("Automatica"), "auto"), ("Italiano", "it"), ("English", "en")].enumerated() {
            let it = NSMenuItem(title: title, action: #selector(setLang(_:)), keyEquivalent: ""); it.tag = n; it.target = self; it.state = Lang.setting == code ? .on : .off; lsub.addItem(it)
        }
        lm.submenu = lsub; app.addItem(lm)
        app.addItem(.separator())
        app.addItem(withTitle: tr("Nascondi Dolly Projector"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: tr("Esci da Dolly Projector"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = top(tr("Modifica"))
        edit.addItem(withTitle: tr("Taglia"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copia"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Incolla"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Seleziona tutto"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let win = top(tr("Finestra"))
        win.addItem(withTitle: tr("Riduci a icona"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    }
    func menuNeedsUpdate(_ menu: NSMenu) {   // elenco schermi aggiornato ogni volta che si apre il menu (un proiettore può essere stato collegato dopo)
        menu.removeAllItems()
        for (i, s) in NSScreen.screens.enumerated() {
            let it = NSMenuItem(title: "\(i + 1) · \(s.localizedName)\(i == 0 ? tr(" (con la barra dei menu)") : "")", action: #selector(pickScreen(_:)), keyEquivalent: "")
            it.tag = i; it.target = self; it.state = (!windowedMode && i == screenIndex) ? .on : .off; menu.addItem(it)
        }
        menu.addItem(.separator())
        let w = NSMenuItem(title: tr("Finestra (per le prove)"), action: #selector(pickScreen(_:)), keyEquivalent: "")
        w.tag = -1; w.target = self; w.state = windowedMode ? .on : .off; menu.addItem(w)
    }
}

/// Per verificare l'aspetto senza permessi di registrazione schermo: --snapshot FILE.png [--play N] disegna la finestra e la salva.
final class SnapshotRunner {
    let engine: Engine, out: String
    var window: NSWindow!
    init(engine: Engine, out: String) { self.engine = engine; self.out = out }
    func run(play: Int?, wait: Double) {
        let host = NSHostingView(rootView: RootView(engine: engine))
        let sz = (argValue("--size") ?? "1320x1100").split(separator: "x").compactMap { Double($0) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: sz.count == 2 ? sz[0] : 1320, height: sz.count == 2 ? sz[1] : 1100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.orderBack(nil)
        if ProcessInfo.processInfo.environment["DOLLY_DARK"] == "1" { window.appearance = NSAppearance(named: .darkAqua) }   // per gli screenshot del sito
        if let p = play { _ = engine.actSync(["a": "play", "i": p]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            host.layoutSubtreeIfNeeded()
            let r = host.bounds; guard let rep = host.bitmapImageRepForCachingDisplay(in: r) else { exit(2) }
            host.cacheDisplay(in: r, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: self.out))
            self.engine.shutdown(); exit(0)
        }
    }
}
var snapshotRunner: SnapshotRunner?

var appDelegate: AppDelegate!
func runApp() {
    if let out = argValue("--snapshot") {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        do {
            let e = try Engine(folder: argValue("--folder") ?? "~/Desktop", mpvBinary: bundledMpv(), extra: (argValue("--mpv") ?? "").split(separator: " ").map(String.init), windowed: true, screen: 0, autoresume: false)
            snapshotRunner = SnapshotRunner(engine: e, out: out); snapshotRunner!.run(play: argValue("--play").flatMap { Int($0) }, wait: Double(argValue("--wait") ?? "4") ?? 4)
        } catch { log("errore:", error); exit(1) }
        app.run(); return
    }
    freopen(NSHomeDirectory() + "/Library/Logs/Dolly.log", "a", stderr)   // registro per capire cosa è successo dopo una proiezione
    setvbuf(stderr, nil, _IOLBF, 0)
    let app = NSApplication.shared
    appDelegate = AppDelegate(); app.delegate = appDelegate
    app.setActivationPolicy(.regular)
    app.run()
}
