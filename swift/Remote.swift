import Foundation
import AppKit
import SwiftUI
import CoreImage

/// Telecomando dal telefono: piccolo server web sulla rete locale (nessuna connessione a internet). Spento di default; si attiva dall'interfaccia.
/// Il telefono apre l'indirizzo mostrato (o inquadra il QR), inserisce il PIN e comanda la proiezione. Solo i comandi elencati in `allowed` sono accettati.
final class RemoteControl: ObservableObject {
    static let shared = RemoteControl()
    @Published var enabled = false
    @Published var pin = ""
    @Published var urls: [String] = []
    @Published var problem: String?

    private let lock = NSLock()
    private var _engine: Engine?
    var engine: Engine? { get { lock.lock(); defer { lock.unlock() }; return _engine } set { lock.lock(); _engine = newValue; lock.unlock() } }
    private var tokens: [String] = []
    private var fails: [Double] = []
    private var listenFd: Int32 = -1
    private var port: UInt16 = 8484
    private var cfile: String { Engine.homePath + "/remote.json" }

    private init() {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: cfile)), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            enabled = o["enabled"] as? Bool ?? false; pin = o["pin"] as? String ?? ""; tokens = o["tokens"] as? [String] ?? []
        }
        if pin.count != 4 { pin = RemoteControl.newPin() }
        if enabled { start() }
    }
    private static func newPin() -> String { String(format: "%04d", Int.random(in: 0...9999)) }
    private func save() {
        let o: [String: Any] = ["enabled": enabled, "pin": pin, "tokens": tokens]
        try? FileManager.default.createDirectory(atPath: Engine.homePath, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: URL(fileURLWithPath: cfile), options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cfile) }
    }

    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
        enabled = on && problem == nil; if on && problem != nil { stop() }
        save()
    }
    /// Nuovo PIN: i telefoni già collegati devono rifare l'accesso.
    func regeneratePin() { lock.lock(); tokens = []; lock.unlock(); pin = RemoteControl.newPin(); save() }

    // MARK: server
    private func start() {
        stop()
        let s = socket(AF_INET, SOCK_STREAM, 0); var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var bound = false
        let first = UInt16(ProcessInfo.processInfo.environment["DOLLY_REMOTE_PORT"] ?? "") ?? 8484   // (la variabile serve solo ai collaudi)
        for p in first...(first + 10) {
            var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = p.bigEndian; a.sin_addr.s_addr = INADDR_ANY
            if withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 { port = p; bound = true; break }
        }
        guard bound, listen(s, 16) == 0 else { close(s); DispatchQueue.main.async { self.problem = "Non riesco ad aprire una porta di rete."; self.urls = [] }; return }
        listenFd = s
        let ips = RemoteControl.lanAddresses(), pt = port
        DispatchQueue.main.async { self.problem = nil; self.urls = ips.map { "http://\($0):\(pt)/" } }
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(s, nil, nil); if c < 0 { break }
                DispatchQueue.global().async { self.handle(c) }
            }
        }
    }
    private func stop() {
        if listenFd >= 0 { shutdown(listenFd, SHUT_RDWR); close(listenFd); listenFd = -1 }
        DispatchQueue.main.async { self.urls = [] }
    }
    /// Indirizzi IPv4 del Mac sulla rete locale (Wi-Fi, Ethernet, hotspot): quelli che il telefono può raggiungere.
    static func lanAddresses() -> [String] {
        var res: [(String, String)] = []; var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return [] }
        defer { freeifaddrs(ifa) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p?.pointee {
            defer { p = i.ifa_next }
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: i.ifa_name); guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { res.append((name, String(cString: host))) }
        }
        return res.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    private func reply(_ fd: Int32, _ code: Int, _ type: String, _ body: Data) {
        let text = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 429: "Too Many Requests", 503: "Service Unavailable"][code] ?? "OK"
        let head = "HTTP/1.1 \(code) \(text)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var d = Data(head.utf8); d.append(body)
        d.withUnsafeBytes { raw in var sent = 0; while sent < d.count { let n = send(fd, raw.baseAddress! + sent, d.count - sent, 0); if n <= 0 { break }; sent += n } }
    }
    private func json(_ fd: Int32, _ code: Int, _ o: Any) { reply(fd, code, "application/json", (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)) }

    /// Comandi che il telefono può inviare (niente scelta di cartelle, scalette, file o impostazioni dell'app).
    private func allowed(_ d: [String: Any]) -> Bool {
        switch d["a"] as? String ?? "" {
        case "toggle", "play", "next", "prev", "stop", "seek", "skipgap", "extend", "resume": return true
        case "set": return ["volume", "mute"].contains(d["p"] as? String ?? "")
        case "setitem": return Set(d.keys).isSubset(of: ["a", "i", "loop"])
        default: return false
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data(); var chunk = [UInt8](repeating: 0, count: 8192); let sep = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while headEnd == nil { let n = recv(fd, &chunk, chunk.count, 0); if n <= 0 || buf.count > 16384 { return }; buf.append(chunk, count: n); headEnd = buf.range(of: sep) }
        let head = String(data: buf[..<headEnd!.lowerBound], encoding: .utf8) ?? ""
        let lines = head.components(separatedBy: "\r\n"); let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0]), full = String(parts[1]); let path = full.components(separatedBy: "?")[0]
        var len = 0, hdrToken = ""
        for l in lines.dropFirst() {
            let low = l.lowercased()
            if low.hasPrefix("content-length:") { len = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0 }
            if low.hasPrefix("x-token:") { hdrToken = l.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        }
        guard len <= 4096 else { reply(fd, 400, "text/plain", Data()); return }
        var body = Data(buf[headEnd!.upperBound...])
        while body.count < len { let n = recv(fd, &chunk, chunk.count, 0); if n <= 0 { break }; body.append(chunk, count: n) }
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        if method == "GET" && (path == "/" || path == "/index.html") { reply(fd, 200, "text/html; charset=utf-8", Data(remoteHTML.utf8)); return }
        if method == "POST" && path == "/api/login" {
            let now = nowT(); lock.lock(); fails = fails.filter { now - $0 < 60 }; let blocked = fails.count >= 5; lock.unlock()
            if blocked { json(fd, 429, ["error": "troppi tentativi"]); return }
            if (obj["pin"] as? String ?? "") == pin {
                let t = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                lock.lock(); tokens = Array((tokens + [t]).suffix(10)); lock.unlock(); save(); json(fd, 200, ["token": t])
            } else { lock.lock(); fails.append(now); lock.unlock(); json(fd, 401, ["error": "PIN errato"]) }
            return
        }
        var tok = hdrToken
        if tok.isEmpty, let q = full.components(separatedBy: "?").dropFirst().first, let r = q.range(of: "t=") { tok = String(q[r.upperBound...].prefix(32)) }
        lock.lock(); let ok = !tok.isEmpty && tokens.contains(tok); lock.unlock()
        guard ok else { json(fd, 401, ["error": "accesso necessario"]); return }
        guard let e = engine else { json(fd, 503, ["error": "player non pronto"]); return }

        if method == "GET" && path == "/api/state" {
            let raw = (try? JSONSerialization.jsonObject(with: e.stateSync())) as? [String: Any] ?? [:]
            var s = raw.filter { ["ok", "name", "mode", "idx", "sel", "label", "left", "playing", "pause", "time", "dur"].contains($0.key) }
            s["items"] = (raw["items"] as? [[String: Any]] ?? []).map { i in i.filter { ["kind", "name", "secs", "text", "ok", "loop"].contains($0.key) } }
            let pr = raw["props"] as? [String: Any] ?? [:]; s["props"] = ["volume": pr["volume"] ?? NSNull(), "mute": pr["mute"] ?? NSNull()]
            json(fd, 200, s)
        } else if method == "GET" && path == "/api/preview" {
            if let j = e.previewSync() { reply(fd, 200, "image/jpeg", j) } else { reply(fd, 204, "text/plain", Data()) }
        } else if method == "POST" && path == "/api/cmd" {
            guard allowed(obj) else { json(fd, 400, ["error": "comando non ammesso"]); return }
            if let err = e.actSync(obj) { json(fd, 200, ["error": err]) } else { json(fd, 200, [String: Any]()) }
        } else { reply(fd, 404, "text/plain", Data()) }
    }

    static func qr(_ s: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(s.utf8), forKey: "inputMessage"); f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out); let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }
}

