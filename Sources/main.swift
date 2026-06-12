// QuotaStrip — show Claude Code / Codex usage quota on the MacBook Pro Touch Bar.
// Lives in the Touch Bar via the DFR private API (same mechanism as MTMR / Pock);
// data comes from quota.py (bundled in Resources). System Control Strip is kept on the right.
import AppKit
import ServiceManagement

// MARK: - DFR private API

@_silgen_name("DFRElementSetControlStripPresenceForIdentifier")
func DFRElementSetControlStripPresenceForIdentifier(_ identifier: NSString, _ visible: Bool)

@_silgen_name("DFRSystemModalShowsCloseBoxWhenFrontMost")
func DFRSystemModalShowsCloseBoxWhenFrontMost(_ show: Bool)

let trayIdentifier = NSTouchBarItem.Identifier("app.quotastrip.QuotaStrip.tray")

func presentSystemModal(_ bar: NSTouchBar, trayId: NSTouchBarItem.Identifier) {
    // placement=0 keeps the system Control Strip; placement=1 takes over the full width.
    let placementSel = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    if let method = class_getClassMethod(NSTouchBar.self, placementSel) {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, Int64, AnyObject?) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        // With the Control Strip kept, the system forces a close box (X) at the far left:
        // tap X to dismiss the panel, tap the gauge icon in the Control Strip to bring it back.
        fn(NSTouchBar.self, placementSel, bar, 0, trayId.rawValue as AnyObject)
        return
    }
    let cls: AnyObject = NSTouchBar.self as AnyObject
    let newSel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    let oldSel = NSSelectorFromString("presentSystemModalFunctionBar:systemTrayItemIdentifier:")
    if cls.responds(to: newSel) {
        _ = cls.perform(newSel, with: bar, with: trayId.rawValue)
    } else if cls.responds(to: oldSel) {
        _ = cls.perform(oldSel, with: bar, with: trayId.rawValue)
    }
}

func addSystemTrayItem(_ item: NSTouchBarItem) {
    let cls: AnyObject = NSTouchBarItem.self as AnyObject
    let sel = NSSelectorFromString("addSystemTrayItem:")
    if cls.responds(to: sel) {
        _ = cls.perform(sel, with: item)
    }
}

// MARK: - Shared paths

enum Paths {
    static let cacheDir = NSHomeDirectory() + "/.cache/quotastrip/"
    static let fetchLog = cacheDir + "fetch.log"
}

// MARK: - Tiny localization (follows the system language)

let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

func L(_ en: String, _ zh: String) -> String { isChinese ? zh : en }

// MARK: - Data model (matches quota.py json output)

struct QuotaWindow: Decodable {
    var pct: Double?   // nil = unknown (window reset but the live value can't be fetched yet)
    var reset: Double?
}

struct QuotaService: Decodable {
    var ok: Bool
    var stale: Bool?
    var five: QuotaWindow?
    var week: QuotaWindow?
    var attention: Bool?
}

struct QuotaPayload: Decodable {
    let claude: QuotaService
    let codex: QuotaService
}

final class QuotaFetcher {
    // quota.py is bundled inside the app, so QuotaStrip.app runs from anywhere.
    private let scriptPath = Bundle.main.path(forResource: "quota", ofType: "py")

    func fetch(force: Bool = false, _ completion: @escaping (QuotaPayload?) -> Void) {
        guard let scriptPath else { completion(nil); return }
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.launchPath = "/usr/bin/python3"
            task.arguments = [scriptPath, "json"] + (force ? ["--force"] : [])
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let payload = try? JSONDecoder().decode(QuotaPayload.self, from: data)
            DispatchQueue.main.async { completion(payload) }
        }
    }
}

// MARK: - Quota panel view (logo + two rows: 5h / 7d bar + percent + reset time)

final class QuotaView: NSView {
    let icon: NSImage?
    let bundleID: String      // desktop app to launch on tap, e.g. "com.anthropic.claudefordesktop"
    let appName: String       // fallback app path component, e.g. "Claude.app"
    let flagName: String       // attention flag file name
    let fallbackURL: String
    var service: QuotaService? { didSet { needsDisplay = true } }
    var onTap: (() -> Void)?

    static let viewWidth: CGFloat = 300

    // Horizontal layout columns
    private let xLabel: CGFloat = 36
    private let xBar: CGFloat = 58
    private let wBar: CGFloat = 120
    private let hBar: CGFloat = 9
    private let xPctRight: CGFloat = 226
    private let xReset: CGFloat = 232

