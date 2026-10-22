import Cocoa
import Foundation
import UserNotifications

// MARK: - Gripper View

class GripperView: NSView {
    var onResize: ((_ deltaH: CGFloat) -> Void)?
    private var dragStartScreenY: CGFloat = 0

    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartScreenY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        let y = NSEvent.mouseLocation.y
        let dy = y - dragStartScreenY
        dragStartScreenY = y
        onResize?(-dy)  // drag down (dy<0) → positive deltaH → panel grows
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.5, alpha: 0.35).setFill()
        let d: CGFloat = 3.5
        let gap: CGFloat = 5
        let n = 5
        let tw = CGFloat(n) * d + CGFloat(n - 1) * gap
        let sx = (bounds.width - tw) / 2
        let sy = (bounds.height - d) / 2
        for i in 0..<n {
            NSBezierPath(ovalIn: NSRect(x: sx + CGFloat(i) * (d + gap), y: sy, width: d, height: d)).fill()
        }
    }
}

// MARK: - Updates Panel

private class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

class UpdatesPanelController: NSObject {
    private var panel: NSPanel?
    private var eventMonitor: Any?

    static let changesPath: String = {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/jira-notifier/changes.json"
    }()

    func loadChanges() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.changesPath)),
              let arr  = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    func pendingCount() -> Int { loadChanges().count }

    func clearChanges() {
        try? "[]".write(toFile: Self.changesPath, atomically: true, encoding: .utf8)
    }

    func show(near statusItem: NSStatusItem, projectKey: String = "Jira") {
        let changes = loadChanges()
        dismiss()
        buildPanel(changes: changes, statusItem: statusItem, projectKey: projectKey)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
        panel?.close(); panel = nil
    }

    var isVisible: Bool { panel != nil }
    var onSettingsTapped: (() -> Void)?

    private static let heightKey     = "JiraNotifierPanelHeight"
    private static let defaultH: CGFloat = 420
    private static let minH: CGFloat     = 200
    private static let maxH: CGFloat     = 700

    private func savedPanelHeight() -> CGFloat {
        let v = CGFloat(UserDefaults.standard.double(forKey: Self.heightKey))
        return v > 0 ? v : Self.defaultH
    }

    private func savePanelHeight(_ h: CGFloat) {
        UserDefaults.standard.set(Double(h), forKey: Self.heightKey)
    }

    private func relativeTimeString(from iso: String) -> String? {
        var date: Date?
        // Standard ISO 8601 with fractional seconds
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = fmt.date(from: iso)
        // Standard ISO 8601 without fractional seconds
        if date == nil {
            fmt.formatOptions = [.withInternetDateTime]
            date = fmt.date(from: iso)
        }
        // "2026-10-21 21:07:04 UTC" — MCP flat format
        if date == nil {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
            df.timeZone = TimeZone(identifier: "UTC")
            date = df.date(from: iso)
        }
        guard let d = date else { return nil }
        let rdf = RelativeDateTimeFormatter()
        rdf.unitsStyle = .full
        return rdf.localizedString(for: d, relativeTo: Date())
    }

    private func buildPanel(changes: [[String: Any]], statusItem: NSStatusItem, projectKey: String = "Jira") {
        let W: CGFloat       = 380
        let rowH: CGFloat    = 72
        let headerH: CGFloat = 46
        let footerH: CGFloat = 44
        let gripperH: CGFloat = 14
        let sepH: CGFloat    = 1

        let chrome = headerH + footerH + gripperH
        let contentH = CGFloat(max(1, changes.count)) * (rowH + sepH)
        let naturalH = chrome + contentH + 16  // 16px bottom padding
        let totalH = changes.isEmpty
            ? max(Self.minH, min(naturalH, Self.maxH))
            : max(naturalH, min(savedPanelHeight(), Self.maxH))

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: W, height: totalH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel      = true
        p.level                = .floating
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate    = false
        p.isReleasedWhenClosed = false
        p.hasShadow            = true
        p.backgroundColor      = .clear

        let isDark = p.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let headerBgColor  = isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.92, alpha: 1)
        let footerBgColor  = isDark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.90, alpha: 1)
        let gripperBgColor = isDark ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 0.86, alpha: 1)

        let root = p.contentView!
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Header
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = headerBgColor.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        let titleStr: String
        if changes.isEmpty {
            titleStr = "\(projectKey) – No pending updates"
        } else {
            let n = changes.count
            let ts    = changes.first?["timestamp"] as? String ?? ""
            let fdate = changes.first?["date"]      as? String ?? ""
            let sinceDisplay = (!ts.isEmpty ? relativeTimeString(from: ts) : nil) ?? fdate
            let sinceClause  = sinceDisplay.isEmpty ? "" : " since \(sinceDisplay)"
            titleStr = "\(projectKey) – \(n) update\(n == 1 ? "" : "s")\(sinceClause)"
        }
        let titleLbl = makeLabel(titleStr, size: 13, weight: .semibold, color: .labelColor)
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLbl)

        let closeBtn = NSButton(title: "", target: self, action: #selector(closeTapped))
        closeBtn.bezelStyle = .circular
        closeBtn.isBordered = false
        closeBtn.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                 accessibilityDescription: "Close")
        closeBtn.contentTintColor = NSColor(white: 0.55, alpha: 1)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(closeBtn)

        // Scroll + stack
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing     = 0
        stack.alignment   = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        if changes.isEmpty {
            let empty = makeLabel("No new activity since last clear.", size: 12,
                                  weight: .regular, color: .secondaryLabelColor)
            empty.translatesAutoresizingMaskIntoConstraints = false
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.heightAnchor.constraint(equalToConstant: rowH).isActive = true
            wrapper.widthAnchor.constraint(equalToConstant: W).isActive = true
            wrapper.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            ])
            stack.addArrangedSubview(wrapper)
        } else {
            for (i, change) in changes.enumerated() {
                stack.addArrangedSubview(buildRow(change, width: W))
                if i < changes.count - 1 {
                    let sep = NSBox()
                    sep.boxType = .separator
                    sep.translatesAutoresizingMaskIntoConstraints = false
                    sep.widthAnchor.constraint(equalToConstant: W).isActive = true
                    sep.heightAnchor.constraint(equalToConstant: sepH).isActive = true
                    stack.addArrangedSubview(sep)
                }
            }
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller   = true
        scrollView.autohidesScrollers    = true
        scrollView.drawsBackground       = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        scrollView.contentView   = clipView
        scrollView.documentView  = stack
        root.addSubview(scrollView)

        // Footer
        let footer = NSView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = footerBgColor.cgColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)

        let clearBtn = NSButton(title: "Clear All", target: self, action: #selector(clearTapped))
        clearBtn.bezelStyle = .rounded
        clearBtn.controlSize = .small
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.isEnabled = !changes.isEmpty
        footer.addSubview(clearBtn)

        let openAllBtn = NSButton(title: "Open All in Browser",
                                  target: self, action: #selector(openAllTapped))
        openAllBtn.bezelStyle = .rounded
        openAllBtn.controlSize = .small
        openAllBtn.translatesAutoresizingMaskIntoConstraints = false
        openAllBtn.isEnabled = !changes.isEmpty
        footer.addSubview(openAllBtn)

        let gearBtn = NSButton(title: "", target: self, action: #selector(gearTapped))
        gearBtn.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        gearBtn.bezelStyle = .rounded
        gearBtn.controlSize = .small
        gearBtn.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(gearBtn)

        // Gripper
        let gripper = GripperView()
        gripper.wantsLayer = true
        gripper.layer?.backgroundColor = gripperBgColor.cgColor
        gripper.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(gripper)

        // Layout
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerH),

            titleLbl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            titleLbl.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            closeBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 22),
            closeBtn.heightAnchor.constraint(equalToConstant: 22),

            gripper.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            gripper.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gripper.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gripper.heightAnchor.constraint(equalToConstant: gripperH),

            footer.bottomAnchor.constraint(equalTo: gripper.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.heightAnchor.constraint(equalToConstant: footerH),

            clearBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            clearBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            openAllBtn.trailingAnchor.constraint(equalTo: clearBtn.leadingAnchor, constant: -8),
            openAllBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            gearBtn.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            gearBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            gearBtn.widthAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            stack.widthAnchor.constraint(equalToConstant: W),
        ])

        // Position below status item button, left-aligned
        if let btn = statusItem.button,
           let win = btn.window {
            let btnScreenFrame = win.convertToScreen(btn.frame)
            let screenMaxX = NSScreen.main?.visibleFrame.maxX ?? W
            let x = max(4, min(btnScreenFrame.minX, screenMaxX - W - 4))
            let y = btnScreenFrame.minY - totalH - 4
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Wire gripper resize
        gripper.onResize = { [weak self, weak p] deltaH in
            guard let self = self, let panel = p else { return }
            let f = panel.frame
            let newH = max(Self.minH, min(Self.maxH, f.height + deltaH))
            panel.setFrame(NSRect(x: f.minX, y: f.maxY - newH, width: f.width, height: newH),
                           display: true, animate: false)
            self.savePanelHeight(newH)
        }

        self.panel = p
        p.makeKeyAndOrderFront(nil)
    }

    private func buildRow(_ change: [String: Any], width: CGFloat) -> NSView {
        let rowH: CGFloat = 78
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: rowH).isActive = true
        row.widthAnchor.constraint(equalToConstant: width).isActive = true

        let key     = change["key"]     as? String ?? ""
        let summary = change["summary"] as? String ?? ""
        let actor   = change["actor"]   as? String ?? ""
        let verb    = change["verb"]    as? String ?? ""
        let date    = change["date"]    as? String ?? ""

        // Build attributed sentence: "[Actor] [verb] KEY – summary"
        // Key portion is accent-coloured + monospace
        let sentence = NSMutableAttributedString()

        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor,
        ]

        if !actor.isEmpty {
            sentence.append(NSAttributedString(string: "\(actor) \(verb) ", attributes: bodyAttrs))
        } else if !verb.isEmpty {
            // Capitalise first letter when no actor
            let capitalized = verb.prefix(1).uppercased() + verb.dropFirst() + " "
            sentence.append(NSAttributedString(string: capitalized, attributes: bodyAttrs))
        }
        sentence.append(NSAttributedString(string: key, attributes: keyAttrs))
        if !summary.isEmpty {
            sentence.append(NSAttributedString(string: " – \(summary)", attributes: bodyAttrs))
        }

        let mainLbl = NSTextField(labelWithString: "")
        mainLbl.attributedStringValue = sentence
        mainLbl.lineBreakMode = .byTruncatingTail
        mainLbl.maximumNumberOfLines = 2
        mainLbl.isSelectable = false
        mainLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(mainLbl)

        let dateLbl = makeLabel(date, size: 11, weight: .regular, color: .tertiaryLabelColor)
        dateLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(dateLbl)

        NSLayoutConstraint.activate([
            mainLbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            mainLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            mainLbl.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),

            dateLbl.topAnchor.constraint(equalTo: mainLbl.bottomAnchor, constant: 4),
            dateLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
        ])

        // Whole row opens the issue on click
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
        row.addGestureRecognizer(click)
        row.identifier = NSUserInterfaceItemIdentifier(key)

        return row
    }

    private func makeLabel(_ s: String, size: CGFloat, weight: NSFont.Weight,
                            color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font      = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.isSelectable = false
        return f
    }

    @objc private func rowClicked(_ gesture: NSClickGestureRecognizer) {
        guard let key = gesture.view?.identifier?.rawValue,
              let url = URL(string: "https://jira.tools.sap/browse/\(key)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func keyTapped(_ sender: NSButton) {
        let key = sender.identifier?.rawValue ?? sender.title
        if let url = URL(string: "https://jira.tools.sap/browse/\(key)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAllTapped() {
        for change in loadChanges() {
            if let key = change["key"] as? String,
               let url = URL(string: "https://jira.tools.sap/browse/\(key)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func clearTapped() {
        clearChanges()
        dismiss()
        NotificationCenter.default.post(name: .jiraChangesCleared, object: nil)
    }

    @objc private func gearTapped() { onSettingsTapped?() }

    @objc private func closeTapped() { dismiss() }
}

extension Notification.Name {
    static let jiraChangesCleared = Notification.Name("JiraChangesClearedNotification")
}

// MARK: - Preferences Panel

class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var projectKeyField: NSTextField!
    private var intervalField: NSTextField!
    var onSave: ((String, Double) -> Void)?

    func show(currentProject: String, currentInterval: Double) {
        if window == nil { buildWindow() }
        projectKeyField.stringValue = currentProject
        intervalField.stringValue = String(Int(currentInterval))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "Jira Notifier — Preferences"
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w

        let v = w.contentView!

        func label(_ s: String, y: CGFloat) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.frame = NSRect(x: 20, y: y, width: 155, height: 20)
            f.alignment = .right
            return f
        }
        func field(placeholder: String, y: CGFloat) -> NSTextField {
            let f = NSTextField()
            f.frame = NSRect(x: 185, y: y - 2, width: 155, height: 24)
            f.placeholderString = placeholder
            return f
        }

        let projectLabel = label("Jira Project Key:", y: 118)
        projectKeyField  = field(placeholder: "e.g. FUN", y: 118)
        let intervalLabel = label("Check Interval (min):", y: 76)
        intervalField     = field(placeholder: "5", y: 76)

        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.frame = NSRect(x: 260, y: 22, width: 80, height: 32)
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.frame = NSRect(x: 170, y: 22, width: 80, height: 32)
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"

        for view in [projectLabel, projectKeyField, intervalLabel, intervalField,
                     save, cancel] as [NSView] { v.addSubview(view) }
    }

    @objc private func saveClicked() {
        let key = projectKeyField.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
        let interval = max(1.0, Double(intervalField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 5.0)
        guard !key.isEmpty else {
            let alert = NSAlert(); alert.messageText = "Project key cannot be empty."; alert.runModal()
            return
        }
        onSave?(key, interval)
        window?.orderOut(nil)
    }
    @objc private func cancelClicked() { window?.orderOut(nil) }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?

    private var projectKey: String = "FUN"
    private var checkIntervalMinutes: Double = 5.0
    private var isChecking = false
    private var lastCheckDate: Date?
    private var connectionStatus = "connected"

    private var projectMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var lastCheckMenuItem: NSMenuItem!
    private var reconnectMenuItem: NSMenuItem!
    private var viewUpdatesMenuItem: NSMenuItem!

    private lazy var prefsController    = PreferencesWindowController()
    private lazy var updatesController  = UpdatesPanelController()

    private let configDir: String = {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/jira-notifier"
    }()
    private var scriptsDir: String {
        Bundle.main.resourcePath ?? configDir
    }
    private var pythonPath: String = "/usr/bin/python3"

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        resolvePython()
        setupNotifications()
        buildMenuBar()
        loadConfig()
        refreshUpdatesMenuItem()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onChangesCleared),
            name: .jiraChangesCleared, object: nil
        )
        if hasToken() {
            setIcon(state: "checking")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.performCheck(manual: false)
            }
            scheduleTimer()
        } else {
            setIcon(state: "auth_expired")
            statusMenuItem.title = "Status: Not Connected 🔴"
            showFirstRunOnboarding()
        }
    }

    private func resolvePython() {
        let candidates = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
        pythonPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    private func hasToken() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "com.sap.jira-notifier", "-a", "oauth_token", "-w"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private func showFirstRunOnboarding() {
        let alert = NSAlert()
        alert.messageText = "Connect to SAP Jira"
        alert.informativeText = "Jira Notifier needs to connect to your SAP Jira account to monitor updates.\n\nClick Connect to open a browser and sign in."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { reconnectClicked() }
    }

    // MARK: Notifications

    private func setupNotifications() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: Menu Bar

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "com.sap.jira-notifier.statusItem"
        setIcon(state: "connected")
        menu = NSMenu()

        let title = NSMenuItem(title: "Jira Notifier", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        viewUpdatesMenuItem = NSMenuItem(title: "No pending updates",
                                         action: #selector(viewUpdatesTapped), keyEquivalent: "u")
        viewUpdatesMenuItem.target = self
        viewUpdatesMenuItem.isEnabled = false
        menu.addItem(viewUpdatesMenuItem)

        menu.addItem(.separator())

        projectMenuItem = NSMenuItem(title: "Project: —", action: nil, keyEquivalent: "")
        projectMenuItem.isEnabled = false
        menu.addItem(projectMenuItem)

        statusMenuItem = NSMenuItem(title: "Status: Initializing...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        lastCheckMenuItem = NSMenuItem(title: "Last Checked: Never", action: nil, keyEquivalent: "")
        lastCheckMenuItem.isEnabled = false
        menu.addItem(lastCheckMenuItem)

        menu.addItem(.separator())

        let openJira = NSMenuItem(title: "Open Jira Project in Browser",
                                   action: #selector(openJiraClicked), keyEquivalent: "o")
        openJira.target = self
        menu.addItem(openJira)

        menu.addItem(.separator())

        reconnectMenuItem = NSMenuItem(title: "Reconnect / Re-authenticate...",
                                        action: #selector(reconnectClicked), keyEquivalent: "")
        reconnectMenuItem.target = self
        menu.addItem(reconnectMenuItem)

        let prefs = NSMenuItem(title: "Preferences...", action: #selector(openPrefsClicked), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let logs = NSMenuItem(title: "View Logs...", action: #selector(viewLogsClicked), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Jira Notifier", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    private func refreshUpdatesMenuItem() {
        let n = updatesController.pendingCount()
        if n == 0 {
            viewUpdatesMenuItem.title = "No pending updates"
            viewUpdatesMenuItem.isEnabled = false
            setIcon(state: connectionStatus)
        } else {
            viewUpdatesMenuItem.title = "View Updates (\(n))  ↩"
            viewUpdatesMenuItem.isEnabled = true
            setIcon(state: "updates")
        }
    }

    @objc private func onChangesCleared() {
        refreshUpdatesMenuItem()
    }

    // MARK: Config

    private var configFile: String { "\(configDir)/config.json" }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            projectMenuItem.title = "Project: \(projectKey)"; return
        }
        if let k = json["project_key"] as? String, !k.isEmpty { projectKey = k }
        if let i = json["interval_minutes"] as? Double { checkIntervalMinutes = i }
        else if let i = json["interval_minutes"] as? Int { checkIntervalMinutes = Double(i) }
        projectMenuItem.title = "Project: \(projectKey)"
    }

    private func saveConfig(key: String, interval: Double) {
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(
            withJSONObject: ["project_key": key, "interval_minutes": interval],
            options: .prettyPrinted
        )
        try? data?.write(to: URL(fileURLWithPath: configFile))
        projectKey = key; checkIntervalMinutes = interval
        projectMenuItem.title = "Project: \(projectKey)"
        scheduleTimer()
    }

    // MARK: Polling

    private func scheduleTimer() {
        timer?.invalidate()
        let seconds = max(60.0, checkIntervalMinutes * 60.0)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.performCheck(manual: false)
        }
    }

    private func performCheck(manual: Bool) {
        guard !isChecking else { return }
        isChecking = true
        loadConfig()
        statusMenuItem.title = "Status: Checking... 🔄"
        setIcon(state: "checking")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.pythonPath)
            process.arguments = ["-I", "\(self.scriptsDir)/daemon.py", "--check-once"]
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    self.isChecking = false
                    self.lastCheckDate = Date()
                    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
                    self.lastCheckMenuItem.title = "Last Checked: \(fmt.string(from: self.lastCheckDate!))"
                    self.handleCheckResult(exitCode: process.terminationStatus, output: output, manual: manual)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isChecking = false
                    self.statusMenuItem.title = "Status: Python not found ⚠️"
                    self.setIcon(state: "error")
                }
            }
        }
    }

    private func handleCheckResult(exitCode: Int32, output: String, manual: Bool) {
        let statusFile = "\(configDir)/status.json"
        var status  = "connected"
        var changes = 0
        if let data = try? Data(contentsOf: URL(fileURLWithPath: statusFile)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = json["status"]           as? String { status  = s }
            if let c = json["changes_detected"] as? Int    { changes = c }
        } else {
            switch exitCode { case 2: status = "auth_expired"; case 3: status = "offline"
            case 0: status = "connected"; default: status = "error" }
        }
        connectionStatus = status

        switch status {
        case "connected":
            statusMenuItem.title = "Status: Connected 🟢"
            refreshUpdatesMenuItem()         // updates icon + menu item
            if changes > 0 {
                showUpdatesPanel()           // auto-open panel when new changes arrive
            } else if manual {
                sendNotification(title: "Jira Notifier", body: "Project \(projectKey) is up to date.")
            }
        case "auth_expired":
            statusMenuItem.title = "Status: Session Expired 🔴"
            setIcon(state: "auth_expired")
            sendNotification(title: "Jira Notifier: Session Expired",
                             body: "Your SAP Jira session has expired. Use Reconnect in the menu bar.")
        case "offline":
            statusMenuItem.title = "Status: Offline ⚠️"
            setIcon(state: "offline")
            sendNotification(title: "Jira Notifier: Offline",
                             body: "Cannot reach jira.tools.sap. Check your VPN connection.")
        default:
            statusMenuItem.title = "Status: Error ⚠️"
            setIcon(state: "error")
        }
    }

    private func showUpdatesPanel() {
        updatesController.onSettingsTapped = { [weak self] in
            guard let self else { return }
            self.statusItem.menu = self.menu
            self.statusItem.button?.performClick(nil)
            self.statusItem.menu = nil
        }
        updatesController.show(near: statusItem, projectKey: projectKey)
    }

    // MARK: Menu Actions

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseDown {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            if updatesController.isVisible {
                updatesController.dismiss()
            } else {
                showUpdatesPanel()
                if !isChecking { performCheck(manual: false) }
            }
        }
    }

    @objc private func viewUpdatesTapped()  { showUpdatesPanel() }
    @objc private func checkNowClicked()    { guard !isChecking else { return }; performCheck(manual: true) }

    @objc private func reconnectClicked() {
        reconnectMenuItem.isEnabled = false
        reconnectMenuItem.title = "Reconnecting..."
        statusMenuItem.title    = "Status: Authenticating..."
        setIcon(state: "checking")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.pythonPath)
            process.arguments = ["-I", "\(self.scriptsDir)/auth.py", "--login"]
            do {
                try process.run(); process.waitUntilExit()
                DispatchQueue.main.async {
                    self.reconnectMenuItem.isEnabled = true
                    self.reconnectMenuItem.title = "Reconnect / Re-authenticate..."
                    if process.terminationStatus == 0 {
                        self.sendNotification(title: "Jira Notifier", body: "Successfully connected to SAP Jira.")
                        self.scheduleTimer()
                        self.performCheck(manual: false)
                    } else {
                        self.statusMenuItem.title = "Status: Auth Failed 🔴"
                        self.setIcon(state: "auth_expired")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.reconnectMenuItem.isEnabled = true
                    self.reconnectMenuItem.title = "Reconnect / Re-authenticate..."
                    self.setIcon(state: "error")
                }
            }
        }
    }

    @objc private func openPrefsClicked() {
        prefsController.onSave = { [weak self] key, interval in self?.saveConfig(key: key, interval: interval) }
        prefsController.show(currentProject: projectKey, currentInterval: checkIntervalMinutes)
    }

    @objc private func openJiraClicked() {
        guard let url = URL(string: "https://jira.tools.sap/browse/\(projectKey)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func viewLogsClicked() {
        let path = "\(configDir)/notifier.log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func quitClicked() { NSApplication.shared.terminate(self) }

    // MARK: Icon

    private lazy var jiraIconBase: NSImage? = {
        let custom = "\(configDir)/jira-icon.svg"
        let svgPath = FileManager.default.fileExists(atPath: custom) ? custom : "\(scriptsDir)/jira-icon.svg"
        guard let source = NSImage(contentsOf: URL(fileURLWithPath: svgPath)) else { return nil }
        let target = NSSize(width: 18, height: 18)
        return NSImage(size: target, flipped: false) { rect in
            source.draw(in: rect, from: NSRect(origin: .zero, size: source.size),
                        operation: .sourceOver, fraction: 1)
            return true
        }
    }()

    private lazy var jiraIconOutline: NSImage? = {
        let custom = "\(configDir)/jira-icon-outline.svg"
        let svgPath = FileManager.default.fileExists(atPath: custom) ? custom : "\(scriptsDir)/jira-icon-outline.svg"
        guard let source = NSImage(contentsOf: URL(fileURLWithPath: svgPath)) else { return nil }
        let target = NSSize(width: 18, height: 18)
        return NSImage(size: target, flipped: false) { rect in
            source.draw(in: rect, from: NSRect(origin: .zero, size: source.size),
                        operation: .sourceOver, fraction: 1)
            return true
        }
    }()

    private func setIcon(state: String) {
        guard let button = statusItem.button else { return }

        let badgeColor: NSColor?
        switch state {
        case "updates":               badgeColor = .systemRed
        case "auth_expired", "error": badgeColor = .systemOrange
        case "offline":               badgeColor = .systemGray
        default:                      badgeColor = nil
        }

        guard let badge = badgeColor else {
            // No updates — outline icon as template; AppKit adapts to menu bar appearance
            guard let outline = jiraIconOutline else { return }
            let img = outline.copy() as! NSImage
            img.isTemplate = true
            button.image = img
            return
        }

        // Has badge — solid icon recolored to menu bar foreground + colored dot
        let size = NSSize(width: 22, height: 18)
        guard let base = jiraIconBase else { return }
        let img = NSImage(size: size, flipped: false) { [base] _ in
            let iconRect = NSRect(origin: .zero, size: NSSize(width: 18, height: 18))
            base.draw(in: iconRect, from: NSRect(origin: .zero, size: base.size),
                      operation: .sourceOver, fraction: 1)
            NSColor.labelColor.setFill()
            iconRect.fill(using: .sourceAtop)
            badge.setFill()
            NSBezierPath(ovalIn: NSRect(x: 16, y: 11, width: 6, height: 6)).fill()
            return true
        }
        img.isTemplate = false
        button.image = img
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
