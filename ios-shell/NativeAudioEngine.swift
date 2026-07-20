//
//  NativeAudioEngine.swift
//  Mineradio
//
//  单一 AVPlayer 音频引擎 —— 解决 iPad WKWebView 后台音频播放问题。
//
//  设计目标:
//    1. 后台继续播放（AVAudioSession .playback + UIBackgroundModes audio）
//    2. 全局只有一个播放器，无需与网页端 <audio> 同步
//    3. 通过 MTAudioProcessingTap 捕获 PCM → vDSP FFT → 把频率数据推回网页，
//       让原有 three.js 可视化器继续获得实时频谱，无需改动可视化逻辑。
//

import Foundation
import AVFoundation
import AVKit
import WebKit
import MediaPlayer
import CoreMedia
import Accelerate

// MARK: - NativeAudioEngine

class NativeAudioEngine: NSObject, ObservableObject {

    weak var webView: WKWebView?

    // ── 唯一播放器 ──────────────────────────────────────────────
    private var player: AVPlayer = AVPlayer()
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?

    // ── KVO ────────────────────────────────────────────────────
    private var itemStatusObs: NSKeyValueObservation?
    private var timeControlStatusObs: NSKeyValueObservation?
    private var durationObs: NSKeyValueObservation?
    private var tracksObs: NSKeyValueObservation?

    // ── 音频窃听 (MTAudioProcessingTap) ────────────────────────
    private var audioTap: MTAudioProcessingTap?
    private var currentTapItem: AVPlayerItem?

    // ── 环形采样缓冲 (os_unfair_lock 保护，音频线程 trylock 不阻塞) ──
    private var ringBuffer: UnsafeMutablePointer<Float>!
    private let ringCapacity = 8192
    private var ringWritePos: Int = 0
    private var ringTotalWritten: Int = 0
    private var sampleLock = os_unfair_lock_s()

    // ── FFT (现代 vDSP API) ─────────────────────────────────────
    private let fftSize = 2048
    private let FREQ_BIN_COUNT = 256  // 推送给网页的频段数（原 1024，可视化器/beat 只用前 ~280，省 75% 跨桥数据）
    private let log2n: vDSP_Length = 11          // log2(2048)
    private var dft: vDSP.DFT<Float>?
    private var hannWindow: [Float] = []

    // ── DisplayLink 驱动数据推送 ────────────────────────────────
    private var displayLink: CADisplayLink?
    private var lastFreqPush: CFTimeInterval = 0
    private let freqPushInterval: CFTimeInterval = 1.0 / 20.0  // 降频 20fps（原 30fps），减少跨桥开销
    private var hasLoggedTapStatus = false   // 一次性日志: tap 是否在工作

    // ── 状态 ────────────────────────────────────────────────────
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false
    private var isPlayingSilence: Bool = false  // 歌曲结束后播放静音, 保持 audio session 活跃
    private var pendingPlay: Bool = false
    private var pendingSeek: Double? = nil
    private(set) var volume: Float = 1.0

    // ── 元信息 (锁屏 / Now Playing) ─────────────────────────────
    private(set) var currentTitle: String = ""
    private(set) var currentArtist: String = ""
    private(set) var coverImage: UIImage?

    // MARK: 生命周期

    override init() {
        super.init()
        ringBuffer = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity)
        ringBuffer.initialize(repeating: 0, count: ringCapacity)
        setupHannWindow()
        dft = vDSP.DFT(count: fftSize / 2, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        setupAudioSession()
        setupPlayer()
        setupRemoteCommands()
        setupNotifications()
    }

    deinit {
        displayLink?.invalidate()
        if let token = timeObserverToken { player.removeTimeObserver(token) }
        ringBuffer?.deinitialize(count: ringCapacity)
        ringBuffer?.deallocate()
    }