    init(iconFile: String, bundleID: String, appName: String, flagName: String, fallbackURL: String) {
        self.icon = Bundle.main.path(forResource: iconFile, ofType: "png").flatMap { NSImage(contentsOfFile: $0) }
        self.bundleID = bundleID
        self.appName = appName
        self.flagName = flagName
        self.fallbackURL = fallbackURL
        super.init(frame: NSRect(x: 0, y: 0, width: QuotaView.viewWidth, height: 30))
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        click.allowedTouchTypes = [.direct]
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: QuotaView.viewWidth, height: 30) }

    // Tap: clear the attention flag, then bring the matching desktop app to the front.
    // Note: NSRunningApplication.activate() is refused for background apps on macOS 14+,
    // so we use NSWorkspace.openApplication (= `open -a`), which also fronts a running app.
    @objc private func tapped() {
        try? FileManager.default.createDirectory(atPath: Paths.cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: Paths.cacheDir + flagName)
        // Drop an "acknowledged" marker so the log heuristic won't re-alert for this same wait.
        let ackName = flagName.replacingOccurrences(of: "_attention", with: "_ack")
        FileManager.default.createFile(atPath: Paths.cacheDir + ackName, contents: nil)
        service?.attention = false
        onTap?()  // update the menu-bar badge immediately, don't wait for the next refresh

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        } else {
            let appURL = URL(fileURLWithPath: "/Applications/" + appName)
            if FileManager.default.fileExists(atPath: appURL.path) {
                NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { [fallbackURL] _, error in
                    if error != nil, let u = URL(string: fallbackURL) {
                        DispatchQueue.main.async { NSWorkspace.shared.open(u) }
                    }
                }
            } else if let u = URL(string: fallbackURL) {
                NSWorkspace.shared.open(u)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor(white: 0.15, alpha: 1).setFill()
        bg.fill()

        icon?.draw(in: NSRect(x: 4, y: 2, width: 26, height: 26), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        guard let s = service else {
            drawText("…", at: NSPoint(x: xLabel, y: 7), color: .gray, size: 13)
            return
        }
        guard s.ok, let five = s.five, let week = s.week else {
            drawText(L("no data", "暂无数据"), at: NSPoint(x: xLabel, y: 7), color: .gray, size: 13)
            return
        }

        drawRow(top: true, label: "5h", window: five, resetStyle: .clock)
        drawRow(top: false, label: "7d", window: week, resetStyle: .remaining)

        if s.attention == true {
            // Waiting-for-you reminder: red badge with white "!" on the logo's top-right.
            let badge = NSRect(x: 21, y: 0, width: 13, height: 13)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: NSColor.white,
            ]
            let mark = "!" as NSString
            let size = mark.size(withAttributes: attrs)
            mark.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
                      withAttributes: attrs)
        }

        if s.stale == true {
            // Stale data (usage API rate-limited / failed for >15 min): yellow dot, top-right.
            let dot = NSBezierPath(ovalIn: NSRect(x: bounds.width - 9, y: 3, width: 5, height: 5))
            NSColor.systemYellow.setFill()
            dot.fill()
        }
    }

    private enum ResetStyle { case clock, remaining }

    private func drawRow(top: Bool, label: String, window: QuotaWindow, resetStyle: ResetStyle) {
        let yText: CGFloat = top ? 0.5 : 15.5
        let yBar: CGFloat = top ? 3 : 18

        drawText(label, at: NSPoint(x: xLabel, y: yText + 1.5), color: NSColor(white: 0.78, alpha: 1), size: 11.5)

        // Empty bar track
        let barRect = NSRect(x: xBar, y: yBar, width: wBar, height: hBar)
        NSColor(white: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: hBar / 2, yRadius: hBar / 2).fill()

        // Unknown value (window reset but live data unavailable): show "—", no fill, no reset time.
        guard let raw = window.pct else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor(white: 0.6, alpha: 1),
            ]
            let s = "—" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: xPctRight - sz.width, y: yText), withAttributes: attrs)
            return
        }

        let pct = min(max(raw, 0), 100)
        if pct > 0 {
            let w = max(barRect.width * CGFloat(pct) / 100, hBar)
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: w, height: hBar)
            barColor(pct).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: hBar / 2, yRadius: hBar / 2).fill()
        }

        // Percentage: right-aligned, bold; white normally, colored when high.
        let pctStr = String(format: "%.0f%%", pct)
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: pctColor(pct),
        ]
        let pctSize = (pctStr as NSString).size(withAttributes: pctAttrs)
        (pctStr as NSString).draw(at: NSPoint(x: xPctRight - pctSize.width, y: yText), withAttributes: pctAttrs)

        // Reset time: 5h row shows a clock time (24h), 7d row shows the remaining duration.
        // The 5h clock turns yellow within the last 30 min — a nudge to use up the window.
        let resetStr = resetStyle == .clock ? clockText(window.reset) : remainingText(window.reset)
        var resetColor = NSColor(white: 0.88, alpha: 1)
        if resetStyle == .clock, let r = window.reset {
            let remain = r - Date().timeIntervalSince1970
            if remain > 0 && remain < 1800 { resetColor = .systemYellow }
        }
        drawText(resetStr, at: NSPoint(x: xReset, y: yText + 1.5), color: resetColor, size: 11.5)
    }

    private func barColor(_ pct: Double) -> NSColor {
        if pct >= 80 { return .systemRed }
        if pct >= 50 { return .systemYellow }
        return .systemGreen
    }

    private func pctColor(_ pct: Double) -> NSColor {
        if pct >= 80 { return .systemRed }
        if pct >= 50 { return .systemYellow }
        return .white
    }

    private func clockText(_ reset: Double?) -> String {
        guard let r = reset else { return "" }
        let date = Date(timeIntervalSince1970: r)
        guard date > Date() else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")  // force 24h, no am/pm
        fmt.dateFormat = "HH:mm"
        return "↻" + fmt.string(from: date)
    }

    private func remainingText(_ reset: Double?) -> String {
        guard let r = reset else { return "" }
        let secs = Int(r - Date().timeIntervalSince1970)
        guard secs > 0 else { return "" }
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "↻\(d)d\(h)h" }
        if h > 0 { return "↻\(h)h\(m)m" }
        return "↻\(m)m"
    }

    private func drawText(_ s: String, at p: NSPoint, color: NSColor, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }
}

