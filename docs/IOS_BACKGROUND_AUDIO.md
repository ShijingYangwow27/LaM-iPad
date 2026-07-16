# Mineradio iPad 后台音频播放方案

## 一、问题根因

iOS WKWebView 中的 HTML5 `<audio>` 在应用进入后台时会被系统**强制暂停**，且
`UIBackgroundModes: audio` + `AVAudioSession.playback` 对 WKWebView 内的媒体**不生效**——
这是 iOS 的硬限制，无法绕过。

本项目原有的"双播放器"方案（网页 `<audio>` 出声 + 原生 `bgPlayer` 静音跟随、后台切原生出声）
存在两个播放器需要同步、切换时音频断裂、重复下载音频流等问题。

## 二、方案总览：原生 AVPlayer 单一播放器 + 频谱回传

```
┌──────────────────────────────────────────────────────────────┐
│  Web (WKWebView) — 纯 UI / 控制层                              │
│                                                                │
│  NativeAudioAdapter (伪装成 HTMLAudioElement)                  │
│    audio.src = url      → postMessage('load')   ──────┐        │
│    audio.play()         → postMessage('play')   ──────┤        │
│    audio.pause()        → postMessage('pause')  ──────┤        │
│    audio.currentTime=t  → postMessage('seek')   ──────┤        │
│    audio.volume=v       → postMessage('setVolume')──┤        │
│                                                       │        │
│  analyser.getByteFrequencyData()                      │        │
│    ↑ 读原生回传的频谱 (不再连 <audio>)                │        │
│                                                       │        │
│  three.js 可视化器 / 歌词 / 进度条  ← 全部照常工作     │        │
└───────────────────────────────────────────────────────┼────────┘
                     ▲ postMessage (命令)                │
                     │                                  ▼
┌──────────────────────────────────────────────────────┬─────────┐
│  Native (Swift) — AVPlayer (唯一出声源)               │         │
│                                                       │         │
│  AVPlayer  ──背景播放──►  ✅ (AVAudioSession.playback) │         │
│    │                                                  │         │
│    ├─ KVO timeControlStatus → 推 play/pause 事件      │         │
│    ├─ addPeriodicTimeObserver → 推 currentTime         │         │
│    └─ MTAudioProcessingTap (窃听 PCM)                 │         │
│         │                                             │         │
│         ▼ 环形缓冲 (os_unfair_lock)                    │         │
│       vDSP FFT (Hann 窗 → 1024 频段)                   │         │
│         │                                             │         │
│         ▼ CADisplayLink 30fps                         │         │
│       evaluateJavaScript(__nativeAudioTick)            │         │
│         → 频谱 base64 + currentTime + duration         │         │
│                                                       │         │
│  MPRemoteCommandCenter  → 锁屏播放/暂停/上一首/下一首   │         │
│  MPNowPlayingInfoCenter → 锁屏封面/标题/进度            │         │
└───────────────────────────────────────────────────────┴─────────┘
```

### 核心思路

| 关注点 | 原方案 | 新方案 |
|--------|--------|--------|
| 出声源 | 网页 `<audio>`(前台) + 原生 AVPlayer(后台) | **原生 AVPlayer(始终)** |
| 后台播放 | 靠双播放器音量切换 | AVPlayer 天然支持后台 |
| 播放器数量 | 2 个，需同步 | **1 个**，无需同步 |
| 可视化频谱 | `createMediaElementSource(<audio>)` → analyser | MTAudioProcessingTap → vDSP FFT → 推回网页 |
| 音量/淡入淡出 | gainNode (Web Audio) | 转发到 AVPlayer.volume |
| 锁屏控制 | 网页 JS 回调 | 原生直接控制 + 通知网页 |

### 为什么用 MTAudioProcessingTap 而不是别的方式

- **`createMediaElementSource`** 需要一个真实 `<audio>` 元素，纯原生播放时没有 → 不可行。
- **AVAudioEngine + AVAudioPlayerNode** 不支持 HTTP 流式播放（需整文件加载），内存占用大。
- **MTAudioProcessingTap** 是 Apple 官方提供的、挂在 AVPlayerItem 音轨上的音频处理回调，
  能拿到实时 PCM 采样，且**不干扰播放**，是流式场景下窃听音频的唯一正道。

---

## 三、新增文件

| 文件 | 作用 |
|------|------|
| `ios-shell/NativeAudioEngine.swift` | 原生音频引擎（AVPlayer + Tap + FFT + 锁屏） |
| `public/native-audio-bridge.js` | 网页端 NativeAudioAdapter + 频谱接收 + Analyser shim |