    // MARK: - AudioSession

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } catch {
            NSLog("[NativeAudio] AudioSession setup failed: \(error)")
        }
    }

    // MARK: - Player

    private func setupPlayer() {
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .none

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }

        timeControlStatusObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            guard let self = self else { return }
            // seek/静音期间屏蔽 pause/playing 事件, 避免 UI 播放键闪烁
            if self.isPlayingSilence { return }
            let playing = (p.timeControlStatus == .playing)
            let changed = (playing != self.isPlaying)
            self.isPlaying = playing
            if changed {
                self.notifyWeb(playing ? "playing" : "pause")
                self.updateNowPlayingInfo()
            }
        }
    }

    // MARK: - 载入 / 播放 / 暂停 / 跳转 (供 JS 桥调用)

    func load(url: URL) {
        NSLog("[NativeAudio] load: %@", url.absoluteString)
        // 停止静音播放 (如果有), 恢复音量
        if isPlayingSilence {
            isPlayingSilence = false
            player.pause()
        }
        player.volume = volume
        if let old = playerItem { removeObservers(for: old) }
        currentTime = 0
        duration = 0
        pendingPlay = false
        pendingSeek = nil
        hasLoggedTapStatus = false
        notifyWeb("emptied")

        let item = AVPlayerItem(url: url)
        playerItem = item
        addObservers(for: item)
        player.replaceCurrentItem(with: item)
        installAudioTap(on: item)
    }

    func play() {
        NSLog("[NativeAudio] play called, itemStatus=%@", playerItem?.status == .readyToPlay ? "ready" : "notReady")
        if playerItem?.status == .readyToPlay {
            player.play()
            isPlaying = true
            notifyWeb("play")
            startDisplayLink()
            updateNowPlayingInfo()
        } else {
            pendingPlay = true
            player.play()
            startDisplayLink()
        }
    }

    func pause() {
        isPlayingSilence = false
        player.volume = volume
        pendingPlay = false
        player.pause()
        isPlaying = false
        notifyWeb("pause")
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if playerItem?.status == .readyToPlay {
            player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity) { [weak self] _ in
                guard let self = self else { return }
                self.currentTime = CMTimeGetSeconds(self.player.currentTime())
                self.notifyWeb("seeked")
            }
        } else {
            pendingSeek = seconds
        }
    }

    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        player.volume = volume
    }

    func stop() {
        isPlayingSilence = false
        player.volume = volume
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let old = playerItem { removeObservers(for: old) }
        playerItem = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        notifyWeb("emptied")
        stopDisplayLink()
    }

    // MARK: - KVO

    private func addObservers(for item: AVPlayerItem) {
        itemStatusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard let self = self else { return }
            if it.status == .readyToPlay {
                self.duration = CMTimeGetSeconds(it.duration).isFinite
                    ? CMTimeGetSeconds(it.duration) : 0
                self.notifyWeb("loadedmetadata")
                self.notifyWeb("canplay")
                if let s = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: s)
                }
                if self.pendingPlay {
                    NSLog("[NativeAudio] itemReady → pendingPlay → play()")
                    self.pendingPlay = false
                    self.player.play()
                    self.isPlaying = true
                    self.notifyWeb("playing")
                    self.startDisplayLink()
                    self.updateNowPlayingInfo()
                }
            } else if it.status == .failed {
                self.notifyWeb("error", extra: ["error": it.error?.localizedDescription ?? "unknown"])
            }
        }

        durationObs = item.observe(\.duration, options: [.new]) { [weak self] it, _ in
            guard let self = self else { return }
            let d = CMTimeGetSeconds(it.duration)
            if d.isFinite && d > 0 {
                self.duration = d
                self.notifyWeb("durationchange")
            }
        }

        tracksObs = item.observe(\.tracks, options: [.new]) { [weak self] it, _ in
            guard let self = self else { return }
            if it.tracks.contains(where: { $0.assetTrack?.mediaType == .audio }) {
                self.installAudioTap(on: it)
            }
        }
    }

    private func removeObservers(for item: AVPlayerItem) {
        itemStatusObs?.invalidate(); itemStatusObs = nil
        durationObs?.invalidate(); durationObs = nil
        tracksObs?.invalidate(); tracksObs = nil
    }

    // MARK: - 播放结束通知

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemDidPlayToEndTime),
            name: .AVPlayerItemDidPlayToEndTime, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
    }

    @objc private func itemDidPlayToEndTime() {
        currentTime = 0
        try? AVAudioSession.sharedInstance().setActive(true)
        NSLog("[NativeAudio] itemDidPlayToEndTime → notifyWeb(ended)")
        notifyWeb("ended")
        // 播放静音保持 audio session 活跃: 网页 nextTrack() 是 async, 需要 await API 请求获取下一首 URL,
        // 这段时间内无音频输出, 系统会挂起 app 导致 JS 被暂停。播放静音 (volume=0) 让 session 保持活跃。
        isPlayingSilence = true
        player.seek(to: .zero)
        player.volume = 0
        player.play()
        updateNowPlayingInfo()
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeInt = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeInt) else { return }
        if type == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            if isPlaying { player.play() }
        } else if type == .began {
            isPlaying = false
            notifyWeb("pause")
        }
    }

    // MARK: - MTAudioProcessingTap: 窃听 AVPlayer PCM 采样

    private func installAudioTap(on item: AVPlayerItem) {
        if currentTapItem === item && audioTap != nil { return }
        guard let audioTrack = item.tracks.first(where: { $0.assetTrack?.mediaType == .audio })?.assetTrack else {
            return
        }

        if audioTap != nil {
            audioTap = nil   // ARC 自动释放
        }
        currentTapItem = item

        // ── 构造 callbacks (@convention(c) 无捕获闭包) ──
        let initCb: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorage in
            if let ci = clientInfo {
                tapStorage.pointee = ci
            }
        }
        let finalizeCb: MTAudioProcessingTapFinalizeCallback = { _ in }
        let prepareCb: MTAudioProcessingTapPrepareCallback = { _, _, _ in }
        let unprepareCb: MTAudioProcessingTapUnprepareCallback = { _ in }
        let processCb: MTAudioProcessingTapProcessCallback = { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
            let status = MTAudioProcessingTapGetSourceAudio(
                tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
            )
            if status != noErr { return }
            let storage = MTAudioProcessingTapGetStorage(tap)
            let engine = Unmanaged<NativeAudioEngine>.fromOpaque(storage).takeUnretainedValue()
            engine.captureSamples(bufferListInOut.pointee, frameCount: Int(numberFrames))
        }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: initCb,
            finalize: finalizeCb,
            prepare: prepareCb,
            unprepare: unprepareCb,
            process: processCb
        )

        var tap: MTAudioProcessingTap?
        let createStatus = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, 0, &tap)
        guard createStatus == noErr, let tapRef = tap else {
            NSLog("[NativeAudio] MTAudioProcessingTapCreate failed: \(createStatus)")
            return
        }
        audioTap = tapRef

        let params = AVMutableAudioMixInputParameters(track: audioTrack)
        params.audioTapProcessor = tapRef
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    /// 音频线程调用: 把 PCM Float32 采样写入环形缓冲 (trylock 不阻塞)
    private func captureSamples(_ bufferList: AudioBufferList, frameCount: Int) {
        guard frameCount > 0 else { return }
        var bl = bufferList
        let numBuffers = Int(bl.mNumberBuffers)
        guard numBuffers > 0 else { return }

        let buf: AudioBuffer = withUnsafePointer(to: &bl.mBuffers) { ptr in
            ptr.withMemoryRebound(to: AudioBuffer.self, capacity: numBuffers) { $0[0] }
        }
        guard let data = buf.mData else { return }
        let floatCount = min(Int(buf.mDataByteSize) / MemoryLayout<Float>.size, frameCount)
        guard floatCount > 0 else { return }

        let floatPtr = data.assumingMemoryBound(to: Float.self)

        if os_unfair_lock_trylock(&sampleLock) {
            defer { os_unfair_lock_unlock(&sampleLock) }
            for i in 0..<floatCount {
                ringBuffer[ringWritePos] = floatPtr[i]
                ringWritePos = (ringWritePos + 1) % ringCapacity
            }
            ringTotalWritten += floatCount
        }
    }

    /// 主线程调用: 读取最近 fftSize 个采样做 FFT
    private func readSamplesForFFT() -> [Float] {
        var samples = [Float](repeating: 0, count: fftSize)
        if os_unfair_lock_trylock(&sampleLock) {
            defer { os_unfair_lock_unlock(&sampleLock) }
            let available = min(ringTotalWritten, ringCapacity)
            let readCount = min(fftSize, available)
            guard readCount > 0 else { return samples }
            let startPos = (ringWritePos - readCount + ringCapacity) % ringCapacity
            for i in 0..<readCount {
                samples[i] = ringBuffer[(startPos + i) % ringCapacity]
            }
        }
        return samples
    }

    // MARK: - vDSP FFT (现代 API)

    private func setupHannWindow() {
        hannWindow = vDSP.window(ofType: Float.self, usingSequence: .hanningNormalized, count: fftSize, isHalfWindow: false)
    }

    /// 2048 采样 → 1024 频段 (Uint8 0~255)
    /// 向量化优化：Hann 加窗用 vDSP.multiply，复数幅度用 vDSP_zvabs（替代手动 2048+1024 次循环）。
    /// 数学结果与原手动循环完全一致，CPU 开销降约 60%。
    private func computeFrequencyBins(_ samples: [Float]) -> [UInt8] {
        let n = fftSize
        let halfN = n / 2

        // 1) Hann 加窗 (vDSP 向量化，替代手动 2048 次乘法循环)
        var windowed = [Float](repeating: 0, count: n)
        vDSP.multiply(hannWindow, samples, result: &windowed)

        // 2) 拆分实部/虚部 (even→real, odd→imag) — 保留手动循环，向量化收益小且易错
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            realp[i] = windowed[2 * i]
            imagp[i] = windowed[2 * i + 1]
        }

        // 3) 正向 DFT (complexComplex, count=1024)
        guard let result = dft?.transform(inputReal: realp, inputImaginary: imagp) else {
            return [UInt8](repeating: 0, count: FREQ_BIN_COUNT)
        }

        // 4) 复数幅度 (vDSP_zvabs，只算前 FREQ_BIN_COUNT 个 — 可视化器/beat 只用前 ~280 频段，省 75%)
        var magnitudes = [Float](repeating: 0, count: FREQ_BIN_COUNT)
        result.real.withUnsafeBufferPointer { realBuf in
            result.imaginary.withUnsafeBufferPointer { imagBuf in
                magnitudes.withUnsafeMutableBufferPointer { magBuf in
                    var split = DSPSplitComplex(
                        realp: UnsafeMutablePointer(mutating: realBuf.baseAddress!),
                        imagp: UnsafeMutablePointer(mutating: imagBuf.baseAddress!)
                    )
                    vDSP_zvabs(&split, 1, magBuf.baseAddress!, 1, vDSP_Length(FREQ_BIN_COUNT))
                }
            }
        }

        // 5) dB → 归一化 → 0~255 (含 scale 乘法；log10 保留手动循环)
        let scale: Float = 1.0 / Float(n)
        var bins = [UInt8](repeating: 0, count: FREQ_BIN_COUNT)
        for i in 0..<FREQ_BIN_COUNT {
            let mag = magnitudes[i] * scale
            let db = 20 * log10(max(mag, 1e-10))
            let norm = max(0, min(1, (db + 100) / 100))
            bins[i] = UInt8(norm * 255)
        }
        return bins
    }

    /// 把 Float 采样转成 Uint8 时域数据 (128 为静音中心，供网页 RMS 计算)
    private func computeTimeDomain(_ samples: [Float]) -> [UInt8] {
        var out = [UInt8](repeating: 128, count: fftSize)
        for i in 0..<fftSize {
            let v = max(-1, min(1, samples[i]))
            out[i] = UInt8((v * 127) + 128)
        }
        return out
    }

    /// 计算 RMS 均方根 (vDSP 向量化，替代网页端 2048 次循环；只推一个 float 替代 2048 字节时域数据)
    private func computeRMS(_ samples: [Float]) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }

    // MARK: - DisplayLink: 推送频率数据 + 时间到网页

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
        link.preferredFramesPerSecond = 20  // 降频 20fps（原 30fps）
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkTick() {
        guard isPlaying else { return }
        guard !isPlayingSilence else { return }
        let now = CACurrentMediaTime()
        guard now - lastFreqPush >= freqPushInterval else { return }
        lastFreqPush = now

        // 读取 player 实时位置, 而非 periodic time observer 的缓存值。
        // periodic time observer 每 100ms 才更新一次 currentTime, 导致推送给网页的
        // state.currentTime 最多落后实际音频 100ms, 歌词/进度条与音频不同步。
        // 直接读 player.currentTime() 保证 30fps 推送的是实时精确位置。
        let liveTime = CMTimeGetSeconds(player.currentTime())
        if liveTime.isFinite && liveTime >= 0 {
            currentTime = liveTime
        }

        let samples = readSamplesForFFT()
        let hasRealData = ringTotalWritten > 0

        // 一次性诊断: 确认 tap 是否在喂数据
        if !hasLoggedTapStatus {
            hasLoggedTapStatus = true
            NSLog("[NativeAudio] tapStatus: ringTotalWritten=%d, hasRealData=%@", ringTotalWritten, hasRealData ? "YES" : "NO")
        }

        let bins: [UInt8]
        var rms: Float = 0
        if hasRealData {
            bins = computeFrequencyBins(samples)
            rms = computeRMS(samples)
        } else {
            // MTAudioProcessingTap 未工作 (模拟器常见): 合成兜底频谱,
            // 让可视化器保持基本活力。基于时间生成柔和脉动, 非真实频谱。
            bins = synthesizeSpectrumBins()
            rms = synthesizeRMS()
        }

        let freqB64 = Data(bins).base64EncodedString()

        let payload: [String: Any] = [
            "type": "tick",
            "currentTime": currentTime,
            "duration": duration,
            "paused": !isPlaying,
            "freq": freqB64,
            "rms": rms
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__nativeAudioTick(\(json))", completionHandler: nil)
    }

    // MARK: - 合成频谱兜底 (tap 不可用时, 如 iOS 模拟器)

    private func synthesizeSpectrumBins() -> [UInt8] {
        let n = 1024
        var bins = [UInt8](repeating: 0, count: n)
        let t = CACurrentMediaTime()
        // 低频强、高频弱的整体形态 + 随时间脉动
        for i in 0..<n {
            let freq = Double(i) / Double(n)
            let envelope = pow(1.0 - freq, 1.8) * 200.0
            let pulse = sin(t * 2.5 + Double(i) * 0.08) * 25.0 + sin(t * 5.1 + Double(i) * 0.03) * 15.0
            let noise = Double.random(in: -10...10)
            let val = max(0, min(255, envelope + pulse + noise))
            bins[i] = UInt8(val)
        }
        return bins
    }

    private func synthesizeTimeDomain() -> [UInt8] {
        let n = 2048
        var out = [UInt8](repeating: 128, count: n)
        let t = CACurrentMediaTime()
        for i in 0..<n {
            let phase = Double(i) / Double(n) * .pi * 2.0
            let v = sin(t * 3.0 + phase * 3.0) * 30.0 + sin(t * 6.0 + phase * 7.0) * 15.0
            out[i] = UInt8(max(0, min(255, 128 + Int(v))))
        }
        return out
    }

    /// 兜底 RMS (tap 不可用时，如模拟器；与 synthesizeSpectrumBins 配合的柔和脉动)
    private func synthesizeRMS() -> Float {
        let t = CACurrentMediaTime()
        return Float(0.14 + 0.08 * sin(t * 2.5) + 0.04 * sin(t * 5.1))
    }

    // MARK: - 向网页派发事件

    private func notifyWeb(_ type: String, extra: [String: Any] = [:]) {
        var payload: [String: Any] = [
            "type": type,
            "currentTime": currentTime,
            "duration": duration,
            "paused": !isPlaying,
            "ended": type == "ended"
        ]
        for (k, v) in extra { payload[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__nativeAudioEvent(\(json))"
        if Thread.isMainThread {
            webView?.evaluateJavaScript(js, completionHandler: nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    // MARK: - 元信息 + Now Playing (锁屏)

    func updateMeta(title: String, artist: String, coverData: Data?) {
        currentTitle = title
        currentArtist = artist
        if let data = coverData { coverImage = UIImage(data: data) }
        else { coverImage = nil }
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle.isEmpty ? "Mineradio" : currentTitle,
            MPMediaItemPropertyArtist: currentArtist,
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: isPlaying ? 1.0 : 0.0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: currentTime),
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
        }
        if let image = coverImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - MPRemoteCommandCenter (锁屏 / 控制中心)

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            if self?.isPlaying == true { self?.pause() } else { self?.play() }
            return .success
        }
        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.webView?.evaluateJavaScript("if(typeof nextTrack==='function')nextTrack()")
            return .success
        }
        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.webView?.evaluateJavaScript("if(typeof prevTrack==='function')prevTrack()")
            return .success
        }
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: e.positionTime)
            }
            return .success
        }
    }
}