// MARK: - App

extension NSTouchBarItem.Identifier {
    static let esc = NSTouchBarItem.Identifier("qs.esc")
    static let claudeQuota = NSTouchBarItem.Identifier("qs.claude")
    static let codexQuota = NSTouchBarItem.Identifier("qs.codex")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let fetcher = QuotaFetcher()
    private let claudeView = QuotaView(iconFile: "claude-logo", bundleID: "com.anthropic.claudefordesktop",
                                       appName: "Claude.app", flagName: "claude_attention",
                                       fallbackURL: "https://claude.ai/settings/usage")
    private let codexView = QuotaView(iconFile: "codex-logo", bundleID: "com.openai.codex",
                                      appName: "Codex.app", flagName: "codex_attention",
                                      fallbackURL: "https://chatgpt.com/codex/settings/usage")
    private var bar: NSTouchBar!
    private var quotaTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy (e.g. login item + manual launch) would fight
        // over the Touch Bar, so just quit quietly.
        let mine = Bundle.main.bundleIdentifier ?? ""
        let twins = NSRunningApplication.runningApplications(withBundleIdentifier: mine)
        if twins.count > 1 {
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()
        claudeView.onTap = { [weak self] in self?.syncStatusAttention() }
        codexView.onTap = { [weak self] in self?.syncStatusAttention() }

        // The esc key needs Accessibility permission. Check SILENTLY here (no prompt) so the
        // app never nags on launch — granting is opt-in via the "Enable esc key…" menu item.

        bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.esc, .claudeQuota, .codexQuota]

        present()

