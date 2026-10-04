import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Anteprima fluida: cattura la finestra reale di mpv (quella che va sul proiettore) con ScreenCaptureKit e la mostra a ~20 fotogrammi al secondo.
/// Serve il permesso "Registrazione schermo" di macOS; senza permesso (o se la cattura fallisce) l'interfaccia ripiega sull'anteprima a una immagine al secondo del motore.
final class LivePreview: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    enum Status: Equatable { case off, starting, live, noPermission, failed }
    @Published var status: Status = .off
    let layer = AVSampleBufferDisplayLayer()
    private let q = DispatchQueue(label: "dolly.preview")
    private var stream: SCStream?
    private var pid: Int32 = 0
    private var wantOn = false
    private var retryAt = Date.distantPast
    private var starting = false

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect; layer.backgroundColor = NSColor.black.cgColor
    }

    /// Da chiamare ogni secondo (e quando cambiano pid o impostazione): avvia, riavvia o ferma la cattura secondo serve.
    func update(pid newPid: Int, enabled: Bool) {
        wantOn = enabled
        guard enabled, newPid > 0 else { stop(); return }
        if CGPreflightScreenCaptureAccess() == false { if stream != nil { stop() }; set(.noPermission); return }
        if Int32(newPid) != pid { stop(); pid = Int32(newPid) }
        if stream == nil && !starting && Date() >= retryAt { start() }
    }
    func requestPermission() {
        if !CGRequestScreenCaptureAccess(), let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
    }

    private func set(_ s: Status) { DispatchQueue.main.async { if self.status != s { self.status = s } } }
    private func stop() {
        let s = stream; stream = nil; pid = 0; starting = false
        if let s = s { Task { try? await s.stopCapture() } }
        layer.flushAndRemoveImage()
        set(wantOn ? .starting : .off)
    }
    private func start() {
        starting = true; set(.starting)
        let target = pid
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let wins = content.windows.filter { $0.owningApplication?.processID == target && $0.frame.width > 40 }
                guard let win = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { throw DollyError("finestra del player non trovata") }
                let cfg = SCStreamConfiguration()
                let w = 960, h = max(2, Int(Double(w) * Double(win.frame.height) / Double(max(1, win.frame.width))) / 2 * 2)
                cfg.width = w; cfg.height = h; cfg.scalesToFit = true; cfg.showsCursor = false; cfg.queueDepth = 3
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 20); cfg.pixelFormat = kCVPixelFormatType_32BGRA
                let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
                try await s.startCapture()
                if !wantOn || pid != target { try? await s.stopCapture(); starting = false; return }   // nel frattempo è cambiato qualcosa
                stream = s; starting = false; set(.live)
            } catch {
                log("anteprima fluida non disponibile:", error)
                starting = false; retryAt = Date().addingTimeInterval(4); set(.failed)
            }
        }
    }

    // MARK: SCStreamOutput
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sb), CMSampleBufferGetNumSamples(sb) == 1 else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let st = arr.first?[.status] as? Int, SCFrameStatus(rawValue: st) != .complete { return }   // solo fotogrammi completi
        if let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(a) > 0 {   // mostra subito, senza orologio
            let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sb)
    }
    func stream(_ s: SCStream, didStopWithError error: Error) {
        log("anteprima fluida interrotta:", error)
        stream = nil; pid = 0; starting = false; retryAt = Date().addingTimeInterval(3); set(.failed)
    }
}

/// Vista che mostra il livello video della cattura.
struct LiveLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeNSView(context: Context) -> NSView { let v = NSView(); v.wantsLayer = true; v.layer = layer; return v }
    func updateNSView(_ v: NSView, context: Context) { v.layer = layer }
}
