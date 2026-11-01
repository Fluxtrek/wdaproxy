import UIKit
import Network
import AVFoundation

// WDAProxy —— 把手机 127.0.0.1:8100 暴露到本机 Wi-Fi 的 0.0.0.0:8101
// （8101 因为 WDA 自己已经占了 127.0.0.1:8100，同端口绑定会 Address already in use）
// 电脑访问：http://<iPhone-IP>:8101  →  手机 127.0.0.1:8100 (WDA)
let LISTEN_PORT: UInt16 = 8101
let TARGET_HOST = "127.0.0.1"
let TARGET_PORT: UInt16 = 8100

final class ProxyServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "proxy.queue", attributes: .concurrent)
    var onLog: ((String) -> Void)?
    private(set) var connectionCount = 0

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: LISTEN_PORT)!)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.log("listening 0.0.0.0:\(LISTEN_PORT)")
            case .failed(let e): self?.log("listener failed: \(e)")
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
    }

    private func handle(_ inbound: NWConnection) {
        let target = NWConnection(host: NWEndpoint.Host(TARGET_HOST),
                                  port: NWEndpoint.Port(rawValue: TARGET_PORT)!,
                                  using: .tcp)
        connectionCount += 1
        log("conn #\(connectionCount) -> \(TARGET_HOST):\(TARGET_PORT)")

        inbound.start(queue: queue)
        target.start(queue: queue)

        pump(from: inbound, to: target, tag: "c>s")
        pump(from: target, to: inbound, tag: "s>c")

        inbound.stateUpdateHandler = { st in
            switch st {
            case .failed, .cancelled: target.cancel()
            default: break
            }
        }
        target.stateUpdateHandler = { st in
            switch st {
            case .failed, .cancelled: inbound.cancel()
            default: break
            }
        }
    }

    private func pump(from src: NWConnection, to dst: NWConnection, tag: String) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                dst.send(content: data, completion: .contentProcessed { err in
                    if err != nil { dst.cancel(); src.cancel() }
                })
            }
            if isComplete || error != nil {
                dst.cancel()
                src.cancel()
                return
            }
            self?.pump(from: src, to: dst, tag: tag)
        }
    }

    private func log(_ s: String) {
        print("[proxy] \(s)")
        onLog?(s)
    }
}

final class KeepAlive {
    private var player: AVAudioPlayer?

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Self.silentWav(seconds: 5).write(to: url)
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 0
        player?.play()
    }

    static func silentWav(seconds: Int) -> Data {
        let sampleRate = 8000
        let samples = sampleRate * seconds
        var d = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!)
        le32(UInt32(36 + samples))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate)); le16(1); le16(8)
        d.append("data".data(using: .ascii)!)
        le32(UInt32(samples))
        d.append(Data(repeating: 128, count: samples))
        return d
    }
}

final class RootVC: UIViewController {
    private let label = UILabel()
    private let server = ProxyServer()
    private let keepAlive = KeepAlive()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        label.numberOfLines = 0
        label.textColor = .green
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
        ])

        let ip = RootVC.wifiIP() ?? "?"
        append("WDAProxy  v2")
        append("phone ip : \(ip)")
        append("forward  : 0.0.0.0:\(LISTEN_PORT) -> \(TARGET_HOST):\(TARGET_PORT)")
        append("pc usage : http://\(ip):\(LISTEN_PORT)/status")
        append("----------")
        append("keep this app open / in background")

        server.onLog = { [weak self] s in DispatchQueue.main.async { self?.append(s) } }
        do {
            try server.start()
            keepAlive.start()
        } catch {
            append("start failed: \(error)")
        }
    }

    private func append(_ s: String) {
        label.text = (label.text ?? "") + "\n" + s
    }

    static func wifiIP() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addr = String(cString: host)
            }
        }
        return addr
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = RootVC()
        window?.makeKeyAndVisible()
        return true
    }
}

// main.swift 允许顶层代码，因此不走 @main，直接显式启动 UIApplication
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                  NSStringFromClass(AppDelegate.self))

