import AppKit

/// Borderless, transparent window: only the scale is visible on the desktop.
final class ScaleWindow: NSWindow {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenNone]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: ScaleWindow!
    private var controller: ScaleController!
    private var clickThroughTimer: Timer?
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        controller = ScaleController()
        guard let view = controller.view else { return }

        window = ScaleWindow(size: NSSize(width: 760, height: 640))
        window.contentView = view
        if let saved = defaults.string(forKey: "windowOrigin") {
            window.setFrameOrigin(NSPointFromString(saved))
        } else {
            window.center()
        }
        window.level = defaults.bool(forKey: "floating") ? .floating : .normal
        Sound.shared.enabled = !defaults.bool(forKey: "muted")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.defaults.set(NSStringFromPoint(self.window.frame.origin), forKey: "windowOrigin")
        }

        // Clicks on transparent pixels fall through to whatever is behind the scale.
        clickThroughTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.updateClickThrough()
        }
        controller.introAnimation()
        if CommandLine.arguments.contains("--demo") { runDemo() }
    }

    /// Scripted interaction used for testing the real app without a human at the mouse.
    private func runDemo() {
        let c = controller!
        let files = CommandLine.arguments.filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        func at(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(2.0) { c.dragEntered(urls: files, at: CGPoint(x: -20, y: 30)) }
        for i in 0..<30 { at(2.0 + Double(i) * 0.03) { c.dragUpdated(at: CGPoint(x: -20 + Double(i), y: 30 - Double(i) * 1.2)) } }
        at(3.4) { _ = c.performDrop() }
        at(6.0) { c.view?.tapButton(.unit) }
        at(7.0) { c.view?.tapButton(.pcs) }
        at(8.0) { c.view?.tapButton(.pcs) }
        at(8.5) { c.view?.tapButton(.tare) }
    }

    private var lastMouse = NSPoint(x: -1, y: -1)

    private func updateClickThrough() {
        guard let view = controller.view else { return }
        let mouse = NSEvent.mouseLocation
        if mouse == lastMouse && !view.isTrackingMouse { return }
        lastMouse = mouse
        if view.isTrackingMouse { window.ignoresMouseEvents = false; return }
        var solid = false
        if window.frame.contains(mouse) {
            let p = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
            solid = view.isSolid(at: p)
        }
        if window.ignoresMouseEvents == solid { window.ignoresMouseEvents = !solid }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menus

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Digital Scale", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Digital Scale", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Digital Scale", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let scaleItem = NSMenuItem()
        main.addItem(scaleItem)
        scaleItem.submenu = scaleMenu(title: "Scale")
        NSApp.mainMenu = main
    }

    private func scaleMenu(title: String) -> NSMenu {
        let m = NSMenu(title: title)
        func add(_ t: String, _ sel: Selector, _ key: String = "", mods: NSEvent.ModifierFlags = []) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            m.addItem(i)
        }
        add("Power On / Off", #selector(menuPower))
        add("Tare", #selector(menuTare))
        add("Unit", #selector(menuUnit))
        add("Piece Count", #selector(menuPCS))
        m.addItem(.separator())
        add("Clear Platform", #selector(menuClear), "\u{8}", mods: [.command])
        m.addItem(.separator())
        let float = NSMenuItem(title: "Float Above Other Windows", action: #selector(menuFloat), keyEquivalent: "")
        float.target = self
        float.state = defaults.bool(forKey: "floating") ? .on : .off
        m.addItem(float)
        let sound = NSMenuItem(title: "Sounds", action: #selector(menuSound), keyEquivalent: "")
        sound.target = self
        sound.state = defaults.bool(forKey: "muted") ? .off : .on
        m.addItem(sound)
        return m
    }

    func contextMenu() -> NSMenu {
        let m = scaleMenu(title: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Digital Scale", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return m
    }

    @objc private func menuPower() { controller.view?.tapButton(.power) }
    @objc private func menuTare() { controller.view?.tapButton(.tare) }
    @objc private func menuUnit() { controller.view?.tapButton(.unit) }
    @objc private func menuPCS() { controller.view?.tapButton(.pcs) }
    @objc private func menuClear() { controller.clearPlate() }

    @objc private func menuFloat(_ sender: NSMenuItem) {
        let on = !defaults.bool(forKey: "floating")
        defaults.set(on, forKey: "floating")
        window.level = on ? .floating : .normal
        buildMenu()
    }

    @objc private func menuSound(_ sender: NSMenuItem) {
        let muted = !defaults.bool(forKey: "muted")
        defaults.set(muted, forKey: "muted")
        Sound.shared.enabled = !muted
        buildMenu()
    }
}
