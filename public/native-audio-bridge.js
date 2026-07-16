/*!
 * native-audio-bridge.js — Mineradio iOS 原生音频桥接
 *
 * 作用: 在 iPad 原生壳(WKWebView)中, 用一个"虚拟 Audio 元素"(NativeAudioAdapter)
 *      替代 HTML5 <audio>, 把所有播放控制转发给原生 AVPlayer。
 *      原生 AVPlayer 是唯一的出声源, 天然支持后台播放。
 *      同时原生会通过 MTAudioProcessingTap + FFT 把频谱数据推回来,
 *      原有 Web Audio API 可视化器(analyser)照常工作, 无需改动。
 *
 * 接入方式:
 *   1. 在 index.html 中, 在主应用脚本之前引入本文件:
 *      <script src="/native-audio-bridge.js"></script>
 *   2. 本文件会在检测到原生环境时自动覆写 window.Audio,
 *      使现有代码里的 `new Audio()` 返回 NativeAudioAdapter 单例。
 *   3. 修改 initAudio() / applyVolumeToAudio() 等少量函数 (见集成文档)。
 *
 * 非原生环境(桌面/浏览器)本文件不做任何事, 完全向后兼容。
 */
(function () {
  'use strict';

  var handler =
    window.webkit &&
    window.webkit.messageHandlers &&
    window.webkit.messageHandlers.nativeAudio;
  if (!handler) return; // 非原生环境, 直接退出, 不影响浏览器版

  window.__isNativeAudio = true;

  // ── 由原生维护的状态 (原生通过 __nativeAudioEvent / __nativeAudioTick 更新) ──
  var state = {
    currentTime: 0,
    duration: 0,
    paused: true,
    ended: false,
    readyState: 0,
    volume: 1,
    muted: false,
    src: '',
    playbackRate: 1
  };

  // ── 频谱缓冲 (原生 base64 推送, 这里解码后填入) ──
  var freqData = null;      // Uint8Array(1024)
  var timeData = null;      // Uint8Array(2048)
  window.__nativeFreqData = null;
  window.__nativeTimeDomainData = null;

  function decodeB64ToUint8(b64) {
    var bin = atob(b64);
    var arr = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    return arr;
  }

  // ════════════════════════════════════════════════════════════
  //  NativeAudioAdapter —— 实现 HTMLAudioElement 所需子集
  // ════════════════════════════════════════════════════════════
  function NativeAudioAdapter() {
    this._listeners = {};
    this._onended = null;
    this._onplay = null;
    this._onpause = null;
    this._ontimeupdate = null;
    this._onloadedmetadata = null;
    this._oncanplay = null;
    this._onseeked = null;
    this._pendingResolve = null;
    this._pendingReject = null;
    this.crossOrigin = 'anonymous';
  }

  NativeAudioAdapter.prototype = {
    // ── 属性 ──
    get src() { return state.src; },
    set src(v) {
      state.src = v;
      state.readyState = 0;
      state.ended = false;
      state.duration = 0;
      state.currentTime = 0;
      state.paused = true;
      this._dispatch('emptied');
    },

    get currentTime() { return state.currentTime; },
    set currentTime(t) {
      state.currentTime = t;
      handler.postMessage({ action: 'seek', time: t });
      // 立即更新 UI, 原生 seek 完成后会再派发 seeked
      this._dispatch('seeking');
    },

    get duration() { return state.duration; },
    get paused() { return state.paused; },
    get ended() { return state.ended; },
    get readyState() { return state.readyState; },

    get volume() { return state.muted ? 0 : state.volume; },
    set volume(v) {
      state.volume = v;
      handler.postMessage({ action: 'setVolume', volume: v });
    },

    get muted() { return state.muted; },
    set muted(v) {
      state.muted = !!v;
      handler.postMessage({ action: 'setVolume', volume: state.muted ? 0 : state.volume });
    },

    get playbackRate() { return state.playbackRate; },
    set playbackRate(v) {
      state.playbackRate = v;
      handler.postMessage({ action: 'setRate', rate: v });
    },

    set crossOrigin(v) { /* 原生流无需 CORS, 忽略 */ },

    // ── 方法 ──
    play: function () {
      var self = this;
      return new Promise(function (resolve, reject) {
        state.paused = false;
        state.ended = false;
        handler.postMessage({ action: 'play' });
        self._pendingResolve = resolve;
        self._pendingReject = reject;
        // 兜底: 1.5s 内未收到 playing 事件则视为成功(resolve),
        // 避免 play() Promise 永远 pending 卡住 UI
        setTimeout(function () {
          if (self._pendingResolve) {
            var r = self._pendingResolve;
            self._pendingResolve = null;
            self._pendingReject = null;
            r();
          }
        }, 1500);
      });
    },

    pause: function () {
      this._pendingResolve = null;
      this._pendingReject = null;
      state.paused = true;
      handler.postMessage({ action: 'pause' });
    },

    load: function () {
      // 把相对 URL 解析成绝对 URL 给原生
      var full;
      try { full = new URL(state.src, location.origin).href; }
      catch (e) { full = state.src; }
      handler.postMessage({ action: 'load', url: full });
    },

    // ── EventTarget 子集 ──
    addEventListener: function (type, fn) {
      (this._listeners[type] = this._listeners[type] || []).push(fn);
    },
    removeEventListener: function (type, fn) {
      var arr = this._listeners[type];
      if (!arr) return;
      var i = arr.indexOf(fn);
      if (i >= 0) arr.splice(i, 1);
    },
    _dispatch: function (type) {
      // 更新 readyState
      if (type === 'loadedmetadata' || type === 'canplay') {
        state.readyState = 4; // HAVE_ENOUGH_DATA
      }
      var evt = { type: type, target: this, currentTarget: this };
      var arr = this._listeners[type];
      if (arr) {
        for (var i = 0; i < arr.length; i++) {
          try { arr[i](evt); } catch (e) { console.warn('[NativeAudio] listener error', e); }
        }
      }
      var onType = 'on' + type;
      if (typeof this[onType] === 'function') {
        try { this[onType](evt); } catch (e) { console.warn('[NativeAudio] on-handler error', e); }
      }
    }
  };

  // 单例
  var adapter = new NativeAudioAdapter();
  window.__nativeAudioAdapter = adapter;

  // 覆写 window.Audio: 让现有代码 `new Audio()` 返回适配器单例
  window.Audio = function () { return adapter; };
  // 同时提供工厂函数 (供 initAudio 等显式调用)
  window.createNativeAudioAdapter = function () { return adapter; };

  // ════════════════════════════════════════════════════════════
  //  原生 → JS 回调
  // ════════════════════════════════════════════════════════════

  // 播放事件 (play/pause/ended/loadedmetadata/canplay/seeked/error/...)
  window.__nativeAudioEvent = function (payload) {
    if (!payload) return;
    if (payload.currentTime != null) state.currentTime = payload.currentTime;
    if (payload.duration != null) state.duration = payload.duration;
    if (payload.paused != null) state.paused = payload.paused;
    if (payload.ended != null) state.ended = payload.ended;

    var type = payload.type;
    if (!type) return;

    // play/playing → resolve play() Promise
    if ((type === 'play' || type === 'playing') && adapter._pendingResolve) {
      var r = adapter._pendingResolve;
      adapter._pendingResolve = null;
      adapter._pendingReject = null;
      r();
    }
    if (type === 'error' && adapter._pendingReject) {
      var rj = adapter._pendingReject;
      adapter._pendingResolve = null;
      adapter._pendingReject = null;
      rj(new Error(payload.error || 'native playback error'));
    }

    adapter._dispatch(type);
  };

  // 频谱 + 时间高频推送 (DisplayLink 30fps)
  window.__nativeAudioTick = function (payload) {
    if (!payload) return;
    if (payload.currentTime != null) state.currentTime = payload.currentTime;
    if (payload.duration != null) state.duration = payload.duration;
    if (payload.paused != null) state.paused = payload.paused;

    if (payload.freq) {
      freqData = decodeB64ToUint8(payload.freq);
      window.__nativeFreqData = freqData;
    }
    if (payload.timeDomain) {
      timeData = decodeB64ToUint8(payload.timeDomain);
      window.__nativeTimeDomainData = timeData;
    }
    // 触发 timeupdate, 让进度条/歌词跟随
    adapter._dispatch('timeupdate');
  };

  // ════════════════════════════════════════════════════════════
  //  Analyser shim: 让原 analyser.getByteFrequencyData 读原生数据
  //  (由 index.html 的 initAudio() 在原生模式下调用)
  // ════════════════════════════════════════════════════════════
  window.installNativeAnalyserShim = function (analyser, beatAnalyser) {
    analyser.getByteFrequencyData = function (arr) {
      var src = window.__nativeFreqData;
      if (src) {
        var n = Math.min(arr.length, src.length);
        for (var i = 0; i < n; i++) arr[i] = src[i];
        for (var j = n; j < arr.length; j++) arr[j] = 0;
      } else {
        for (var i = 0; i < arr.length; i++) arr[i] = 0;
      }
    };
    analyser.getByteTimeDomainData = function (arr) {
      var src = window.__nativeTimeDomainData;
      if (src) {
        var n = Math.min(arr.length, src.length);
        for (var i = 0; i < n; i++) arr[i] = src[i];
        for (var j = n; j < arr.length; j++) arr[j] = 128;
      } else {
        for (var i = 0; i < arr.length; i++) arr[i] = 128;
      }
    };
    if (beatAnalyser) {
      beatAnalyser.getByteFrequencyData = analyser.getByteFrequencyData;
      beatAnalyser.getByteTimeDomainData = analyser.getByteTimeDomainData;
    }
  };

})();
