import Foundation

/// mpv come processo separato, pilotato via socket IPC (così se mpv si pianta non porta giù l'app).
final class Mpv {
    let binary: String, extra: [String], windowed: Bool, screen: Int
    private(set) var proc: Process?
    private(set) var sock = ""
    private var rid = 0

    init(binary: String, extra: [String], windowed: Bool, screen: Int) { self.binary = binary; self.extra = extra; self.windowed = windowed; self.screen = screen }

    func start() throws {
        sock = NSTemporaryDirectory() + "dolly-\(getpid())-\(Int(Date().timeIntervalSince1970)).sock"
        var a = ["--idle=yes", "--force-window=yes", "--keep-open=no", "--no-osc", "--no-input-default-bindings", "--no-input-cursor",
                 "--osd-level=0", "--osd-font-size=64", "--osd-align-x=center", "--osd-align-y=center", "--osd-bold=yes",
                 "--screenshot-format=jpeg", "--screenshot-jpeg-quality=60", "--cursor-autohide=always", "--audio-display=no", "--no-terminal",
                 "--hwdec=auto-safe", "--alang=ita,it,eng,en", "--subs-match-os-language=no", "--no-resume-playback", "--demuxer-readahead-secs=30",
                 "--screen=\(screen)", "--input-ipc-server=\(sock)"]
        a += windowed ? ["--no-border"] : ["--fs", "--fs-screen=\(screen)"]
        let p = Process(); p.executableURL = URL(fileURLWithPath: binary); p.arguments = a + extra
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run(); proc = p
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: sock) && p.isRunning { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw DollyError("mpv non è partito")
    }
    var alive: Bool { proc?.isRunning ?? false }
    func kill() {
        guard let p = proc, p.isRunning else { return }
        Darwin.kill(p.processIdentifier, SIGKILL); p.waitUntilExit()
    }

    /// Più comandi su un'unica connessione. Lancia se mpv non risponde; nil per le proprietà non disponibili.
    @discardableResult
    func ipc(_ cmds: [[Any]], timeout: TimeInterval = 2) throws -> [Any?] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DollyError("socket") }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(sock.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw DollyError("percorso socket troppo lungo") }
        withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { p in for (i, c) in pathBytes.enumerated() { p[i] = c } } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { throw DollyError("mpv non risponde (connect)") }

        var ids: [Int: Int] = [:]; var out = [Any?](repeating: nil, count: cmds.count)
        for (i, c) in cmds.enumerated() {
            rid += 1; ids[rid] = i
            var data = try JSONSerialization.data(withJSONObject: ["command": c, "request_id": rid] as [String: Any]); data.append(10)
            var sent = 0
            try data.withUnsafeBytes { raw in
                while sent < data.count {
                    let n = send(fd, raw.baseAddress! + sent, data.count - sent, 0)
                    if n <= 0 { throw DollyError("mpv non risponde (invio)") }
                    sent += n
                }
            }
        }
        var buf = Data(); var left = cmds.count; var chunk = [UInt8](repeating: 0, count: 65536)
        while left > 0 {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 { throw DollyError("mpv non risponde (timeout)") }
            if n == 0 { throw DollyError("mpv ha chiuso la connessione") }
            buf.append(chunk, count: n)
            while let nl = buf.firstIndex(of: 10) {
                let line = buf[buf.startIndex..<nl]; buf = Data(buf[buf.index(after: nl)...])
                guard let r = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = asInt(r["request_id"]), let i = ids[id] else { continue }
                if (r["error"] as? String) == "success" { let d = r["data"]; out[i] = (d is NSNull) ? nil : d }
                left -= 1
            }
        }
        return out
    }
    func get(_ props: [String]) throws -> [String: Any] {
        let r = try ipc(props.map { ["get_property", $0] })
        var d: [String: Any] = [:]; for (k, v) in zip(props, r) { if let v = v { d[k] = v } }
        return d
    }
}
