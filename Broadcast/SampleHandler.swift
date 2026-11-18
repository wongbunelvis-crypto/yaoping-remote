import ReplayKit
import UIKit
import CoreImage
import VideoToolbox

/// 系统屏幕广播扩展：拿到整块屏幕的每一帧，压成 JPEG，推到公网中转。
class SampleHandler: RPBroadcastSampleHandler {

    private var client: MqttLite?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastSent: CFTimeInterval = 0
    private var room: String = "8888"

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 房间号由主 App 写进系统剪贴板，扩展这边读出来
        let pasted = UIPasteboard.general.string ?? ""
        let digits = pasted.filter { $0.isNumber }
        if digits.count == 4 { room = String(digits) }
        let c = MqttLite(clientId: "p" + UUID().uuidString.prefix(8), subscribeTopic: "yaoping/\(room)/v")
        client = c
        c.connect()
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        client?.disconnect()
        client = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = CACurrentMediaTime()
        guard now - lastSent >= 0.12 else { return }   // 约 8 帧/秒，够用又省电
        lastSent = now

        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let source = CIImage(cvPixelBuffer: pixel)
        let target: CGFloat = 420
        let scale = target / max(source.extent.width, 1)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.42) else { return }
        client?.publish(data)
    }
}
