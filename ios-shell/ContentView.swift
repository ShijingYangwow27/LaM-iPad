import SwiftUI
import WebKit
import AVKit
import AVFoundation
import MediaPlayer
import CoreMedia
import CoreVideo

func swiftLog(_ step: String, _ extra: [String: Any] = [:]) {
    var payload: [String: Any] = ["step": "swift_" + step]
    for (k, v) in extra { payload[k] = v }
    guard let url = URL(string: "http://192.168.31.251:3000/api/qq/qr/log"),
          let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    URLSession.shared.dataTask(with: req).resume()
}

class MainWebViewHolder {
    weak var webView: WKWebView?
    static let shared = MainWebViewHolder()
}

class PiPHostView: UIView {
    var playerLayer: AVPlayerLayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
}

class PiPManager: NSObject, AVPictureInPictureControllerDelegate, ObservableObject {
    @Published var pipActive = false
    var pipController: AVPictureInPictureController?
    var pipPlayer: AVPlayer?
    var pipHostView: PiPHostView?
    var coverImage: UIImage?
    var currentTitle: String = ""
    var currentArtist: String = ""
    weak var webView: WKWebView?
    
    // 后台音频播放器
    var bgPlayer: AVPlayer?
    var bgPlayerItem: AVPlayerItem?
    
    private let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("pip_frame.mp4")
    private var videoReady = false
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var silentPlayer: AVAudioPlayer?
    
