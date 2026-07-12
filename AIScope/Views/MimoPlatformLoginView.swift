import SwiftUI
import AppKit
import WebKit

// MARK: - MiMo Platform Login

private var integrationLoginWindowFrame: NSRect {
    NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
}

struct MimoPlatformLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "登录后会自动保存 Cookie"

    let onCookie: (String) -> Void
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MiMo 平台登录")
                        .font(.headline)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("关闭") {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
            }
            .padding(14)

            Divider()

            MimoPlatformWebView(
                onCookie: onCookie,
                onStatus: { status = $0 }
            )
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
    }
}

@MainActor
final class MimoPlatformLoginWindowController: NSObject, NSWindowDelegate {
    static let shared = MimoPlatformLoginWindowController()

    private var window: NSWindow?
    private var onCookie: ((String) -> Void)?

    func show(onCookie: @escaping (String) -> Void) {
        self.onCookie = onCookie

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.setFrame(integrationLoginWindowFrame, display: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: integrationLoginWindowFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MiMo 平台登录"
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MimoPlatformLoginView(
                onCookie: { [weak self] cookie in
                    self?.onCookie?(cookie)
                    self?.close()
                },
                onClose: { [weak self] in
                    self?.close()
                }
            )
        )
        self.window = window
        window.setFrame(integrationLoginWindowFrame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onCookie = nil
    }
}

private struct MimoPlatformWebView: NSViewRepresentable {
    let onCookie: (String) -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookie: onCookie, onStatus: onStatus)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.startPolling(webView)

        if let url = URL(string: "https://platform.xiaomimimo.com/token-plan") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onCookie: (String) -> Void
        private let onStatus: (String) -> Void
        private var timer: Timer?
        private var isChecking = false
        private var didSave = false

        init(onCookie: @escaping (String) -> Void, onStatus: @escaping (String) -> Void) {
            self.onCookie = onCookie
            self.onStatus = onStatus
        }

        func startPolling(_ webView: WKWebView) {
            stopPolling()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak webView] _ in
                guard let webView else { return }
                DispatchQueue.main.async {
                    self?.captureAndValidateCookie(from: webView)
                }
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            captureAndValidateCookie(from: webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let requestURL = navigationAction.request.url {
                webView.load(URLRequest(url: requestURL))
            }
            return nil
        }

        private func captureAndValidateCookie(from webView: WKWebView) {
            guard !didSave, !isChecking else { return }

            isChecking = true
            onStatus("检测平台登录状态...")

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let header = Self.cookieHeader(from: cookies)
                guard !header.isEmpty else {
                    DispatchQueue.main.async {
                        self.isChecking = false
                        self.onStatus("等待平台登录...")
                    }
                    return
                }

                Task {
                    let isValid = await Self.validateCookieHeader(header)
                    await MainActor.run {
                        self.isChecking = false
                        guard !self.didSave else { return }
                        if isValid {
                            self.didSave = true
                            self.stopPolling()
                            self.onStatus("Cookie 已验证")
                            self.onCookie(header)
                        } else {
                            self.onStatus("等待平台登录...")
                        }
                    }
                }
            }
        }

        private static func cookieHeader(from cookies: [HTTPCookie]) -> String {
            cookies
                .filter { cookie in
                    cookie.domain.localizedCaseInsensitiveContains("xiaomimimo.com")
                        && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
                }
                .sorted { $0.name < $1.name }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
        }

        private static func validateCookieHeader(_ cookieHeader: String) async -> Bool {
            guard let url = URL(string: "https://platform.xiaomimimo.com/api/v1/tokenPlan/detail") else {
                return false
            }

            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Locale.preferredLanguages.first ?? "zh-CN", forHTTPHeaderField: "Accept-Language")
            request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-timeZone")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return false
                }

                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return false
                }
                if let code = root["code"] as? Int {
                    return code == 0 || code == 200
                }
                return root["data"] != nil
            } catch {
                return false
            }
        }
    }
}
