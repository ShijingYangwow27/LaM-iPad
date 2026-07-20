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
    playbackRate: 1,
    _seeking: false,  // seek 期间屏蔽外推和 tick, seeked 到达后解除
    seekTarget: null  // 仅用于进度条显示的目标位置 (歌词仍跟随真实播放位置)
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
      state._seeking = false;
      state.seekTarget = null;
      window.__nativeSeekTarget = null;
      if (state._seekTimeout) { clearTimeout(state._seekTimeout); state._seekTimeout = null; }
      this._dispatch('emptied');
    },

    get currentTime() { return state.currentTime; },
    set currentTime(t) {
      // 关键修复: 不要乐观地把 state.currentTime 设成目标值。
      // 否则歌词/进度条会立刻跳到目标, 而原生 AVPlayer.seek 是异步的,
      // 真实人声还在旧位置 → "人声比歌词进度慢"。
      // 这里只记录目标(供进度条显示)并置 _seeking 屏蔽 tick 推送,
      // state.currentTime 保持真实播放位置, 等原生 seeked 回传真实位置后再前进。
      // 冻结 state.currentTime 在真实旧位置: 原生 AVPlayer.seek 是异步的,
      // 真实人声要到 seeked 事件后才在新位置出声。若这里乐观写目标, 歌词会领先人声。
      // tick 推送在 seek 期间已被屏蔽(state._seeking), 直到 seeked 才放行。
      state._seeking = true;
      state.seekTarget = t;
      window.__nativeSeekTarget = t;
      // 安全兜底: 若原生 seeked 因异常未回传, 4s 后强制解除冻结并跳到目标,
      // 避免歌词永久卡在旧位置。
      if (state._seekTimeout) clearTimeout(state._seekTimeout);
      state._seekTimeout = setTimeout(function () {
        state._seeking = false;
        state.seekTarget = null;
        window.__nativeSeekTarget = null;
        state._seekTimeout = null;
        state.currentTime = t;
        adapter._dispatch('timeupdate');
      }, 4000);
      handler.postMessage({ action: 'seek', time: t });
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
    // seeked 事件: 解除 _seeking 屏蔽, 清掉目标标记
    if (payload.type === 'seeked') {
      if (state._seekTimeout) { clearTimeout(state._seekTimeout); state._seekTimeout = null; }
      state._seeking = false;
      state.seekTarget = null;
      window.__nativeSeekTarget = null;
    }
    if (payload.currentTime != null) {
      state.currentTime = payload.currentTime;
    }
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
    // 时间高频推送(原生 isPlaying 时触发, 30fps)。
    // 正常播放: state.currentTime 严格 = 原生真实位置, 歌词跟随人声, 绝不领先。
    // seek 期间(state._seeking = true): 冻结 state.currentTime —— 不覆盖,
    //   让歌词停在真实旧位置。原生 AVPlayer.seek 是异步的, 真实人声要到 seeked
    //   事件回传后才在新位置出声; 若这里把 tick 推来的新位置写进 state.currentTime,
    //   歌词会领先人声。因此 seek 期间忽略 tick, 等 __nativeAudioEvent('seeked')
    //   (或 4s 安全兜底) 解除 _seeking 后再继续跟随。这与浏览器 <audio>.currentTime
    //   行为一致: seek 期间 currentTime 不变, seeked 后才跳到目标。
    if (payload.currentTime != null && !state._seeking) {
      state.currentTime = payload.currentTime;
    }
    if (payload.duration != null) state.duration = payload.duration;
    if (payload.paused != null) state.paused = payload.paused;

    if (payload.freq) {
      freqData = decodeB64ToUint8(payload.freq);
      window.__nativeFreqData = freqData;
    }
    if (payload.rms != null) {
      window.__nativeRms = payload.rms;
    }
    // 触发 timeupdate, 让进度条/歌词跟随
    adapter._dispatch('timeupdate');
  };

  // ════════════════════════════════════════════════════════════
  //  元信息 → 原生 (锁屏 Now Playing)
  //  由 index.html 的 updateControlTrackInfo() 调用
  // ════════════════════════════════════════════════════════════
  window.__nativeSetMeta = function (title, artist, coverUrl) {
    try {
      handler.postMessage({
        action: 'meta',
        title: title || '',
        artist: artist || '',
        coverUrl: coverUrl || ''
      });
    } catch (e) {
      console.warn('[NativeAudio] __nativeSetMeta error', e);
    }
  };

  // ════════════════════════════════════════════════════════════
  //  时间模型: 直接采用原生推送的 currentTime, 不做 rAF 外推。
  //  原因: 原生 displayLinkTick 30fps 推送 player.currentTime() 真实可听位置。
  //  任何 rAF 外推(state.currentTime = lastNative + elapsed)都会因 evaluateJavaScript
  //  5-100ms 可变延迟而在推送迟到时超前真实音频, 待推送到达再被拉回 → 歌词振荡/领先人声。
  //  直接采用推送值: 它是真实位置的稳定快照, 与浏览器 <audio>.currentTime 单时钟一致。
  //  原生仅在 isPlaying 时推送 tick, seek/缓冲期间不会提前把 state.currentTime 推到目标。
  // ════════════════════════════════════════════════════════════

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
