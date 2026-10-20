import AppKit
import EventKit
import ServiceManagement
import SwiftUI
import CalSyncCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var changeDebounce: Timer?

    /// EventKit notifies us about *our own* writes too. Ignoring changes for a short
    /// window after each sync stops a run from immediately triggering another.
    private var ignoreStoreChangesUntil = Date.distantPast

    let calendars = CalendarStore()
    let settings = SettingsStore()
    private lazy var engine = SyncEngine(calendars: calendars, settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        observeSystemEvents()

        Task {
            await Notifier.requestAuthorizationIfNeeded()
            let granted = await calendars.requestAccess()
            Log.write("START access=\(granted ? "granted" : "denied") "
                    + "configured=\(settings.config.isConfigured)")

            if !granted || !settings.config.isConfigured {
                openSettings()   // first run, or permissions were revoked
            } else {
                await engine.syncNow(trigger: "launch")
            }
            refreshMenu()
            restartTimer()
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "CalSync"
        applyStatusImage(alert: false)
        // A status item macOS previously hid stays hidden until asked otherwise.
        statusItem.isVisible = true
        statusItem.menu = NSMenu()

        Log.write("INFO status item created image=\(statusItem.button?.image != nil) "
                + "visible=\(statusItem.isVisible) length=\(statusItem.length) "
                + "barHeight=\(NSStatusBar.system.thickness)")
        refreshMenu()
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        menu.addItem(disabledItem(statusLine()))
        if let problem = ConfigValidator.validate(settings.config) {
            menu.addItem(disabledItem(problem))
        }
        menu.addItem(.separator())

        let sync = NSMenuItem(title: engine.isSyncing ? "Syncing…" : "Sync Now",
                              action: #selector(syncNow), keyEquivalent: "s")
        sync.target = self
        sync.isEnabled = !engine.isSyncing && settings.config.isConfigured
        menu.addItem(sync)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Open Log", #selector(openLog), key: ""))

        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLaunchAtLogin), key: "")
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit CalSync", #selector(quit), key: "q"))

        // Surface trouble on the icon itself, so it is visible without opening the menu.
        applyStatusImage(alert: engine.lastOutcome?.hasProblem ?? false)
    }

    /// A status item whose button has no image and no title collapses to zero width and
    /// is simply invisible — indistinguishable from the app not running. Fall back
    /// through the drawn mark, then a system symbol, then plain text, so the item is
    /// always findable.
    private func applyStatusImage(alert: Bool) {
        guard let button = statusItem?.button else { return }

        if let drawn = CalSyncMark.statusItemImage(alert: alert) {
            button.image = drawn
            button.imagePosition = .imageOnly
            button.title = ""
            return
        }
        Log.write("WARN could not render the status icon; falling back")

        if let symbol = NSImage(systemSymbolName: alert ? "calendar.badge.exclamationmark"
                                                       : "calendar.badge.clock",
                                accessibilityDescription: "CalSync") {
            button.image = symbol
            button.title = ""
            return
        }
        button.image = nil
        button.title = alert ? "CalSync!" : "CalSync"
    }

    private func statusLine() -> String {
        if engine.isSyncing { return "Syncing…" }
        guard let outcome = engine.lastOutcome else {
            return settings.config.isConfigured ? "Not synced yet" : "Not set up yet"
        }
        let time = outcome.finishedAt.formatted(date: .omitted, time: .shortened)
        return "\(outcome.shortSummary) · \(time)"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Scheduling

    private func restartTimer() {
        timer?.invalidate()
        let minutes = max(1, settings.config.syncIntervalMinutes)
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes) * 60, repeats: true) { _ in
            Task { @MainActor in await self.runSync(trigger: "timer") }
        }
    }

    private func observeSystemEvents() {
        // React to calendar edits so a new meeting is blocked within seconds rather
        // than at the next tick.
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                Task { @MainActor in self.calendarsChanged() }
            }

        // A sleeping Mac fires no timers; catch up on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in await self.runSync(trigger: "wake") }
            }
    }

    private func calendarsChanged() {
        guard Date() >= ignoreStoreChangesUntil, !engine.isSyncing else { return }
        changeDebounce?.invalidate()
        changeDebounce = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            Task { @MainActor in await self.runSync(trigger: "calendar-change") }
        }
    }

    private func runSync(trigger: String) async {
        refreshMenu()
        await engine.syncNow(trigger: trigger)
        ignoreStoreChangesUntil = Date().addingTimeInterval(15)
        refreshMenu()
    }

    // MARK: - Actions

    @objc private func syncNow() {
        Task { await runSync(trigger: "manual") }
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Log.fileURL.path) {
            Log.write("INFO log opened before first run")
        }
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("ERROR launch-at-login toggle failed: \(error.localizedDescription)")
            presentAlert("Could not change the login setting", error.localizedDescription)
        }
        refreshMenu()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                settings: settings,
                calendars: calendars,
                onSave: { [weak self] in
                    guard let self else { return }
                    self.restartTimer()
                    self.refreshMenu()
                    Task { await self.runSync(trigger: "settings-saved") }
                })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 680),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 560, height: 620)
            window.title = "CalSync Settings"
            window.contentViewController = NSHostingController(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func presentAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