    override init() {
        super.init()
        setupAudioSession()
        setupSilentPlayer()
        setup()
        setupRemoteCommands()
        setupNotifications()
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidReachEnd), name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    @objc private func appDidEnterBackground() {
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "pip-audio") { [weak self] in
            if let id = self?.bgTaskId, id != .invalid {
                UIApplication.shared.endBackgroundTask(id)
                self?.bgTaskId = .invalid
            }
        }
        // 确保音频会话在后台保持活跃
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            swiftLog("audio_session_bg_fail", ["error": error.localizedDescription])
        }
        // 确保静音播放器持续播放
        if silentPlayer?.isPlaying != true {
            silentPlayer?.play()
        }
        // 后台时取消bgPlayer静音，让音频继续播放
        bgPlayer?.volume = 1.0
        swiftLog("app_did_enter_bg", ["pipActive": pipActive])
    }
    
    @objc private func appWillEnterForeground() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
        // 前台时静音bgPlayer，避免双重播放
        bgPlayer?.volume = 0.0
        // 恢复网页音频
        if let webView = webView {
            let js = """
            (function(){
                try {
                    if (typeof audio !== 'undefined' && audio && audio.paused && audio.src) {
                        audio.play().catch(function(){});
                    }
                } catch(e){}
            })();
            """
            webView.evaluateJavaScript(js)
        }
    }
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowAirPlay])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            swiftLog("audio_session_ok", ["category": session.category.rawValue])
        } catch {
            print("[PiP] AudioSession setup failed: \(error)")
            swiftLog("audio_session_fail", ["error": error.localizedDescription])
        }
    }
    
    private func setupSilentPlayer() {
        let numSamples = 44100
        var d = Data()
        func appendStr(_ s: String) { d.append(contentsOf: s.utf8) }
        func append16(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func append32(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        appendStr("RIFF")
        append32(36 + UInt32(numSamples) * 4)
        appendStr("WAVE")
        appendStr("fmt ")
        append32(16)
        append16(1)
        append16(2)
        append32(44100)
        append32(176400)
        append16(4)
        append16(16)
        appendStr("data")
        append32(UInt32(numSamples) * 4)
        d.append(contentsOf: [UInt8](repeating: 0, count: numSamples * 4))
        silentPlayer = try? AVAudioPlayer(data: d)
        silentPlayer?.volume = 0.5
        silentPlayer?.numberOfLoops = -1
        silentPlayer?.prepareToPlay()
        let ok = silentPlayer?.play() ?? false
        swiftLog("silent_player", ["ok": ok])
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeInt = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeInt) else { return }
        if type == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            if pipActive { pipPlayer?.play() }
        }
    }
    
    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonInt = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonInt) else { return }
        if reason == .oldDeviceUnavailable {
            pipPlayer?.pause()
        }
    }
    
    private func setup() {
        pipPlayer = AVPlayer()
        pipPlayer?.volume = 0.001
        pipPlayer?.isMuted = false
        pipPlayer?.actionAtItemEnd = .none
        pipPlayer?.automaticallyWaitsToMinimizeStalling = false
        
        pipHostView = PiPHostView()
        pipHostView?.frame = CGRect(x: 0, y: 0, width: 480, height: 480)
        pipHostView?.backgroundColor = .clear
        pipHostView?.isUserInteractionEnabled = false
        pipHostView?.isHidden = false
        
        let playerLayer = AVPlayerLayer(player: pipPlayer)
        playerLayer.frame = CGRect(x: 0, y: 0, width: 480, height: 480)
        playerLayer.videoGravity = .resizeAspect
        pipHostView?.layer.addSublayer(playerLayer)
        pipHostView?.playerLayer = playerLayer
        
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: playerLayer)
            pipController?.delegate = self
            pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            swiftLog("pip_controller_created", ["supported": true])
        } else {
            swiftLog("pip_not_supported", [:])
        }
        
        generateInitialVideo()
    }
    
    private func generateInitialVideo() {
        currentTitle = "Mineradio"
        currentArtist = "等待播放..."
        generateCoverVideo { [weak self] url in
            guard let self = self, let url = url else { return }
            DispatchQueue.main.async {
                let item = AVPlayerItem(url: url)
                self.pipPlayer?.replaceCurrentItem(with: item)
                self.videoReady = true
                self.pipPlayer?.play()
                swiftLog("initial_video_ready", [:])
            }
        }
    }
    
    @objc private func playerItemDidReachEnd() {
        pipPlayer?.seek(to: .zero)
        pipPlayer?.play()
    }
    
    // 后台音频播放
    func startBgAudio(url: URL) {
        swiftLog("bg_audio_start", ["url": url.absoluteString])
        let item = AVPlayerItem(url: url)
        bgPlayerItem = item
        if bgPlayer == nil {
            bgPlayer = AVPlayer()
        }
        // 默认静音，前台由网页端播放，后台时取消静音
        bgPlayer?.volume = 0.0
        bgPlayer?.replaceCurrentItem(with: item)
        bgPlayer?.play()
        swiftLog("bg_audio_playing", [:])
    }
    
    func stopBgAudio() {
        bgPlayer?.pause()
        bgPlayer?.replaceCurrentItem(with: nil)
        bgPlayerItem = nil
        swiftLog("bg_audio_stopped", [:])
    }
    
    func pauseBgAudio() {
        bgPlayer?.pause()
        swiftLog("bg_audio_paused", [:])
    }
    
    func resumeBgAudio() {
        bgPlayer?.play()
        swiftLog("bg_audio_resumed", [:])
    }
    
    func attachHostView(to parentView: UIView) {
        guard let hostView = pipHostView, hostView.superview == nil else { return }
        hostView.frame = CGRect(x: -500, y: -500, width: 480, height: 480)
        hostView.clipsToBounds = false
        hostView.alpha = 1
        hostView.isHidden = false
        parentView.addSubview(hostView)
        swiftLog("host_view_attached", ["parent": String(describing: type(of: parentView))])
    }
    
    func startPiP() {
        guard videoReady else {
            swiftLog("pip_start_skipped_video_not_ready", [:])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.startPiP() }
            return
        }
        guard let pip = pipController else {
            swiftLog("pip_start_skipped_no_controller", [:])
            showFallbackToast("当前设备不支持画中画")
            return
        }
        if pipActive {
            stopPiP()
            return
        }
        
        pipPlayer?.seek(to: .zero)
        pipPlayer?.play()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            if pip.isPictureInPicturePossible {
                pip.startPictureInPicture()
                swiftLog("pip_start_called", ["possible": true])
            } else {
                swiftLog("pip_not_possible", [:])
                self.showFallbackToast("画中画暂时不可用，请确保正在播放歌曲")
            }
        }
        updateNowPlayingInfo()
    }
    
    func stopPiP() {
        pipController?.stopPictureInPicture()
        pipActive = false
    }
    
    private func showFallbackToast(_ msg: String) {
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("if(typeof showToast==='function')showToast('\(msg)')")
        }
    }
    
    func updateInfo(title: String, artist: String, coverData: Data?) {
        currentTitle = title
        currentArtist = artist
        if let data = coverData {
            coverImage = UIImage(data: data)
        } else {
            coverImage = nil
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.generateCoverVideo { [weak self] url in
                guard let self = self, let url = url else { return }
                DispatchQueue.main.async {
                    let wasPlaying = self.pipActive
                    let item = AVPlayerItem(url: url)
                    self.pipPlayer?.replaceCurrentItem(with: item)
                    self.pipPlayer?.seek(to: .zero)
                    self.videoReady = true
                    if wasPlaying || self.pipActive {
                        self.pipPlayer?.play()
                    }
                    self.updateNowPlayingInfo()
                }
            }
        }
    }
    
    func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.webView?.evaluateJavaScript("if(window.pipTogglePlay){window.pipTogglePlay()}else if(typeof togglePlay==='function'){togglePlay()}else if(typeof audio!=='undefined'&&audio&&audio.paused){audio.play()}")
            return .success
        }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.webView?.evaluateJavaScript("if(window.pipTogglePlay){window.pipTogglePlay()}else if(typeof togglePlay==='function'){togglePlay()}else if(typeof audio!=='undefined'&&audio&&!audio.paused){audio.pause()}")
            return .success
        }
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.webView?.evaluateJavaScript("if(window.pipTogglePlay){window.pipTogglePlay()}else if(typeof togglePlay==='function'){togglePlay()}")
            return .success
        }
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.webView?.evaluateJavaScript("if(window.pipNextTrack){window.pipNextTrack()}else if(typeof nextTrack==='function'){nextTrack()}")
            return .success
        }
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.webView?.evaluateJavaScript("if(window.pipPrevTrack){window.pipPrevTrack()}else if(typeof prevTrack==='function'){prevTrack()}")
            return .success
        }
        commandCenter.changePlaybackPositionCommand.isEnabled = false
    }
    
    func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle.isEmpty ? "Mineradio" : currentTitle,
            MPMediaItemPropertyArtist: currentArtist.isEmpty ? "" : currentArtist,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPMediaItemPropertyPlaybackDuration: NSNumber(value: 600),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: 0)
        ]
        
        if let image = coverImage {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func generateCoverVideo(completion: @escaping (URL?) -> Void) {
        let size = CGSize(width: 480, height: 480)
        let durationSec: Double = 600
        
        try? FileManager.default.removeItem(at: videoURL)
        
        guard let writer = try? AVAssetWriter(outputURL: videoURL, fileType: .mp4) else {
            print("[PiP] Failed to create AVAssetWriter")
            completion(nil)
            return
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: NSNumber(value: Int(size.width)),
            AVVideoHeightKey: NSNumber(value: Int(size.height))
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: NSNumber(value: Int(size.width)),
            kCVPixelBufferHeightKey as String: NSNumber(value: Int(size.height))
        ]
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        
        writer.add(writerInput)
        
        guard writer.startWriting() else {
            print("[PiP] startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
            completion(nil)
            return
        }
        writer.startSession(atSourceTime: .zero)
        
        let frameImage = renderFrameImage(size: size)
        
        func appendPixelBuffer(at time: CMTime) -> Bool {
            var pb: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &pb)
            guard status == kCVReturnSuccess, let buffer = pb else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            
            guard let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            
            ctx.draw(frameImage, in: CGRect(origin: .zero, size: size))
            return adaptor.append(buffer, withPresentationTime: time)
        }
        
        writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "pip.videowriter")) {
            while writerInput.isReadyForMoreMediaData {
                if !appendPixelBuffer(at: .zero) { break }
                if !appendPixelBuffer(at: CMTime(seconds: durationSec - 1, preferredTimescale: 600)) { break }
                writerInput.markAsFinished()
                writer.finishWriting {
                    DispatchQueue.main.async {
                        if writer.status == .completed {
                            completion(self.videoURL)
                        } else {
                            print("[PiP] finishWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
                            completion(nil)
                        }
                    }
                }
                return
            }
        }
    }
    
    private func renderFrameImage(size: CGSize) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { context in
            let c = context.cgContext
            let w = size.width, h = size.height
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                UIColor(red: 0.11, green: 0.11, blue: 0.16, alpha: 1.0).cgColor,
                UIColor(red: 0.055, green: 0.055, blue: 0.094, alpha: 1.0).cgColor
            ]
            let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0.0, 1.0])!
            c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
            
            let coverSize = w * 0.62
            let coverX = (w - coverSize) / 2
            let coverY: CGFloat = 58
            let coverRect = CGRect(x: coverX, y: coverY, width: coverSize, height: coverSize)
            let cornerRadius: CGFloat = 22
            
            let path = UIBezierPath(roundedRect: coverRect, cornerRadius: cornerRadius)
            path.addClip()
            if let image = coverImage {
                let imgSize = image.size
                let aspectW = coverSize / imgSize.width
                let aspectH = coverSize / imgSize.height
                let aspect = max(aspectW, aspectH)
                let drawW = imgSize.width * aspect
                let drawH = imgSize.height * aspect
                let drawX = coverX + (coverSize - drawW) / 2
                let drawY = coverY + (coverSize - drawH) / 2
                image.draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
            } else {
                UIColor(red: 0.2, green: 0.2, blue: 0.28, alpha: 1.0).setFill()
                UIRectFill(coverRect)
                let symbolConfig = UIImage.SymbolConfiguration(pointSize: coverSize * 0.4, weight: .light)
                if let musicIcon = UIImage(systemName: "music.note", withConfiguration: symbolConfig) {
                    let tinted = musicIcon.withTintColor(.white.withAlphaComponent(0.6), renderingMode: .alwaysOriginal)
                    let ix = coverX + (coverSize - tinted.size.width) / 2
                    let iy = coverY + (coverSize - tinted.size.height) / 2
                    tinted.draw(at: CGPoint(x: ix, y: iy))
                }
            }
            c.resetClip()
            
            UIColor.white.withAlphaComponent(0.08).setStroke()
            let borderPath = UIBezierPath(roundedRect: coverRect, cornerRadius: cornerRadius)
            borderPath.lineWidth = 1
            borderPath.stroke()
            
            let titleText = currentTitle.isEmpty ? "Mineradio" : currentTitle
            let artistText = currentArtist.isEmpty ? "" : currentArtist
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.alignment = .center
            paraStyle.lineBreakMode = .byTruncatingTail
            let titleFont = UIFont.systemFont(ofSize: 26, weight: .bold)
            let artistFont = UIFont.systemFont(ofSize: 17, weight: .regular)
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.white, .paragraphStyle: paraStyle]
            let artistAttrs: [NSAttributedString.Key: Any] = [.font: artistFont, .foregroundColor: UIColor.white.withAlphaComponent(0.5), .paragraphStyle: paraStyle]
            let textMaxWidth = w - 60
            let titleTextSize = (titleText as NSString).boundingRect(with: CGSize(width: textMaxWidth, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: titleAttrs, context: nil).size
            let titleY = coverY + coverSize + 36
            (titleText as NSString).draw(in: CGRect(x: 30, y: titleY, width: textMaxWidth, height: titleTextSize.height), withAttributes: titleAttrs)
            if !artistText.isEmpty {
                (artistText as NSString).draw(in: CGRect(x: 30, y: titleY + titleTextSize.height + 6, width: textMaxWidth, height: 24), withAttributes: artistAttrs)
            }
        }
        return rendered.cgImage!
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.pipActive = true
            self.updateNowPlayingInfo()
            swiftLog("pip_did_start", [:])
        }
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.pipActive = false
            self.pipPlayer?.seek(to: .zero)
            self.webView?.evaluateJavaScript("if(typeof exitPip==='function')exitPip()")
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            swiftLog("pip_did_stop", [:])
        }
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.pipActive = false
            print("[PiP] Failed to start: \(error)")
            swiftLog("pip_failed", ["error": error.localizedDescription])
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