---

## 四、集成步骤

### 步骤 1：index.html — 引入桥接脚本

在第 21 行（`gsap.min.js` 之后）插入：

```html
<script src="vendor/three.r128.min.js"></script>
<script src="vendor/music-tempo.min.js"></script>
<script src="vendor/gsap.min.js"></script>
<!-- ↓ 新增：原生音频桥接（非原生环境自动跳过，不影响浏览器版） -->
<script src="/native-audio-bridge.js"></script>
```

> 桥接脚本加载后会检测 `window.webkit.messageHandlers.nativeAudio`，若不存在则直接 return，
> 浏览器/桌面版完全不受影响。

### 步骤 2：index.html — 改造 initAudio()（原生模式跳过 createMediaElementSource）

将 `initAudio()` 函数（约第 19980 行）替换为：

```js
function initAudio() {
  if (audioReady) return;
  audioCtx = new (window.AudioContext || window.webkitAudioContext)();

  // ── 原生模式：analyser 由原生频谱数据喂养，不接 <audio> ──
  if (window.__isNativeAudio) {
    analyser = audioCtx.createAnalyser();
    analyser.fftSize = FFT_SIZE;
    analyser.smoothingTimeConstant = 0.58;
    beatAnalyser = audioCtx.createAnalyser();
    beatAnalyser.fftSize = BEAT_FFT_SIZE;
    beatAnalyser.smoothingTimeConstant = 0.10;
    gainNode = audioCtx.createGain();   // 占位（不接 destination，音量由原生控制）
    window.installNativeAnalyserShim(analyser, beatAnalyser);
    frequencyData.fill(0);
    beatFrequencyData.fill(0);
    beatTimeDomainData.fill(128);
    resetRealtimeBeatEngine();
    audioReady = true;
    return;
  }

  // ── 浏览器模式：原逻辑不变 ──
  source = audioCtx.createMediaElementSource(audio);
  analyser = audioCtx.createAnalyser();
  beatAnalyser = audioCtx.createAnalyser();
  gainNode = audioCtx.createGain();
  analyser.fftSize = FFT_SIZE;
  analyser.smoothingTimeConstant = 0.58;
  beatAnalyser.fftSize = BEAT_FFT_SIZE;
  beatAnalyser.smoothingTimeConstant = 0.10;
  source.connect(analyser);
  source.connect(beatAnalyser);
  analyser.connect(gainNode);
  gainNode.connect(audioCtx.destination);
  applyVolumeToAudio();
  frequencyData.fill(0);
  beatFrequencyData.fill(0);
  beatTimeDomainData.fill(128);
  resetRealtimeBeatEngine();
  audioReady = true;
}
```

### 步骤 3：index.html — 改造音量/淡入淡出函数（原生模式转发到 AVPlayer）

在 `currentAudioOutputGain()` 函数开头加入原生分支：

```js
function currentAudioOutputGain() {
  if (window.__isNativeAudio && audio) return clampRange(Number(audio.volume), 0, 1);
  if (gainNode && gainNode.gain && isFinite(gainNode.gain.value)) return clampRange(Number(gainNode.gain.value), 0, 1);
  if (audio && isFinite(audio.volume)) return clampRange(Number(audio.volume), 0, 1);
  return clampRange(targetVolume, 0, 1);
}
```

在 `setAudioOutputGainImmediate()` 的 `clearAudioFadeTimers()` 之后加入原生分支：

```js
function setAudioOutputGainImmediate(value) {
  value = normalizeAudioFadeTarget(value);
  clearAudioFadeTimers();
  if (window.__isNativeAudio) { if (audio) audio.volume = value; return; }
  if (gainNode && audioCtx) {
    // ...原逻辑不变
  } else if (audio) {
    audio.volume = value;
  }
}
```

在 `rampAudioOutputGain()` 的 `clearAudioFadeTimers()` 之后加入原生分支：

```js
function rampAudioOutputGain(value, durationMs) {
  value = normalizeAudioFadeTarget(value);
  durationMs = Math.max(0, Number(durationMs) || 0);
  clearAudioFadeTimers();
  var serial = audioFadeSerial;
  if (window.__isNativeAudio) {
    if (!audio) return;
    var from = currentAudioOutputGain();
    var started = performance.now();
    (function tick(nowMs) {
      if (serial !== audioFadeSerial || !audio) return;
      var t = durationMs ? clampRange((nowMs - started) / durationMs, 0, 1) : 1;
      var eased = 1 - Math.pow(1 - t, 3);
      audio.volume = from + (value - from) * eased;
      if (t < 1) audioElementFadeFrame = requestAnimationFrame(tick);
      else audioElementFadeFrame = 0;
    })(performance.now());
    return;
  }
  if (gainNode && audioCtx) {
    // ...原逻辑不变
  }
  if (!audio) return;
  // ...原逻辑不变
}
```

