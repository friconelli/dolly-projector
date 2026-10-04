import Foundation

var signalSources: [DispatchSourceSignal] = []

// Avvio: con --test-api PORTA gira senza finestra e offre l'interfaccia di collaudo; altrimenti è l'app con la finestra (vedi App.swift).
func argValue(_ name: String) -> String? { CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } }
let mpvBinary = ProcessInfo.processInfo.environment["DOLLY_MPV"] ?? "/Applications/mpv.app/Contents/MacOS/mpv"

// Collaudo dell'aggiornamento senza finestre: --selftest-update stampa l'esito di controllo, scarico e verifica (non sostituisce nulla).
if CommandLine.arguments.contains("--selftest-update") {
    do { let i = try Updater.fetch(); var o: [String: Any] = ["version": i.version, "newer": Updater.isNewer(i.version, than: Updater.current), "current": Updater.current]
        if CommandLine.arguments.contains("--download") { o["app"] = try Updater.download(i) }
        print(String(data: try JSONSerialization.data(withJSONObject: o), encoding: .utf8)!); exit(0)
    } catch { print("{\"error\": \"\(error)\"}"); exit(2) }
}

if let p = argValue("--test-api"), let port = UInt16(p) {
    setvbuf(stderr, nil, _IOLBF, 0)
    let folder = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") && Int($0) == nil && $0 != argValue("--mpv") } ?? "~/Desktop"
    let extra = (argValue("--mpv") ?? "").split(separator: " ").map(String.init)
    do {
        let engine = try Engine(folder: folder, mpvBinary: mpvBinary, extra: extra, windowed: CommandLine.arguments.contains("--windowed"),
                                screen: Int(argValue("--screen") ?? "0") ?? 0, autoresume: CommandLine.arguments.contains("--autoresume"), resetPlaylist: CommandLine.arguments.contains("--reset-playlist"))
        try TestServer(engine: engine, port: port).start()
        RemoteControl.shared.engine = engine; if CommandLine.arguments.contains("--remote") { RemoteControl.shared.setEnabled(true) }   // telecomando da telefono, solo se richiesto
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main); s.setEventHandler { engine.shutdown(); exit(0) }; s.resume()
            signalSources.append(s)
        }
        dispatchMain()
    } catch { log("errore:", error); exit(1) }
} else {
    runApp()
}
