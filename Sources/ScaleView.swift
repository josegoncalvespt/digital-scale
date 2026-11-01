import AppKit
import SceneKit

/// The SceneKit view that *is* the app. Handles mouse, keyboard and file drops.
final class ScaleView: SCNView {
    unowned let controller: ScaleController
    let world: ScaleScene

    private enum Tracking { case none, button, item }
    private var tracking: Tracking = .none
    var isTrackingMouse: Bool { tracking != .none }

    private var savedDragImages: [Int: (() -> [NSDraggingImageComponent])?] = [:]

    init(controller: ScaleController, world: ScaleScene) {
        self.controller = controller
        self.world = world
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 640),
                   options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        scene = world.scene
        pointOfView = world.cameraNode
        backgroundColor = .clear
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 120
        autoenablesDefaultLighting = false
        allowsCameraControl = false
        wantsLayer = true
        layer?.isOpaque = false
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Geometry

    /// Projects a view point onto a horizontal plane above the platform; returns plate-local (x, z).
    func platePoint(_ p: NSPoint, height: CGFloat = ScaleController.hoverHeight) -> CGPoint {
        let near = unprojectPoint(SCNVector3(p.x, p.y, 0))
        let far = unprojectPoint(SCNVector3(p.x, p.y, 1))
        let planeY = world.plateTopNode.convertPosition(SCNVector3Zero, to: nil).y + height
        let dy = far.y - near.y
        guard abs(dy) > 1e-6 else { return .zero }
        let t = (planeY - near.y) / dy
        let x = near.x + (far.x - near.x) * t
        let z = near.z + (far.z - near.z) * t
        return CGPoint(x: x, y: z - Dim.plateZ)
    }

    enum Hit { case button(ButtonID), item(ScaleItem), body, none }

    func hitThing(at p: NSPoint) -> Hit {
        let mask = ScaleScene.interactiveMask | ScaleScene.itemMask | ScaleScene.decorMask
        let hits = hitTest(p, options: [
            .categoryBitMask: mask,
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true,
        ])
        for h in hits {
            if h.node.categoryBitMask & ScaleScene.itemMask != 0, let name = h.node.name,
               let item = controller.item(named: name), item.state == .resting || item.state == .falling {
                return .item(item)
            }
        }
        guard let first = hits.first else { return .none }
        if let name = first.node.name, name.hasPrefix("button:"), let id = ButtonID(rawValue: String(name.dropFirst(7))) {
            return .button(id)
        }
        return .body
    }

    /// Cheap check used to decide whether the window should swallow clicks at this point.
    func isSolid(at p: NSPoint) -> Bool {
        let hits = hitTest(p, options: [
            .categoryBitMask: ScaleScene.interactiveMask | ScaleScene.itemMask | ScaleScene.decorMask,
            .searchMode: SCNHitTestSearchMode.any.rawValue,
            .boundingBoxOnly: true,
            .ignoreHiddenNodes: true,
        ])
        return !hits.isEmpty
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        switch hitThing(at: p) {
        case .button(let id):
            tracking = .button
            controller.pressButton(id)
        case .item(let item):
            tracking = .item
            controller.pick(item, at: platePoint(p))
            NSCursor.closedHand.set()
        case .body:
            tracking = .none
            window?.performDrag(with: event)
        case .none:
            tracking = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking == .item else { return }
        controller.dragHeld(to: platePoint(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        switch tracking {
        case .button: controller.releaseButton()
        case .item: controller.releaseHeld()
        case .none: break
        }
        tracking = .none
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at p: NSPoint) {
        guard tracking == .none else { return }
        switch hitThing(at: p) {
        case .button: NSCursor.pointingHand.set()
        case .item: NSCursor.openHand.set()
        default: NSCursor.arrow.set()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = (NSApp.delegate as? AppDelegate)?.contextMenu()
        if let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t": tapButton(.tare)
        case "u": tapButton(.unit)
        case "p": tapButton(.pcs)
        case "o", " ": tapButton(.power)
        default:
            if event.keyCode == 51 || event.keyCode == 117 { controller.clearPlate() } else { super.keyDown(with: event) }
        }
    }

    func tapButton(_ id: ButtonID) {
        controller.pressButton(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.controller.releaseButton() }
    }

    // MARK: - Drag & drop

    private func urls(from info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let list = urls(from: sender)
        guard !list.isEmpty else { return [] }
        hideDragImages(sender)
        controller.dragEntered(urls: list, at: platePoint(convert(sender.draggingLocation, from: nil)))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller.dragUpdated(at: platePoint(convert(sender.draggingLocation, from: nil)))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender { restoreDragImages(sender) }
        controller.dragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.animatesToDestination = false
        savedDragImages.removeAll()
        return controller.performDrop()
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {}

    /// The 3D tile replaces the system drag image while over the scale.
    private func hideDragImages(_ info: NSDraggingInfo) {
        savedDragImages.removeAll()
        info.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self], searchOptions: [:]) { item, idx, _ in
            self.savedDragImages[idx] = item.imageComponentsProvider
            item.imageComponentsProvider = { [] }
        }
    }

    private func restoreDragImages(_ info: NSDraggingInfo) {
        guard !savedDragImages.isEmpty else { return }
        info.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self], searchOptions: [:]) { item, idx, _ in
            if let saved = self.savedDragImages[idx] { item.imageComponentsProvider = saved }
        }
        savedDragImages.removeAll()
    }
}