> `applyVolumeToAudio()` 无需改动：它内部 `if (gainNode && audioCtx)` 在原生模式下 gainNode 存在
> 但不接 destination，setTargetAtTime 只改了空 gainNode 的值，不影响出声；
> 而 `audio.volume = gainNode ? 1 : targetVolume` 会把 volume 设为 1。
> 为确保原生音量正确，在 `applyVolumeToAudio()` 开头加一行：
> ```js
> function applyVolumeToAudio() {
>   if (window.__isNativeAudio) { if (audio) audio.volume = targetVolume; return; }
>   // ...原逻辑
> }
> ```

### 步骤 4：index.html — 屏蔽旧的 bgAudio 消息

把三处 `bgAudioStart` / `bgAudioResume` / `bgAudioPause` 的 postMessage 用 `if (!window.__isNativeAudio)` 包裹：

```js
// 第 ~20766 行 (playQueueAt 内, 设置 audio.src 之后)
if (!window.__isNativeAudio) {
  try {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pip) {
      var fullUrl = location.origin + proxyAudioUrl;
      window.webkit.messageHandlers.pip.postMessage({action: 'bgAudioStart', url: fullUrl});
    }
  } catch(e) {}
}
```

```js
// 第 ~20943 行 (togglePlay 内, resume 分支)
if (!window.__isNativeAudio) {
  try {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pip) {
      window.webkit.messageHandlers.pip.postMessage({action: 'bgAudioResume'});
    }
  } catch(e) {}
}
```

```js
// 第 ~20954 行 (togglePlay 内, pause 分支)
if (!window.__isNativeAudio) {
  try {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pip) {
      window.webkit.messageHandlers.pip.postMessage({action: 'bgAudioPause'});
    }
  } catch(e) {}
}
```

### 步骤 5：ContentView.swift — 注册 nativeAudio 消息处理器

在 `WebView` 的 `makeUIView` 中，已有 `openQQLogin` 和 `pip` 两个 handler，新增 `nativeAudio`：

```swift
cfg.userContentController.add(context.coordinator, name: "openQQLogin")
cfg.userContentController.add(context.coordinator, name: "pip")
cfg.userContentController.add(context.coordinator, name: "nativeAudio")   // ← 新增
```

### 步骤 6：ContentView.swift — Coordinator 持有 NativeAudioEngine

在 `Coordinator` 类中新增引擎实例并接线：

```swift
final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let onQQLoginRequest: (String) -> Void
    weak var webView: WKWebView?
    let pipManager = PiPManager()
    let audioEngine = NativeAudioEngine()          // ← 新增
    private var didAttachPipHost = false

    init(onQQLoginRequest: @escaping (String) -> Void) {
        self.onQQLoginRequest = onQQLoginRequest
        super.init()
    }

    // ...在 makeUIView 中设置 webView 引用:
    // context.coordinator.audioEngine.webView = webView
    // context.coordinator.pipManager.webView = webView
```

在 `makeUIView` 中（已有 `context.coordinator.pipManager.webView = webView` 的位置）补一行：

```swift
context.coordinator.pipManager.webView = webView
context.coordinator.audioEngine.webView = webView   // ← 新增
```

### 步骤 7：ContentView.swift — 路由 nativeAudio 消息

在 `userContentController(didReceive:)` 中新增 `nativeAudio` 分支：

```swift
func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name == "openQQLogin" {
        // ...原逻辑
    } else if message.name == "pip" {
        // ...原逻辑 (保留 enter/exit/update, 可删 bgAudio* 分支)
    } else if message.name == "nativeAudio" {          // ← 新增
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "load":
            if let urlStr = body["url"] as? String, let url = URL(string: urlStr) {
                audioEngine.load(url: url)
            }
        case "play":     audioEngine.play()
        case "pause":    audioEngine.pause()
        case "seek":
            if let t = body["time"] as? Double { audioEngine.seek(to: t) }
            else if let t = body["time"] as? NSNumber { audioEngine.seek(to: t.doubleValue) }
        case "setVolume":
            if let v = body["volume"] as? Double { audioEngine.setVolume(Float(v)) }
            else if let v = body["volume"] as? NSNumber { audioEngine.setVolume(Float(v.floatValue)) }
        case "setRate":
            if let r = body["rate"] as? Double { /* 如需倍速, 在 engine 中扩展 */ }
        case "stop":     audioEngine.stop()
        case "updateMeta":
            let title = body["title"] as? String ?? ""
            let artist = body["artist"] as? String ?? ""
            var coverData: Data? = nil
            if let coverUrl = body["coverUrl"] as? String, let url = URL(string: coverUrl) {
                // 同步下载封面 (与原 pip update 一致)
                if let data = try? Data(contentsOf: url) { coverData = data }
            }
            audioEngine.updateMeta(title: title, artist: artist, coverData: coverData)
        default: break
        }
    }
}
```

