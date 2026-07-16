# Mineradio 项目长期记忆

## 技术栈
- 前端: HTML/CSS/JS 单页应用 (public/index.html, 30000+ 行内联), three.js 可视化器
- 后端: Node.js (server.js), 音频代理 /api/audio?url=xxx 支持 Range
- iPad 原生壳: Swift/SwiftUI + WKWebView (ios-shell/), xcodegen 管理 project.yml

## 架构决策
- iPad 后台音频: 原生 AVPlayer 单一播放器 + MTAudioProcessingTap 频谱回传 (2026-07-17)
  - 网页 NativeAudioAdapter 伪装 HTMLAudioElement，覆写 window.Audio
  - 浏览器版不受影响 (native-audio-bridge.js 检测无 nativeAudio handler 即退出)
  - 文档: docs/IOS_BACKGROUND_AUDIO.md

## 关键文件位置
- 网页主代码: public/index.html (内联 JS)
- 原生壳: ios-shell/ContentView.swift, ios-shell/NativeAudioEngine.swift
- iOS 配置: ios-shell/project.yml (xcodegen)
- 音频代理端点: server.js ~L4775
- 可视化频谱消费: index.html ~L29500 (analyser.getByteFrequencyData)
- Web Audio 图初始化: index.html ~L19980 (initAudio)
