import AppKit

/// The whole of the app's UI: an icon in the menu bar, and three things behind it.
///
/// This used to be a live picture of every session — one circle each, filled when a session wanted you
/// and a hairline ring when it was merely working, with an overflow badge, cross-fades and a session
/// list. All of it is gone. The picture was answering a question the notification already answers, and
/// it was answering it somewhere you have to *remember to look*.
///
/// What is left is the smallest thing that can still do the job: **notify**, and be switchable off.
///
/// The icon is deliberately **static**. Nothing about it moves when a session starts, finishes or
/// blocks — because the moment it did, it would be a picture again, and you would go back to watching
/// the menu bar instead of trusting the notification.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let item: NSStatusItem
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let notificationsItem = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")

    var onQuit: (() -> Void)?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.image = MenuBarIcon.image()
        item.button?.toolTip = "NotifyMe"

        // Assigning `.menu` is what makes a plain **left**-click open it. This used to be a custom
        // NSView, because a menu swallows left-clicks and a left-click had to teleport to a session.
        // Nothing is teleported from the bar any more, so the standard behaviour is the right one — and
        // it brings keyboard access and the highlight state along with it, for free.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        notificationsItem.action = #selector(toggleNotifications)
        for entry in [launchAtLoginItem, notificationsItem] {
            entry.target = self
            entry.isEnabled = true
            menu.addItem(entry)
        }

        menu.addItem(.separator())

        // No ⌘Q. This is an `.accessory` app — never the key application — so a key equivalent here can
        // never fire, and AppKit will not even draw it. A menu advertising a shortcut that cannot work
        // is just a lie.
        let quit = NSMenuItem(title: "Quit NotifyMe", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        item.menu = menu
        refresh()
    }

    // MARK: - State

    /// Re-read both switches from whoever actually owns them, every time the menu opens.
    ///
    /// Launch-at-login is not ours to remember. The user can switch it off in **System Settings → Login
    /// Items** without ever opening this menu, and a checkbox that went on insisting otherwise would be
    /// telling them a story about their own machine. `SMAppService` is asked afresh, and it wins.
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func refresh() {
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        notificationsItem.state = Preferences.shared.notificationsEnabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin() {
        // Registration can be refused. `refresh` re-reads the system rather than assuming the write
        // landed, so a failed toggle leaves the tick where the truth is — not where the click wanted it.
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        refresh()
    }

    @objc private func toggleNotifications() {
        Preferences.shared.notificationsEnabled.toggle()
        refresh()
    }

    @objc private func quit() {
        onQuit?()
    }
}