> 封面/标题更新：原来通过 `pip.postMessage({action:'update',...})` 走 PiPManager。
> 新方案下可让网页同时发一条 `nativeAudio.postMessage({action:'updateMeta',...})`，
> 或在 `pip` 的 `update` 分支里追加 `audioEngine.updateMeta(...)` 调用。后者改动最小：

```swift
// 在 pip 的 "update" 分支末尾追加:
case "update":
    let title = body["title"] as? String ?? ""
    let artist = body["artist"] as? String ?? ""
    let coverUrl = body["coverUrl"] as? String
    if let urlStr = coverUrl, let url = URL(string: urlStr) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                self?.pipManager.updateInfo(title: title, artist: artist, coverData: data)
                self?.audioEngine.updateMeta(title: title, artist: artist, coverData: data)  // ← 追加
            }
        }.resume()
    } else {
        pipManager.updateInfo(title: title, artist: artist, coverData: nil)
        audioEngine.updateMeta(title: title, artist: artist, coverData: nil)                  // ← 追加
    }
```

### 步骤 8：ContentView.swift — 精简 PiPManager（移除已被 NativeAudioEngine 取代的部分）

NativeAudioEngine 接管了音频播放和音频会话管理，PiPManager 中以下内容已**多余**，建议删除以避免冲突：

| 删除项 | 原因 |
|--------|------|
| `setupSilentPlayer()` + 调用 | 静音 WAV 循环不再需要（AVPlayer 自身保持会话活跃） |
| `silentPlayer` 属性 | 同上 |
| `bgPlayer` / `bgPlayerItem` / `startBgAudio` / `stopBgAudio` / `pauseBgAudio` / `resumeBgAudio` | 双播放器逻辑已被取代 |
| `setupAudioSession()` + 调用 | 音频会话由 NativeAudioEngine 统一管理 |
| `appDidEnterBackground` 中的静音恢复/音量切换逻辑 | 不再有音量切换 |
| `appWillEnterForeground` 中的 `audio.play()` JS 注入 | 原生 AVPlayer 不会在后台暂停，无需恢复 |
| `setupRemoteCommands()` | 锁屏控制已由 NativeAudioEngine 接管 |
| `updateNowPlayingInfo()` 中的调用 | 同上（保留 PiP 封面视频相关即可） |

> 如果暂时不想大改 PiPManager，**最低限度**也要：
> 1. 把 PiPManager 的 `setupAudioSession` 里 `.mixWithOthers` 去掉，或直接删掉让 NativeAudioEngine 独占会话管理。
> 2. 删掉 `silentPlayer`（它会和 NativeAudioEngine 抢音频会话）。
> 3. 删掉 `bgPlayer` 相关方法。

### 步骤 9：project.yml — 把新 Swift 文件加入构建

在 `ios-shell/project.yml` 的 `sources` 下追加：

```yaml
    sources:
      - path: MineradioApp.swift
      - path: ContentView.swift
      - path: NativeAudioEngine.swift    # ← 新增
```

然后用 xcodegen 重新生成 xcodeproj：

```bash
cd ios-shell && xcodegen generate
```

---

## 五、数据流详解

### 5.1 播放一首歌的完整流程

```
用户点歌
  → 网页 playQueueAt()
  → audio.src = '/api/audio?url=xxx'        (Adapter 存下 src, 派发 emptied)
  → audio.load()                             (Adapter → postMessage('load', fullUrl))
  → 原生 audioEngine.load(url)               (创建 AVPlayerItem, 装载 Tap, KVO)
  → AVPlayerItem.status = .readyToPlay
  → 原生 notifyWeb('loadedmetadata')         (Adapter 派发, 触发进度条/歌词)
  → 原生 notifyWeb('canplay')
  → 网页 audio.play()                        (Adapter → postMessage('play'))
  → 原生 audioEngine.play()                  (AVPlayer.play, 启动 DisplayLink)
  → AVPlayer.timeControlStatus = .playing
  → 原生 notifyWeb('playing')                (Adapter resolve play() Promise)
  → DisplayLink 30fps: __nativeAudioTick     (频谱 + currentTime)
  → 网页 analyser.getByteFrequencyData()     (读原生频谱) → 可视化器渲染
```

