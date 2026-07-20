import SwiftUI
import WebKit

/// 读取 Info.plist 中的 WEB_BASE_URL（由 project.yml 的 INFOPLIST_KEY_WEB_BASE_URL 注入，可在构建时配置）。
/// 未配置时回退到 Mac 本机 dev server，便于模拟器/本地调试。
func appWebBaseURL() -> String {
    if let v = Bundle.main.object(forInfoDictionaryKey: "WEB_BASE_URL") as? String,
       !v.trimmingCharacters(in: .whitespaces).isEmpty {
        return v
    }
    return "http://127.0.0.1:3001"
}

func swiftLog(_ step: String, _ extra: [String: Any] = [:]) {
    var payload: [String: Any] = ["step": "swift_" + step]
    for (k, v) in extra { payload[k] = v }
    guard let url = URL(string: appWebBaseURL() + "/api/qq/qr/log"),
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
        cfg.userContentController.add(context.coordinator, name: "nativeAudio")

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
        context.coordinator.audioEngine.webView = webView
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
        let audioEngine = NativeAudioEngine()

        init(onQQLoginRequest: @escaping (String) -> Void) {
            self.onQQLoginRequest = onQQLoginRequest
            super.init()
        }

        func bind(to webView: WKWebView) { webView.navigationDelegate = self }

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
                    // PiP 已移除，后台播放由 NativeAudioEngine 的 AVAudioSession .playback 接管
                    webView?.evaluateJavaScript("if(typeof showToast==='function')showToast('后台播放已由系统接管，无需画中画')")
                case "exit":
                    break
                case "update":
                    // 元信息转发给 NativeAudioEngine (锁屏 Now Playing)
                    let title = body["title"] as? String ?? ""
                    let artist = body["artist"] as? String ?? ""
                    let coverUrl = body["coverUrl"] as? String

                    if let urlStr = coverUrl, let url = URL(string: urlStr) {
                        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
                            guard let self = self, error == nil else { return }
                            DispatchQueue.main.async {
                                self.audioEngine.updateMeta(title: title, artist: artist, coverData: data)
                            }
                        }.resume()
                    } else {
                        audioEngine.updateMeta(title: title, artist: artist, coverData: nil)
                    }
                case "bgAudioStart":
                    break  // 已由 NativeAudioEngine 接管
                case "bgAudioStop":
                    break
                case "bgAudioPause":
                    break
                case "bgAudioResume":
                    break
                default:
                    break
                }
            } else if message.name == "nativeAudio" {
                guard let body = message.body as? [String: Any],
                      let action = body["action"] as? String else { return }
                switch action {
                case "load":
                    if let urlStr = body["url"] as? String, let url = URL(string: urlStr) {
                        audioEngine.load(url: url)
                    }
                case "play":
                    audioEngine.play()
                case "pause":
                    audioEngine.pause()
                case "seek":
                    if let t = body["time"] as? Double { audioEngine.seek(to: t) }
                    else if let t = body["time"] as? NSNumber { audioEngine.seek(to: t.doubleValue) }
                case "setVolume":
                    if let v = body["volume"] as? Double { audioEngine.setVolume(Float(v)) }
                    else if let v = body["volume"] as? NSNumber { audioEngine.setVolume(Float(v.floatValue)) }
                case "stop":
                    audioEngine.stop()
                case "meta":
                    let title = body["title"] as? String ?? ""
                    let artist = body["artist"] as? String ?? ""
                    let coverUrl = body["coverUrl"] as? String
                    if let urlStr = coverUrl, let url = URL(string: urlStr) {
                        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
                            guard let self = self, error == nil else { return }
                            DispatchQueue.main.async {
                                self.audioEngine.updateMeta(title: title, artist: artist, coverData: data)
                            }
                        }.resume()
                    } else {
                        audioEngine.updateMeta(title: title, artist: artist, coverData: nil)
                    }
                default:
                    break
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        "\(appWebBaseURL())/?v=" + String(Int(Date().timeIntervalSince1970))
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
