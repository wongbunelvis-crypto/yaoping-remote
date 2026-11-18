import Foundation
import Network

/// 极简 MQTT 3.1.1 客户端（QoS0，走 TLS 8883），不依赖任何第三方库。
/// 只做三件事：连上、订阅、发字节；收到消息回调。
final class MqttLite {

    private let host = "broker.emqx.io"
    private let port: NWEndpoint.Port = 8883
    private let subTopic: String
    private let pubTopic: String
    private let clientId: String

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "yaoping.mqtt")
    private var buf = [UInt8]()
    private var pingTimer: DispatchSourceTimer?
    private var subscribed = false

    var onPayload: ((Data) -> Void)?

    init(clientId: String, subscribeTopic: String, publishTopic: String? = nil) {
        self.clientId = clientId
        self.subTopic = subscribeTopic
        self.pubTopic = publishTopic ?? subscribeTopic
    }

    func connect() {
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendConnect()
                self.startPing()
                self.receiveLoop()
            case .failed, .cancelled:
                self.stopPing()
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    func disconnect() {
        stopPing()
        conn?.cancel()
        conn = nil
    }

    func publish(_ payload: Data) {
        var body = Data()
        body.append(stringBytes(pubTopic))
        body.append(payload)
        var pkt = Data([0x30])
        pkt.append(varLen(body.count))
        pkt.append(body)
        rawSend(pkt)
    }

    func publishText(_ s: String) {
        guard let d = s.data(using: .utf8) else { return }
        publish(d)
    }

    // MARK: - 私有

    private func sendConnect() {
        var body = Data()
        body.append(stringBytes("MQTT"))
        body.append(contentsOf: [0x04, 0x02])      // level 4, clean session
        body.append(contentsOf: [0x00, 0x3C])      // keepalive 60s
        body.append(stringBytes(clientId))
        var pkt = Data([0x10])
        pkt.append(varLen(body.count))
        pkt.append(body)
        rawSend(pkt)
    }

    private func sendSubscribe() {
        var body = Data()
        body.append(contentsOf: [0x00, 0x01])      // packet id
        body.append(stringBytes(subTopic))
        body.append(0x00)                          // qos0
        var pkt = Data([0x82])
        pkt.append(varLen(body.count))
        pkt.append(body)
        rawSend(pkt)
        subscribed = true
    }

    private func startPing() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 40, repeating: 40)
        t.setEventHandler { [weak self] in
            self?.rawSend(Data([0xC0, 0x00]))
        }
        t.resume()
        pingTimer = t
    }

    private func stopPing() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func rawSend(_ data: Data) {
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                self.buf.append(contentsOf: [UInt8](d))
                self.drain()
            }
            if error != nil || isDone { return }
            self.receiveLoop()
        }
    }

    private func drain() {
        while buf.count >= 2 {
            let header = buf[0]
            var len = 0
            var mul = 1
            var i = 1
            var ok = false
            while i < buf.count && i <= 4 {
                let b = Int(buf[i])
                len += (b & 0x7F) * mul
                mul *= 128
                i += 1
                if b & 0x80 == 0 { ok = true; break }
            }
            guard ok else { return }
            let total = i + len
            guard buf.count >= total else { return }
            let body = Array(buf[i..<total])
            buf.removeFirst(total)
            handle(header: header >> 4, body: body)
        }
    }

    private func handle(header type: UInt8, body: [UInt8]) {
        switch type {
        case 2:
            sendSubscribe()
        case 3:
            guard body.count >= 2 else { return }
            let tl = Int(body[0]) * 256 + Int(body[1])
            guard body.count >= 2 + tl else { return }
            let payload = Data(body[(2 + tl)...])
            onPayload?(payload)
        default:
            break
        }
    }

    private func stringBytes(_ s: String) -> Data {
        let u = Array(s.utf8)
        var d = Data([UInt8(u.count / 256), UInt8(u.count % 256)])
        d.append(contentsOf: u)
        return d
    }

    private func varLen(_ n: Int) -> Data {
        var v = n
        var d = Data()
        repeat {
            var b = UInt8(v % 128)
            v = v / 128
            if v > 0 { b |= 0x80 }
            d.append(b)
        } while v > 0
        return d
    }
}
