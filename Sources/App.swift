import SwiftUI
import ReplayKit
import UIKit

@main
struct YaopingApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var mode = 0
    @State private var room = UserDefaults.standard.string(forKey: "room") ?? "8888"

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.07).ignoresSafeArea()
            VStack(spacing: 14) {
                Picker("", selection: $mode) {
                    Text("分享我的屏幕").tag(0)
                    Text("看对方屏幕").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if mode == 0 {
                    ShareView(room: $room)
                } else {
                    WatchView(room: $room)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: room) { newValue in
            UserDefaults.standard.set(newValue, forKey: "room")
            UIPasteboard.general.string = newValue
        }
        .onAppear {
            UIPasteboard.general.string = room
        }
    }
}

// MARK: - 分享端

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        v.preferredExtension = "com.suchuan.yaoping.broadcast"
        v.showsMicrophoneButton = false
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct ShareView: View {
    @Binding var room: String

    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("房间号").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                HStack {
                    TextField("4 位数字", text: $room)
                        .keyboardType(.numberPad)
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(12)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.05))
                VStack(spacing: 10) {
                    BroadcastPicker().frame(width: 72, height: 72)
                    Text("点上面这个按钮 → 选「遥屏广播」→ 开始")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .frame(height: 170)

            VStack(alignment: .leading, spacing: 8) {
                row("1", "设好房间号，iPad 上也填一样的")
                row("2", "点上面的广播按钮，等 3 秒倒数")
                row("3", "iPad 那边就能看到你的屏幕了")
                row("4", "要停：点屏幕顶部红色条，或控制中心再点一次")
            }
            .padding(14)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func row(_ n: String, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.16, green: 0.83, blue: 0.73))
                .frame(width: 14, alignment: .leading)
            Text(t).font(.system(size: 13)).foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 观看端

final class Viewer: ObservableObject {
    @Published var image: UIImage?
    @Published var status = "未连接"
    @Published var fps: Double = 0

    private var client: MqttLite?
    private var frames = 0
    private var lastTick = Date()

    func start(room: String) {
        stop()
        let c = MqttLite(clientId: "w" + UUID().uuidString.prefix(8),
                         subscribeTopic: "yaoping/\(room)/v",
                         publishTopic: "yaoping/\(room)/t")
        c.onPayload = { [weak self] data in
            guard let self = self, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.image = img
                self.frames += 1
                let now = Date()
                if now.timeIntervalSince(self.lastTick) >= 1 {
                    self.fps = Double(self.frames) / now.timeIntervalSince(self.lastTick)
                    self.frames = 0
                    self.lastTick = now
                }
            }
        }
        client = c
        c.connect()
        status = "已连接房间 \(room)"
    }

    func stop() {
        client?.disconnect()
        client = nil
        status = "未连接"
        image = nil
    }

    func touch(_ phase: String, _ x: CGFloat, _ y: CGFloat) {
        guard let c = client else { return }
        c.publishText(String(format: "%@ %.4f %.4f", phase, Double(x), Double(y)))
    }
}

/// 铺在画面上的透明触控层：点一下 / 拖一下，都换算成 0~1 的坐标发给对方
struct TouchPad: UIViewRepresentable {
    let onTouch: (String, CGFloat, CGFloat) -> Void

    final class Pad: UIView {
        var onTouch: ((String, CGFloat, CGFloat) -> Void)?
        private var downAt: CGPoint = .zero

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            downAt = t.location(in: self)
            report("d", downAt)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            let p = t.location(in: self)
            if hypot(p.x - downAt.x, p.y - downAt.y) > 24 { report("m", p) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            let p = t.location(in: self)
            report("m", p)
            report("u", p)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            report("u", downAt)
        }
        private func report(_ phase: String, _ p: CGPoint) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            onTouch?(phase, p.x / bounds.width, p.y / bounds.height)
        }
    }

    func makeUIView(context: Context) -> Pad {
        let v = Pad()
        v.backgroundColor = .clear
        v.onTouch = onTouch
        return v
    }
    func updateUIView(_ uiView: Pad, context: Context) {
        uiView.onTouch = onTouch
    }
}

struct WatchView: View {
    @Binding var room: String
    @StateObject private var viewer = Viewer()

    private func fit(_ s: CGSize, in box: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let r = min(box.width / s.width, box.height / s.height)
        return CGSize(width: s.width * r, height: s.height * r)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("房间号", text: $room)
                    .keyboardType(.numberPad)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .padding(10)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundColor(.white)

                Button {
                    if viewer.image == nil { viewer.start(room: room) } else { viewer.stop() }
                } label: {
                    Text(viewer.image == nil ? "连上" : "断开")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Color(red: 0.16, green: 0.83, blue: 0.73))
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.black)
                if let img = viewer.image {
                    GeometryReader { geo in
                        let box = CGSize(width: geo.size.width, height: geo.size.height)
                        let fitted = fit(img.size, in: box)
                        Image(uiImage: img)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        TouchPad { phase, x, y in
                            viewer.touch(phase, x, y)
                        }
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(viewer.status).font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.1), lineWidth: 1))

            HStack {
                Text(viewer.status).font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                Spacer()
                Text(String(format: "%.1f fps", viewer.fps)).font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
}