        refresh()
        quotaTimer = Timer.scheduledTimer(timeInterval: 20, target: self,
                                          selector: #selector(refresh), userInfo: nil, repeats: true)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(present),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: Menu bar

    private var loginItem: NSMenuItem!
    private var escPermItem: NSMenuItem!

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = AppDelegate.gaugeIcon()
        let menu = NSMenu()
        menu.delegate = self   // refresh dynamic item states each time the menu opens
        menu.addItem(NSMenuItem(title: L("Refresh now", "立即刷新"), action: #selector(refreshForced), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: L("Re-show Touch Bar", "重新显示 Touch Bar"), action: #selector(present), keyEquivalent: "t"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Open Claude usage page", "打开 Claude 用量页"), action: #selector(openClaude), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("Open Codex usage page", "打开 Codex 用量页"), action: #selector(openCodex), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("View connection log", "查看连接日志"), action: #selector(openLog), keyEquivalent: "l"))
        menu.addItem(.separator())
        escPermItem = NSMenuItem(title: L("Enable esc key (grant Accessibility)…", "启用 esc 键（授权辅助功能）…"),
                                 action: #selector(grantAccessibility), keyEquivalent: "")
        menu.addItem(escPermItem)
        loginItem = NSMenuItem(title: L("Start at login", "开机自启"), action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit QuotaStrip", "退出 QuotaStrip"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = loginEnabled ? .on : .off
        // Hide the esc-permission item once Accessibility is granted (silent check, no prompt).
        escPermItem.isHidden = AXIsProcessTrusted()
    }

    /// Opt-in: only here do we show the system Accessibility prompt, when the user asks for it.
    @objc private func grantAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            // Also open the pane directly in case the prompt was dismissed previously.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Icon: two bars of different length (a usage gauge); template image adapts to light/dark.
    static func gaugeIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            let rows: [(y: CGFloat, fill: CGFloat)] = [(9.5, 14), (3.5, 8)]
            for row in rows {
                NSColor.black.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: NSRect(x: 1, y: row.y, width: 18, height: 4.5),
                             xRadius: 2.25, yRadius: 2.25).fill()
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: 1, y: row.y, width: row.fill, height: 4.5),
                             xRadius: 2.25, yRadius: 2.25).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func updateStatusAttention(_ attention: Bool) {
        guard let button = statusItem.button else { return }
        if attention {
            button.attributedTitle = NSAttributedString(
                string: " !",
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.boldSystemFont(ofSize: 14)])
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
        }
    }

    // MARK: Login item (SMAppService, macOS 13+)

    private var loginEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else {
            let a = NSAlert()
            a.messageText = L("Start at login needs macOS 13 or later.", "开机自启需要 macOS 13 或更高版本。")
            a.runModal()
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            let a = NSAlert()
            a.messageText = L("Could not change the login item: ", "无法更改登录项：") + error.localizedDescription
            a.runModal()
        }
    }

    // MARK: Touch Bar presentation

    @objc func present() {
        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        let tray = NSCustomTouchBarItem(identifier: trayIdentifier)
        tray.view = NSButton(image: AppDelegate.gaugeIcon(), target: self, action: #selector(present))
        addSystemTrayItem(tray)
        DFRElementSetControlStripPresenceForIdentifier(trayIdentifier.rawValue as NSString, true)
        presentSystemModal(bar, trayId: trayIdentifier)
        // Re-disable the left close box after presenting (setting it beforehand gets reset).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        }
    }

    // MARK: Data refresh

    /// Menu "Refresh now": force a real request, bypassing the cache and the 429 cooldown.
    @objc func refreshForced() {
        doRefresh(force: true)
    }

    @objc func refresh() {
        doRefresh(force: false)
    }

    private func doRefresh(force: Bool) {
        fetcher.fetch(force: force) { [weak self] payload in
            guard let self, let payload else { return }
            self.claudeView.service = payload.claude
            self.codexView.service = payload.codex
            self.syncStatusAttention()
        }
    }

    private func syncStatusAttention() {
        let attention = (claudeView.service?.attention == true)
            || (codexView.service?.attention == true)
        updateStatusAttention(attention)
    }

    // MARK: Actions

    @objc private func escPressed() {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    @objc private func openClaude() { NSWorkspace.shared.open(URL(string: claudeView.fallbackURL)!) }
    @objc private func openCodex() { NSWorkspace.shared.open(URL(string: codexView.fallbackURL)!) }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Paths.fetchLog) {
            try? FileManager.default.createDirectory(atPath: Paths.cacheDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Paths.fetchLog, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.fetchLog))
    }

    // MARK: NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case .esc:
            let b = NSButton(title: "esc", target: self, action: #selector(escPressed))
            b.widthAnchor.constraint(equalToConstant: 54).isActive = true
            item.view = b
        case .claudeQuota:
            item.view = claudeView
            claudeView.widthAnchor.constraint(equalToConstant: QuotaView.viewWidth).isActive = true
        case .codexQuota:
            item.view = codexView
            codexView.widthAnchor.constraint(equalToConstant: QuotaView.viewWidth).isActive = true
        default:
            return nil
        }
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