struct QQLoginSheetView: View {
    @Environment(\.dismiss) var dismiss
    let onComplete: (String?) -> Void
    @State private var sheetWebView: WKWebView? = nil
    @State private var statusText: String = "正在加载 QQ 音乐官网…"

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                }
                QQSheetWebView(onWebViewCreated: { webView in
                    self.sheetWebView = webView
                }, onTitleChanged: { title in
                    self.statusText = title ?? ""
                })
            }
            .navigationBarTitle("QQ 音乐登录", displayMode: .inline)
            .navigationBarItems(
                leading: Button("取消") {
                    self.onComplete(nil)
                    self.dismiss()
                },
                trailing: Button("完成登录") {
                    self.extractCookiesAndComplete()
                }
            )
            .navigationViewStyle(.stack)
        }
    }

    private func extractCookiesAndComplete() {
        swiftLog("complete_tapped", ["sheetWebViewExists": sheetWebView != nil])
        guard sheetWebView != nil else {
            swiftLog("complete_aborted", ["reason": "sheetWebView is nil"])
            self.onComplete(nil)
            self.dismiss()
            return
        }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let qqCookies = cookies.filter { $0.domain.contains("qq.com") }
            let cookieStr = qqCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            swiftLog("cookies_extracted", ["count": qqCookies.count, "cookieStrLen": cookieStr.count])
            DispatchQueue.main.async {
                self.onComplete(cookieStr.isEmpty ? nil : cookieStr)
                self.dismiss()
            }
        }
    }
}

