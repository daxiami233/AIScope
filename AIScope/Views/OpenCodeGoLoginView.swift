import SwiftUI
import AppKit
import WebKit

// MARK: - OpenCode Go 官网登录

struct OpenCodeGoLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "完成 OpenCode 登录后会自动验证并保存会话"

    let onCookie: (String) -> Void
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenCode Go 登录")
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

            OpenCodeGoWebView(
                onCookie: onCookie,
                onStatus: { status = $0 }
            )
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
    }
}

@MainActor
final class OpenCodeGoLoginWindowController: NSObject, NSWindowDelegate {
    static let shared = OpenCodeGoLoginWindowController()

    private var window: NSWindow?
    private var onCookie: ((String) -> Void)?

    func show(onCookie: @escaping (String) -> Void) {
        self.onCookie = onCookie
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenCode Go 登录"
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: OpenCodeGoLoginView(
                onCookie: { [weak self] cookie in
                    self?.onCookie?(cookie)
                    self?.close()
                },
                onClose: { [weak self] in self?.close() }
            )
        )
        self.window = window
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

private struct OpenCodeGoWebView: NSViewRepresentable {
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

        // /auth 会重定向到 OpenCode 官方授权页；完成后回到 /auth/callback。
        webView.load(URLRequest(url: URL(string: "https://opencode.ai/auth")!))
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
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func captureAndValidateCookie(from webView: WKWebView) {
            guard !didSave, !isChecking else { return }
            isChecking = true
            onStatus("正在验证 OpenCode 官网登录状态...")

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let header = Self.cookieHeader(from: cookies)
                guard !header.isEmpty else {
                    DispatchQueue.main.async {
                        self.isChecking = false
                        self.onStatus("等待完成 OpenCode 登录...")
                    }
                    return
                }

                Task {
                    let isValid = await OpenCodeGoProvider.validateOfficialSession(cookie: header)
                    await MainActor.run {
                        self.isChecking = false
                        guard !self.didSave else { return }
                        if isValid {
                            self.didSave = true
                            self.stopPolling()
                            self.onStatus("已验证官网实时额度")
                            self.onCookie(header)
                        } else {
                            self.onStatus("等待完成 OpenCode 登录...")
                        }
                    }
                }
            }
        }

        private static func cookieHeader(from cookies: [HTTPCookie]) -> String {
            cookies
                .filter { cookie in
                    let domain = cookie.domain.lowercased()
                    return (domain == "opencode.ai" || domain == ".opencode.ai") &&
                        (cookie.expiresDate == nil || cookie.expiresDate! > Date())
                }
                .sorted { $0.name < $1.name }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
        }
    }
}