/// Scheda "Telecomando dal telefono" (scheda Altro).
struct RemoteCard: View {
    @ObservedObject var r = RemoteControl.shared
    var body: some View {
        Card(title: "Telecomando dal telefono", symbol: "iphone.radiowaves.left.and.right") {
            Toggle("Attiva il telecomando", isOn: Binding(get: { r.enabled }, set: { r.setEnabled($0) })).toggleStyle(.switch)
            if let p = r.problem { Text(p).font(.system(size: 12)).foregroundStyle(.red) }
            if r.enabled, let u = r.urls.first {
                HStack(alignment: .top, spacing: 12) {
                    if let q = RemoteControl.qr(u) { Image(nsImage: q).interpolation(.none).resizable().frame(width: 112, height: 112).background(Color.white).cornerRadius(6) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Indirizzo").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(u).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        Text("PIN").font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack { Text(r.pin).font(.system(size: 20, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Button("Nuovo PIN") { r.regeneratePin() }.controlSize(.small) }
                    }
                }
                if r.urls.count > 1 { Text("Altri indirizzi: " + r.urls.dropFirst().joined(separator: "  ")).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
            } else if r.enabled { Text("Nessuna rete trovata: collega il Mac al Wi-Fi o a un router.").font(.system(size: 12)).foregroundStyle(.secondary) }
            Text("Il telefono e il Mac devono stare sulla stessa rete; non serve internet. Inquadra il QR o scrivi l'indirizzo nel browser del telefono.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
