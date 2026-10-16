import AppKit
import SwiftUI
import WebKit

// Extensions' side panels, in the sidebar panel (UtilitySidebar.swift).
//
// Chrome gives an extension a column beside the page for a page of its own —
// sidePanel.open, or its button with openPanelOnActionClick. Here that
// column is the sidebar panel, on the side away from the tabs. With the
// sidebar panel switched off in Settings, a panel opens as a tab, as it
// always did.
//
// The page is loaded in a view built from the extension's own
// configuration, as its popup is (see ExtensionPopup), and WebKit is told of
// it as a tab of the window it is in — no place in the row — so the panel's
// tabs.query({currentWindow: true}) answers that window. One panel at a
// time in a window, as in Chrome: going to another extension's panel, or to
// the chat, closes the one that was there.

@available(macOS 15.4, *)
@MainActor
final class SidePanelPage: NSObject, WKWebExtensionTab, WKUIDelegate, WKNavigationDelegate {
    let extensionID: String
    let url: URL
    let web: WKWebView
    weak var browser: Browser?

    init?(_ url: URL, for context: WKWebExtensionContext, in browser: Browser) {
        guard let configuration = context.webViewConfiguration else { return nil }
        extensionID = context.uniqueIdentifier
        self.url = url
        self.browser = browser
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 600), configuration: configuration)
        super.init()
        web.uiDelegate = self
        web.navigationDelegate = self
        web.isInspectable = true
        web.load(URLRequest(url: url))
    }

    // MARK: - as WebKit sees it

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser.map { Extensions.shared.window(of: $0) }
    }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web.title }
    func url(for context: WKWebExtensionContext) -> URL? { web.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !web.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws {
        if let browser { SidePanels.close(extensionID, in: browser) }
    }

    // MARK: - the page asking

    /// window.close() from the panel puts it away, as in Chrome.
    func webViewDidClose(_ webView: WKWebView) {
        if let browser { SidePanels.close(extensionID, in: browser) }
    }

    /// A link that asks for a new window is a tab of the window, beside the
    /// page; the panel stays.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, (try? Extensions.mayOpen(url)) != nil {
            browser?.open(url, foreground: true)
        }
        return nil
    }

    /// The camera or microphone, asked on the window's card and kept for the
    /// extension, as for its other pages (see Browser.askedForCapture).
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let browser else { return decisionHandler(.deny) }
        browser.askedForCapture(webView, origin: origin, frame: frame, type: type, decisionHandler: decisionHandler)
    }
}

/// Which extensions have a side panel, the panels open in each window, and
/// opening and closing them.
enum SidePanels {
    @available(macOS 15.4, *)
    @MainActor
    static func hasPanel(_ context: WKWebExtensionContext) -> Bool {
        guard enabled[context.uniqueIdentifier] != false else { return false }
        return ExtensionShims.panelPath[context.uniqueIdentifier] != nil || ExtensionShims.defaultPanel(context) != nil
    }

    /// Switched off by the extension (sidePanel.setOptions({enabled: false})).
    @MainActor static var enabled: [String: Bool] = [:]

    /// The panel page open in each window, by the window's browser.
    @available(macOS 15.4, *)
    @MainActor private static var pages: [ObjectIdentifier: SidePanelPage] = [:]

    /// The address the panel is at now: the one the extension set, else its
    /// manifest's.
    @available(macOS 15.4, *)
    @MainActor
    static func url(for context: WKWebExtensionContext) -> URL? {
        guard let path = ExtensionShims.panelPath[context.uniqueIdentifier] ?? ExtensionShims.defaultPanel(context) else { return nil }
        return ExtensionShims.page(path, in: context)
    }

    /// The page for this extension in this window, made if it isn't open —
    /// for the sidebar panel to show. Nil when the extension has no panel.
    @available(macOS 15.4, *)
    @MainActor
    static func page(for id: String, in browser: Browser) -> SidePanelPage? {
        let key = ObjectIdentifier(browser)
        guard let context = Extensions.shared.contexts[id], hasPanel(context), let url = url(for: context) else { return nil }
        if let open = pages[key], open.extensionID == id, open.url == url { return open }
        if let open = pages[key] { forget(open, key: key) }
        guard let made = SidePanelPage(url, for: context, in: browser) else { return nil }
        pages[key] = made
        context.didOpenTab(made)
        return made
    }

    /// sidePanel.open, or the extension's button set to open its panel: in
    /// the window in front's sidebar panel, or — with that switched off — in
    /// a tab, as before.
    @available(macOS 15.4, *)
    @MainActor
    static func open(_ context: WKWebExtensionContext, owner: Extensions) {
        guard let browser = owner.browser, let url = url(for: context) else { return }
        enabled[context.uniqueIdentifier] = nil
        if browser.prefs.utilitySidebar {
            browser.showUtility(.panel(context.uniqueIdentifier))
        } else {
            browser.open(url, foreground: true)
        }
    }

    /// The panel put away in this window: the page goes, and the sidebar
    /// panel with it if it was showing it.
    @available(macOS 15.4, *)
    @MainActor
    static func close(_ id: String, in browser: Browser) {
        let key = ObjectIdentifier(browser)
        if let open = pages[key], open.extensionID == id { forget(open, key: key) }
        if browser.utility == .panel(id) { browser.utility = nil }
    }

    /// The window showing something else now: whatever panel was open there
    /// goes, as in Chrome, where one panel replaces another.
    @available(macOS 15.4, *)
    @MainActor
    static func left(_ id: String, in browser: Browser) {
        let key = ObjectIdentifier(browser)
        if let open = pages[key], open.extensionID == id { forget(open, key: key) }
    }

    /// Every window's panel of this extension: it was switched off, taken up
    /// afresh or removed, or turned its panel off.
    @available(macOS 15.4, *)
    @MainActor
    static func closeAll(of id: String) {
        for browser in Browsers.all { close(id, in: browser) }
    }

    /// sidePanel.setOptions changed where the panel is: an open one follows.
    @available(macOS 15.4, *)
    @MainActor
    static func moved(_ id: String) {
        for browser in Browsers.all where browser.utility == .panel(id) {
            _ = page(for: id, in: browser)
            browser.objectWillChange.send()
        }
    }

    @available(macOS 15.4, *)
    @MainActor
    private static func forget(_ page: SidePanelPage, key: ObjectIdentifier) {
        pages[key] = nil
        page.web.removeFromSuperview()
        if let context = Extensions.shared.contexts[page.extensionID] {
            context.didCloseTab(page, windowIsClosing: false)
        }
    }

    /// For the bench: what each window's panel shows.
    @available(macOS 15.4, *)
    @MainActor
    static var open: [(id: String, url: String)] {
        pages.values.map { ($0.extensionID, $0.web.url?.absoluteString ?? $0.url.absoluteString) }
    }
}

/// The panel's page, in the sidebar panel. The view is the page's own,
/// lent to this one while it is shown and given up when it isn't.
@available(macOS 15.4, *)
struct SidePanelView: NSViewRepresentable {
    let page: SidePanelPage

    func makeNSView(context: Context) -> NSView {
        let holder = NSView()
        hold(page.web, in: holder)
        return holder
    }

    func updateNSView(_ holder: NSView, context: Context) {
        if page.web.superview !== holder {
            holder.subviews.forEach { $0.removeFromSuperview() }
            hold(page.web, in: holder)
        }
    }

    private func hold(_ web: WKWebView, in holder: NSView) {
        web.removeFromSuperview()
        web.frame = holder.bounds
        web.autoresizingMask = [.width, .height]
        holder.addSubview(web)
    }
}