struct QQSheetWebView: UIViewRepresentable {
    let onWebViewCreated: (WKWebView) -> Void
    let onTitleChanged: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTitleChanged: onTitleChanged) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.scrollView.bounces = false
        webView.backgroundColor = .white
        context.coordinator.bind(to: webView)
        onWebViewCreated(webView)
        if let url = URL(string: "https://y.qq.com/n/ryqq/profile") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onTitleChanged: (String?) -> Void
        init(onTitleChanged: @escaping (String?) -> Void) { self.onTitleChanged = onTitleChanged }
        func bind(to webView: WKWebView) { webView.navigationDelegate = self }
        func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
            onTitleChanged("请在页面中扫码登录 QQ 音乐")
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: String
    let onQQLoginRequest: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onQQLoginRequest: onQQLoginRequest) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        cfg.allowsAirPlayForMediaPlayback = true

        cfg.userContentController.add(context.coordinator, name: "openQQLogin")
        cfg.userContentController.add(context.coordinator, name: "pip")

        let wrapperScript = WKUserScript(source: """
            (function() {
                function qqNativeLog(obj) {
                    try { fetch('/api/qq/qr/log', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(obj) }); } catch(e) {}
                }
                window.__qqLoginCallbacks = {};
                window.__qqLoginCallbackFromNative = function(data) {
                    qqNativeLog({ step: 'native_callback_received', callbackId: data.callbackId, ok: data.ok, cookieLen: data.cookie ? data.cookie.length : 0, message: data.message || '' });
                    var cb = window.__qqLoginCallbacks[data.callbackId];
                    if (cb) {
                        delete window.__qqLoginCallbacks[data.callbackId];
                        if (data.ok) cb.resolve({ ok: true, cookie: data.cookie });
                        else cb.reject(new Error(data.message || 'QQ 登录未完成'));
                    } else {
                        qqNativeLog({ step: 'native_callback_not_found', callbackId: data.callbackId, availableIds: Object.keys(window.__qqLoginCallbacks) });
                    }
                };
                window.iosBridge = {
                    openQQMusicLogin: function() {
                        return new Promise(function(resolve, reject) {
                            var id = 'qql_' + Date.now() + '_' + Math.random().toString(36).slice(2);
                            window.__qqLoginCallbacks[id] = { resolve: resolve, reject: reject };
                            qqNativeLog({ step: 'openQQMusicLogin_called', callbackId: id });
                            try {
                                window.webkit.messageHandlers.openQQLogin.postMessage({ callbackId: id });
                            } catch(e) {
                                delete window.__qqLoginCallbacks[id];
                                reject(e);
                            }
                        });
                    }
                };
                window.pipTogglePlay = function() { if(typeof togglePlay==='function')togglePlay(); };
                window.pipNextTrack = function() { if(typeof nextTrack==='function')nextTrack(); };
                window.pipPrevTrack = function() { if(typeof prevTrack==='function')prevTrack(); };
                qqNativeLog({ step: 'iosBridge_injected' });
            })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(wrapperScript)

        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        context.coordinator.webView = webView
        context.coordinator.pipManager.webView = webView
        MainWebViewHolder.shared.webView = webView
        
        if let u = URL(string: url) {
            let req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
            webView.load(req)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onQQLoginRequest: (String) -> Void
        weak var webView: WKWebView?
        let pipManager = PiPManager()
        private var didAttachPipHost = false

        init(onQQLoginRequest: @escaping (String) -> Void) {
            self.onQQLoginRequest = onQQLoginRequest
            super.init()
        }

        func bind(to webView: WKWebView) { webView.navigationDelegate = self }
        
        func attachPipIfNeeded(to webView: WKWebView) {
            guard !didAttachPipHost else { return }
            didAttachPipHost = true
            pipManager.attachHostView(to: webView)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "openQQLogin" {
                if let body = message.body as? [String: Any],
                   let callbackId = body["callbackId"] as? String {
                    swiftLog("openQQLogin_received", ["callbackId": callbackId])
                    onQQLoginRequest(callbackId)
                }
            } else if message.name == "pip" {
                guard let body = message.body as? [String: Any],
                      let action = body["action"] as? String else { return }
                
                switch action {
                case "enter":
                    if let wv = webView { attachPipIfNeeded(to: wv) }
                    pipManager.startPiP()
                case "exit":
                    pipManager.stopPiP()
                case "update":
                    let title = body["title"] as? String ?? ""
                    let artist = body["artist"] as? String ?? ""
                    let coverUrl = body["coverUrl"] as? String
                    
                    if let urlStr = coverUrl, let url = URL(string: urlStr) {
                        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
                            guard let self = self, error == nil else { return }
                            DispatchQueue.main.async {
                                self.pipManager.updateInfo(title: title, artist: artist, coverData: data)
                            }
                        }.resume()
                    } else {
                        pipManager.updateInfo(title: title, artist: artist, coverData: nil)
                    }
                case "bgAudioStart":
                    if let urlStr = body["url"] as? String, let url = URL(string: urlStr) {
                        pipManager.startBgAudio(url: url)
                    }
                case "bgAudioStop":
                    pipManager.stopBgAudio()
                case "bgAudioPause":
                    pipManager.pauseBgAudio()
                case "bgAudioResume":
                    pipManager.resumeBgAudio()
                default:
                    break
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            attachPipIfNeeded(to: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
            NSLog("[Mineradio] nav error: \(error.localizedDescription)")
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no"><style>
            html,body{margin:0;height:100%;background:#0a0a0a;color:#fff;font:15px -apple-system,BlinkMacSystemFont,'Helvetica Neue',sans-serif;display:flex;align-items:center;justify-content:center;flex-direction:column;gap:14px;padding:24px;text-align:center}
            h1{font-size:18px;letter-spacing:.5px;margin:0;color:#f4d28a}
            p{margin:0;opacity:.62;font-size:13px;line-height:1.6}
            code{background:rgba(255,255,255,.08);padding:4px 10px;border-radius:6px;font-size:12px;word-break:break-all}
            </style></head><body>
            <h1>无法连接 dev server</h1>
            <p>请确认 Mac 端 <code>node server.js</code> 正在运行</p>
            <p>当前 URL: <code>\(webView.url?.absoluteString ?? "")</code></p>
            <p>错误: <code>\(error.localizedDescription)</code></p>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

struct ContentView: View {
    private var devURL: String {
        "http://127.0.0.1:3000/?v=" + String(Int(Date().timeIntervalSince1970))
    }

    @State private var cacheCleared = false
    @State private var showQQSheet = false
    @State private var qqCallbackId: String? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(.all, edges: .all)
            if cacheCleared {
                WebView(
                    url: devURL,
                    onQQLoginRequest: { callbackId in
                        self.qqCallbackId = callbackId
                        self.showQQSheet = true
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all, edges: .all)
        .onAppear {
            let types: Set<String> = [
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeOfflineWebApplicationCache,
                WKWebsiteDataTypeFetchCache,
                WKWebsiteDataTypeServiceWorkerRegistrations
            ]
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: Date.distantPast) {
                DispatchQueue.main.async { self.cacheCleared = true }
            }
        }
        .sheet(isPresented: $showQQSheet) {
            QQLoginSheetView { cookieString in
                let callbackId = self.qqCallbackId
                let webView = MainWebViewHolder.shared.webView
                if let callbackId = callbackId, let webView = webView {
                    let ok = (cookieString != nil)
                    let cookie = cookieString ?? ""
                    let message = ok ? "" : "未获取到 QQ Cookie"
                    let payload: [String: Any] = [
                        "callbackId": callbackId,
                        "ok": ok,
                        "cookie": cookie,
                        "message": message
                    ]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        let js = "window.__qqLoginCallbackFromNative(\(jsonString))"
                        webView.evaluateJavaScript(js)
                    }
                }
                self.qqCallbackId = nil
            }
        }
    }
}
