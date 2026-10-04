import Foundation

/// Interfaccia HTTP locale (solo 127.0.0.1) per i collaudi automatici: stessa API del vecchio motore, così i test girano sul codice reale.
/// Si attiva solo con --test-api PORTA; l'app normale non apre nessuna porta.
final class TestServer {
    let engine: Engine, port: UInt16
    init(engine: Engine, port: UInt16) { self.engine = engine; self.port = port }

    func start() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0); var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(s, 64) == 0 else { throw DollyError("porta \(port) non disponibile") }
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(s, nil, nil); if c < 0 { continue }
                DispatchQueue.global().async { self.handle(c) }
            }
        }
    }

    private func reply(_ fd: Int32, _ code: Int, _ type: String, _ body: Data) {
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "No Content")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var d = Data(head.utf8); d.append(body)
        d.withUnsafeBytes { raw in var sent = 0; while sent < d.count { let n = send(fd, raw.baseAddress! + sent, d.count - sent, 0); if n <= 0 { break }; sent += n } }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data(); var chunk = [UInt8](repeating: 0, count: 65536); let sep = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while headEnd == nil { let n = recv(fd, &chunk, chunk.count, 0); if n <= 0 { return }; buf.append(chunk, count: n); headEnd = buf.range(of: sep) }
        let head = String(data: buf[..<headEnd!.lowerBound], encoding: .utf8) ?? ""
        let lines = head.components(separatedBy: "\r\n"); let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0]), path = String(parts[1])
        var len = 0; for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") { len = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0 }
        var body = Data(buf[headEnd!.upperBound...])
        while body.count < len { let n = recv(fd, &chunk, chunk.count, 0); if n <= 0 { break }; body.append(chunk, count: n) }

        if method == "GET" {
            if path.hasPrefix("/api/state") { reply(fd, 200, "application/json", engine.stateSync()) }
            else if path.hasPrefix("/api/preview") { if let j = engine.previewSync() { reply(fd, 200, "image/jpeg", j) } else { reply(fd, 204, "text/plain", Data()) } }
            else { reply(fd, 200, "text/html; charset=utf-8", Data("<!doctype html><html><head><title>Dolly</title></head><body>Dolly (interfaccia di collaudo)</body></html>".utf8)) }
            return
        }
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        var out: [String: Any] = [:]
        if path.hasPrefix("/api/pick") { out = ["paths": [String]()] }
        else if obj["a"] as? String == "quit" {
            reply(fd, 200, "application/json", Data("{}".utf8)); engine.shutdown(); exit(0)
        } else if let e = engine.actSync(obj) { out = ["error": e] }
        reply(fd, 200, "application/json", (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8))
    }
}
