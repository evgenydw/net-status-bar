import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let targetKey = "targetHost"
    private let interval: TimeInterval = 5
    private let offlineFailureThreshold = 3
    private let onlineSuccessThreshold = 2

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var isChecking = false
    private var stableOnlineStatus: Bool?
    private var consecutiveSuccesses = 0
    private var consecutiveFailures = 0
    private var targetHost: String {
        get {
            UserDefaults.standard.string(forKey: targetKey) ?? "1.1.1.1"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: targetKey)
        }
    }

    private let statusMenuItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
    private let targetMenuItem = NSMenuItem(title: "Target: 1.1.1.1", action: nil, keyEquivalent: "")
    private let lastCheckedMenuItem = NSMenuItem(title: "Last check: -", action: nil, keyEquivalent: "")
    private let notificationStatusMenuItem = NSMenuItem(title: "Notifications: Checking...", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LaunchServicesRegistration.registerSelf()
        NotificationManager.shared.prepare()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Checking internet status..."

        configureMenu()
        updateIndicator(isOnline: nil, message: "Checking...")
        runCheck()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runCheck()
            }
        }
    }

    private func configureMenu() {
        let menu = NSMenu()

        statusMenuItem.isEnabled = false
        targetMenuItem.isEnabled = false
        lastCheckedMenuItem.isEnabled = false
        notificationStatusMenuItem.isEnabled = false

        let checkNowItem = NSMenuItem(title: "Check Now", action: #selector(checkNow), keyEquivalent: "r")
        checkNowItem.target = self

        let changeTargetItem = NSMenuItem(title: "Change IP...", action: #selector(changeTarget), keyEquivalent: ",")
        changeTargetItem.target = self

        let enableNotificationsItem = NSMenuItem(title: "Enable Notifications...", action: #selector(enableNotifications), keyEquivalent: "n")
        enableNotificationsItem.target = self

        let testNotificationItem = NSMenuItem(title: "Test Notification", action: #selector(testNotification), keyEquivalent: "t")
        testNotificationItem.target = self

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(targetMenuItem)
        menu.addItem(lastCheckedMenuItem)
        menu.addItem(notificationStatusMenuItem)
        menu.addItem(.separator())
        menu.addItem(checkNowItem)
        menu.addItem(changeTargetItem)
        menu.addItem(enableNotificationsItem)
        menu.addItem(testNotificationItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshTargetText()
        refreshNotificationStatus()
    }

    private func runCheck() {
        guard !isChecking else { return }
        isChecking = true

        let host = targetHost
        statusMenuItem.title = "Status: Checking..."
        statusItem.button?.toolTip = "Checking \(host)..."

        Task.detached(priority: .background) {
            let online = await PingChecker.check(host: host)
            await MainActor.run {
                self.isChecking = false
                self.handleCheckResult(isOnline: online)
            }
        }
    }

    private func handleCheckResult(isOnline: Bool) {
        if isOnline {
            consecutiveSuccesses += 1
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
            consecutiveSuccesses = 0
        }

        let previousStatus = stableOnlineStatus
        let nextStatus = resolvedStatus(afterRawResult: isOnline)
        stableOnlineStatus = nextStatus

        updateIndicator(
            isOnline: nextStatus,
            message: statusMessage(rawOnline: isOnline, stableOnline: nextStatus)
        )

        if let previousStatus, let nextStatus, previousStatus != nextStatus {
            notifyStatusChanged(isOnline: nextStatus)
        }
    }

    private func resolvedStatus(afterRawResult isOnline: Bool) -> Bool? {
        switch stableOnlineStatus {
        case .none:
            if isOnline {
                return true
            }
            return consecutiveFailures >= offlineFailureThreshold ? false : nil
        case .some(true):
            return consecutiveFailures >= offlineFailureThreshold ? false : true
        case .some(false):
            return consecutiveSuccesses >= onlineSuccessThreshold ? true : false
        }
    }

    private func statusMessage(rawOnline: Bool, stableOnline: Bool?) -> String {
        if rawOnline {
            if stableOnline == false {
                return "Recovering \(consecutiveSuccesses)/\(onlineSuccessThreshold)"
            }
            return "Online"
        }

        if stableOnline == true {
            return "Online, missed \(consecutiveFailures)/\(offlineFailureThreshold)"
        }

        if stableOnline == nil {
            return "Checking, missed \(consecutiveFailures)/\(offlineFailureThreshold)"
        }

        return "Offline"
    }

    private func updateIndicator(isOnline: Bool?, message: String) {
        let color: NSColor
        let statusText: String

        switch isOnline {
        case .some(true):
            color = .systemGreen
            statusText = "Status: Online"
        case .some(false):
            color = .systemRed
            statusText = "Status: Offline"
        case .none:
            color = .systemGray
            statusText = "Status: \(message)"
        }

        statusItem.button?.image = IndicatorImage.make(color: color)
        statusItem.button?.toolTip = "\(message): \(targetHost)"
        statusMenuItem.title = statusText
        lastCheckedMenuItem.title = "Last check: \(DateFormatter.statusTime.string(from: Date()))"
        refreshTargetText()
    }

    private func notifyStatusChanged(isOnline: Bool) {
        if isOnline {
            NotificationManager.shared.showRestored()
        } else {
            NotificationManager.shared.showOffline()
        }
    }

    private func refreshTargetText() {
        targetMenuItem.title = "Target: \(targetHost)"
    }

    @objc private func checkNow() {
        runCheck()
    }

    @objc private func changeTarget() {
        let alert = NSAlert()
        alert.messageText = "Change IP"
        alert.informativeText = "Enter an IP address or host to ping."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = targetHost
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else { return }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        targetHost = value
        stableOnlineStatus = nil
        consecutiveSuccesses = 0
        consecutiveFailures = 0
        refreshTargetText()
        runCheck()
    }

    @objc private func enableNotifications() {
        NotificationManager.shared.requestPermissionFromMenu { [weak self] in
            self?.refreshNotificationStatus()
        }
    }

    @objc private func testNotification() {
        NotificationManager.shared.showTest { [weak self] in
            self?.refreshNotificationStatus()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshNotificationStatus() {
        Task {
            let status = await NotificationManager.shared.currentPermissionStatus()
            notificationStatusMenuItem.title = "Notifications: \(NotificationManager.label(for: status))"
        }
    }
}

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let offlineSoundName = "Sosumi"
    private let restoredSoundName = "Funk"

    private override init() {
        super.init()
    }

    func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestPermissionIfNeeded()
    }

    func requestPermissionFromMenu(completion: (() -> Void)? = nil) {
        LaunchServicesRegistration.registerSelf()

        Task {
            let status = await currentPermissionStatus()

            if status == .denied {
                showPermissionSettingsAlert()
                completion?()
                return
            }

            let granted = await requestPermission()
            if granted {
                showTest(completion: completion)
            } else {
                showPermissionSettingsAlert()
                completion?()
            }
        }
    }

    func requestPermissionIfNeeded() {
        Task {
            guard await currentPermissionStatus() == .notDetermined else { return }
            _ = await requestPermission()
        }
    }

    func showOffline() {
        show(
            title: "📡 Связь с цивилизацией потеряна",
            body: """
            VPN делает вид, что работает.
            Интернет с этим не согласен.
            """,
            soundName: offlineSoundName
        )
    }

    func showRestored() {
        show(
            title: "🟢 Цивилизация восстановлена",
            body: Bool.random()
                ? "Пакеты снова проходят границу."
                : "Интернет вернулся. Можно продолжать страдать.",
            soundName: restoredSoundName
        )
    }

    func showTest(completion: (() -> Void)? = nil) {
        show(
            title: "🔔 Нотификации включены",
            body: "Если ты это видишь, macOS больше не делает вид, что ничего не происходит.",
            soundName: restoredSoundName,
            completion: completion
        )
    }

    private func show(
        title: String,
        body: String,
        soundName: String,
        completion: (() -> Void)? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        Task {
            let status = await currentPermissionStatus()

            if notificationsAllowed(status) {
                await add(request)
                playSound(named: soundName)
                completion?()
                return
            }

            if status == .notDetermined {
                let granted = await requestPermission()
                if granted {
                    await add(request)
                } else {
                    showPermissionSettingsAlert()
                }
                playSound(named: soundName)
                completion?()
                return
            }

            playSound(named: soundName)
            showPermissionSettingsAlert()
            completion?()
        }
    }

    func currentPermissionStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    private func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    private func add(_ request: UNNotificationRequest) async {
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func notificationsAllowed(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private func playSound(named soundName: String) {
        if NSSound(named: soundName)?.play() != true {
            NSSound.beep()
        }
    }

    private func showPermissionSettingsAlert() {
        let alert = NSAlert()
        alert.messageText = "Notifications are disabled"
        alert.informativeText = "macOS is not allowing NetStatusBar to show notifications. Open System Settings and enable notifications for this app."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openNotificationSettings()
    }

    private func openNotificationSettings() {
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]

        for urlString in settingsURLs {
            guard let url = URL(string: urlString), NSWorkspace.shared.open(url) else {
                continue
            }
            return
        }
    }

    static func label(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

enum LaunchServicesRegistration {
    static func registerSelf() {
        let bundleURL = Bundle.main.bundleURL.path.hasSuffix(".app")
            ? Bundle.main.bundleURL
            : Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        process.arguments = ["-f", bundleURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }
}

enum PingChecker {
    static func check(host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-c", "1", "-W", "1000", host]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}

enum IndicatorImage {
    static func make(color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(x: 3, y: 3, width: 12, height: 12)
        let path = NSBezierPath(ovalIn: rect)

        color.setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1
        path.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

extension DateFormatter {
    static let statusTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