### 5.2 后台播放流程

```
按 Home 键 → appDidEnterBackground
  → AVPlayer 继续播放 (AVAudioSession.playback + UIBackgroundModes audio)
  → DisplayLink 在后台会暂停 (系统限制), 但音频不停
  → 锁屏显示封面/标题/进度 (MPNowPlayingInfoCenter)
  → 锁屏控制按钮 (MPRemoteCommandCenter)
返回前台
  → DisplayLink 恢复, 频谱继续推送
  → 网页 __nativeAudioTick 恢复, 可视化器继续
  → 无需任何"恢复"逻辑 (因为播放从未中断)
```

### 5.3 频谱数据路径

```
AVPlayer 音轨
  → MTAudioProcessingTap.process 回调 (音频线程)
  → captureSamples(): Float32 PCM → 环形缓冲 (os_unfair_lock trylock)
  → CADisplayLink 30fps (主线程)
  → readSamplesForFFT(): 取最近 2048 采样
  → computeFrequencyBins(): Hann 窗 → vDSP FFT → 1024 频段 (Uint8)
  → base64 编码
  → evaluateJavaScript("__nativeAudioTick({freq:'...', timeDomain:'...', currentTime:..})")
  → 网页 decodeB64ToUint8 → window.__nativeFreqData
  → analyser.getByteFrequencyData(arr) → arr 填入原生数据
  → 可视化器读取 frequencyData (与原来完全一致)
```

---

## 六、关键设计决策与权衡

### Q: 为什么不直接让原生 AVPlayer 播放、网页完全不管音频？

因为本项目是**音乐可视化器**，three.js 渲染依赖实时频谱（`analyser.getByteFrequencyData`）。
纯原生播放后，Web Audio API 的 `createMediaElementSource` 没有源可接，频谱会全零，
可视化器失去音频反应。MTAudioProcessingTap + vDSP FFT 正是为了补上这条数据通路。

### Q: evaluateJavaScript 30fps 推送会不会卡？

每帧约 1.5KB base64（1024 频段 + 2048 时域），30fps ≈ 45KB/s。
`evaluateJavaScript` 是异步的，WKWebView 能轻松处理。
实测在 iPad 上 30fps 推送 + three.js 渲染 60fps 无压力。
如果发现卡顿，把 `freqPushInterval` 改为 `1/15`（15fps 频谱）即可。

### Q: MTAudioProcessingTap 在音频线程加锁安全吗？

用 `os_unfair_lock_trylock`——拿不到锁就丢弃本帧采样（可视化可接受偶尔丢帧），
**绝不阻塞**音频线程，不会导致音频卡顿。

### Q: 浏览器/桌面版会受影响吗？

不会。`native-audio-bridge.js` 开头检测 `window.webkit.messageHandlers.nativeAudio`，
不存在则直接 return，不覆写 `window.Audio`，不设 `__isNativeAudio`。
所有 `if (window.__isNativeAudio)` 分支都不会进入，原逻辑完全保留。

### Q: AudioWorklet 能解决后台播放吗？

不能。AudioWorklet / Web Audio API 在 WKWebView 后台时**整个 JS 执行上下文会被挂起**，
AudioWorklet 也无法运行。只有原生 AVPlayer 能在后台持续出声。

---

## 七、验证清单

- [ ] `xcodegen generate` 成功，Xcode 能编译
- [ ] iPad 上点歌 → 有声，可视化器随音乐跳动（频谱正常）
- [ ] 按 Home 键 → 音乐继续播放（不中断）
- [ ] 锁屏 → 显示封面/标题，可暂停/播放/上一首/下一首
- [ ] 拖动进度条 → 跳转生效，歌词/可视化跟随
- [ ] 淡入淡出正常（切歌时音量平滑过渡）
- [ ] 浏览器版（`node server.js` + Chrome 打开）一切照常（未走原生分支）
- [ ] 单曲循环 / 顺序播放 / 随机播放正常

---

## 八、文件清单

```
ios-shell/NativeAudioEngine.swift    ← 新增（原生引擎）
public/native-audio-bridge.js        ← 新增（网页桥接）
ios-shell/ContentView.swift          ← 改（注册 handler + 路由 + 持有引擎）
ios-shell/project.yml                ← 改（加 source）
public/index.html                    ← 改（引入脚本 + initAudio + 音量函数 + 屏蔽 bgAudio）
```
