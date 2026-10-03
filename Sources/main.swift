// Earshot: headset battery, settings and audio switching in the macOS menu bar.

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let headset = Headset()
    private var switcher: Switcher!
    /// nil until the baseline is known: a headset that is already on at launch is not "turning on".
    /// Switching at launch once took the sound away from what the user was listening on.
    private var wasOn: Bool?
    /// Kept, not rebuilt, so its title updates live while the menu is open.
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        switcher = Switcher()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        headset.onChange = { [weak self] in self?.stateChanged() }
        render()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.headset.request() }
        // The first report sets the baseline; with no dongle there is no report, so settle after 2 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wasOn == nil else { return }
            self.wasOn = self.headset.isOn
        }
    }

    private func stateChanged() {
        render()
        let on = headset.isOn
        if let wasOn, on != wasOn { on ? switcher.headsetOn() : switcher.headsetOff() }
        wasOn = on
    }

    private func render() {
        // No dongle, no icon.
        item.isVisible = headset.state != .noDongle
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headset")
        button.imagePosition = .imageLeading
        var colour: NSColor?
        let title = NSMutableAttributedString()
        switch headset.state {
        case .noDongle:
            break
        case .off:
            title.append(NSAttributedString(string: "off"))
        case .onBattery(let level):
            title.append(NSAttributedString(string: "\(level)%"))
            if level <= lowBattery { colour = .systemRed }
        case .charging(let level), .pluggedIn(let level):
            title.append(NSAttributedString(string: "\(level)%"))
            let bolt = NSTextAttachment()
            bolt.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "charging")
            title.append(NSAttributedString(attachment: bolt))
        }
        if let colour {
            title.addAttribute(.foregroundColor, value: colour, range: NSRange(location: 0, length: title.length))
        }
        button.attributedTitle = title
        button.appearsDisabled = !headset.isOn

        switch headset.state {
        case .noDongle: statusLine.title = "Dongle not plugged in"
        case .off: statusLine.title = "Headset off"
        case .onBattery(let level): statusLine.title = "Battery \(level)%, on battery"
        case .charging(let level): statusLine.title = "Battery \(level)%, charging"
        case .pluggedIn(let level): statusLine.title = "Battery \(level)%, plugged in, not charging"
        }
        if headset.micMuted { statusLine.title += " · mic muted" }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        headset.request()
        headset.requestSettings()
        menu.removeAllItems()
        menu.addItem(NSMenuItem.sectionHeader(title: headset.name))
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(submenu("Audio switching", switchingMenu()))
        menu.addItem(submenu("Headset settings", controlsMenu()))
        menu.addItem(.separator())
        let login = action("Open at Login", #selector(toggleLogin), nil)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("About Earshot", #selector(showAbout), nil))
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func switchingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(title: "When the headset turns on, use it for"))
        for role in Role.allCases {
            let entry = action(role.title, #selector(toggleUse(_:)), role.rawValue)
            entry.state = Settings.useHeadset(role) ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "When it turns off, switch to"))
        for role in Role.allCases {
            menu.addItem(submenu("\(role.title): \(label(Settings.fallback(role)))", fallbackMenu(role)))
        }
        return menu
    }

    private func fallbackMenu(_ role: Role) -> NSMenu {
        let menu = NSMenu()
        let current = Settings.fallback(role)
        func add(_ title: String, _ fallback: Fallback) {
            let entry = action(title, #selector(chooseFallback(_:)), [role.rawValue, fallback.stored])
            entry.state = fallback == current ? .on : .off
            menu.addItem(entry)
        }
        add("Don't switch", .none)
        add("Previous device" + (switcher.previousName(role).map { " (\($0))" } ?? ""), .previous)
        menu.addItem(.separator())
        let headsetUID = Audio.headset()?.uid
        let devices = Audio.devices(for: role).filter { $0.uid != headsetUID }
        for device in devices {
            add(device.name, .device(uid: device.uid, name: device.name))
        }
        if case .device(let uid, let name) = current, !devices.contains(where: { $0.uid == uid }) {
            add("\(name) (not connected)", current)
        }
        return menu
    }

    private func controlsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.sectionHeader(title: headset.isOn
            ? "Read from the headset"
            : "Turn the headset on to change these"))
        for (index, control) in controls.enumerated() {
            let current = control.read(headset.readings)
            // An EQ preset made in the phone app is not in our list, so show its name as it is.
            let label = current.flatMap { value in control.options.first { $0.value == value }?.label }
                ?? (control.title == "Equaliser" ? headset.readings.equaliserName : nil)
                ?? "unknown"
            let options = NSMenu()
            options.autoenablesItems = false
            for option in control.options {
                let choice = action(option.label, #selector(chooseControl(_:)), [index, option.value])
                choice.state = option.value == current ? .on : .off
                choice.isEnabled = headset.isOn
                options.addItem(choice)
            }
            menu.addItem(submenu("\(control.title): \(label)", options))
        }
        return menu
    }

    private func label(_ fallback: Fallback) -> String {
        switch fallback {
        case .none: "don't switch"
        case .previous: "previous device"
        case .device(_, let name): name
        }
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }

    private func action(_ title: String, _ selector: Selector, _ value: Any?) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        entry.representedObject = value
        return entry
    }

    // MARK: Actions

    /// Sends the pick once. The headset keeps it, like the phone app's settings.
    @objc private func chooseControl(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2,
              controls.indices.contains(pair[0]), headset.isOn else { return }
        headset.send(commands: controls[pair[0]].commands(pair[1]))
    }

    @objc private func toggleUse(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let role = Role(rawValue: raw) else { return }
        let on = !Settings.useHeadset(role)
        Settings.setUseHeadset(role, on)
        if on, headset.isOn { switcher.headsetOn() }  // takes effect now, not at the next power-on
    }

    @objc private func chooseFallback(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let role = Role(rawValue: pair[0]) else { return }
        Settings.setFallback(role, Fallback(stored: pair[1]))
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func showAbout() {
        let link = "https://github.com/gabrielbelli/earshot"
        let credits = NSMutableAttributedString(
            string: "Battery, settings and audio switching for your headset.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)])
        credits.append(NSAttributedString(string: link, attributes: [.link: link, .font: NSFont.systemFont(ofSize: 11)]))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
