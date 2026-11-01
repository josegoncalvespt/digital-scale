import AppKit
import SceneKit

/// Owns the scale's behaviour: power, units, tare, piece counting, the load-cell
/// reading dynamics, item physics and the LCD. Drives everything from one tick.
final class ScaleController: NSObject {
    let world = ScaleScene()
    private(set) var view: ScaleView?

    // Scale state
    private(set) var powered = false
    private var unitIndex = {
        let saved = UserDefaults.standard.object(forKey: "unitIndex") as? Int ?? Units.defaultIndex
        return (0..<Units.all.count).contains(saved) ? saved : Units.defaultIndex
    }() {
        didSet { UserDefaults.standard.set(unitIndex, forKey: "unitIndex") }
    }
    private var pcsMode = false
    private var tareGrams: Double = 0
    private var tareCount = 0

    // Load cell
    private var reading: Double = 0
    private var readingVel: Double = 0
    private var stable = true
    private var settleTime: Double = 0
    private var displayClock: Double = 0
    private var shownGross: Double = 0
    private var lastLCD: LCDState?

    // Power sequencing
    private var backlight: CGFloat = 0
    private var bootTimer: Double = 0
    private var messageTimer: Double = 0
    private var message: String?

    // Mechanics
    private var plateDip: CGFloat = 0
    private var plateVel: CGFloat = 0
    private var buttonDepth: [ButtonID: CGFloat] = [:]
    private var buttonHeld: ButtonID?

    // Items
    private(set) var items: [ScaleItem] = []
    private var heldItem: ScaleItem?
    private var dragHover: [ScaleItem] = []

    // Timing
    private var time: Double = 0
    private var idle: Double = 0
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    static let hoverHeight: CGFloat = 24
    static let gravity: CGFloat = 1900

    init(snapshotMode: Bool = false) {
        super.init()
        if !snapshotMode {
            let v = ScaleView(controller: self, world: world)
            view = v
            let link = v.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        ButtonID.allCases.forEach { buttonDepth[$0] = 0 }
        renderLCD(force: true)
    }

    // MARK: - Lifecycle

    func introAnimation() {
        world.root.opacity = 0
        world.root.position.y = -8
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.7
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        world.root.opacity = 1
        world.root.position.y = 0
        SCNTransaction.commit()
        wake()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.setPower(true, withClick: false)
        }
    }

    func prepareSnapshot(files: [URL]) {
        powered = true
        backlight = 1
        for (i, url) in files.enumerated() {
            let item = ScaleItem(url: url)
            item.state = .resting
            item.landed = true
            let n = CGFloat(files.count)
            item.pos = CGPoint(x: (CGFloat(i) - (n - 1) / 2) * 6, y: (CGFloat(i) - (n - 1) / 2) * -5)
            item.y = CGFloat(i) * (ScaleItem.thickness + 0.12)
            addNodes(item)
            items.append(item)
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
            item.bytes = Int64(vals?.totalFileSize ?? vals?.fileSize ?? 1_234_567)
            item.fileCount = 1
        }
        if CommandLine.arguments.contains("--hover"), let last = items.last {
            last.y = 18; last.pos = CGPoint(x: 4, y: 8); last.state = .hovering; last.landed = false
            last.tilt = CGPoint(x: 0.12, y: -0.08)
        }
        let gross = items.filter(\.countsTowardWeight).reduce(0) { $0 + $1.grams }
        reading = gross; shownGross = gross; stable = true
        syncNodes()
        renderLCD(force: true)
    }

    func wake() {
        idle = 0
        displayLink?.isPaused = false
        view?.rendersContinuously = true
    }

    // MARK: - Buttons

    func pressButton(_ id: ButtonID) {
        wake()
        buttonHeld = id
        Sound.shared.play("click")
        switch id {
        case .power:
            setPower(!powered, withClick: false)
        case .tare:
            guard powered, bootTimer <= 0 else { break }
            tareGrams = grossTarget
            tareCount = countTarget
            shownGross = reading
            Sound.shared.play("beep")
            stable = false
            settleTime = 0
        case .unit:
            guard powered, bootTimer <= 0 else { break }
            if pcsMode { pcsMode = false } else { unitIndex = (unitIndex + 1) % Units.all.count }
            Sound.shared.play("beep")
        case .pcs:
            guard powered, bootTimer <= 0 else { break }
            pcsMode.toggle()
            Sound.shared.play("beep")
        }
        renderLCD(force: false)
    }

    func releaseButton() {
        if buttonHeld != nil { Sound.shared.play("release") }
        buttonHeld = nil
        wake()
    }

    func setPower(_ on: Bool, withClick: Bool = true) {
        if withClick { Sound.shared.play("click") }
        wake()
        if on {
            powered = true
            bootTimer = 1.1
            Sound.shared.play("beepLong")
            // Like a real scale, powering on zeroes whatever is on the platform.
            tareGrams = grossTarget
            tareCount = countTarget
            pcsMode = false
        } else {
            powered = false
            bootTimer = 0
            Sound.shared.play("beep")
        }
    }

    // MARK: - Weight

    private var grossTarget: Double { items.filter(\.countsTowardWeight).reduce(0) { $0 + $1.grams } }
    private var countTarget: Int { items.filter(\.countsTowardWeight).reduce(0) { $0 + $1.fileCount } }

    // MARK: - Item interaction (plate-top coordinates)

    private func addNodes(_ item: ScaleItem) {
        world.itemsRoot.addChildNode(item.node)
        world.reflectionRoot.addChildNode(item.reflection)
        world.shadowsRoot.addChildNode(item.shadow)
    }

    private func startMeasuring(_ item: ScaleItem) {
        item.job = FileWeigher.weigh(item.url) { [weak self, weak item] bytes, files, done in
            guard let item else { return }
            item.bytes = bytes
            item.fileCount = files
            item.measured = done
            self?.wake()
        }
    }

    static let plateHalf = CGSize(width: Dim.plateW / 2, height: Dim.plateL / 2)

    private func clampToPlate(_ p: CGPoint) -> CGPoint {
        let mx = Self.plateHalf.width - ScaleItem.size * 0.32
        let mz = Self.plateHalf.height - ScaleItem.size * 0.32
        return CGPoint(x: max(-mx, min(mx, p.x)), y: max(-mz, min(mz, p.y)))
    }

    private func isOverPlate(_ p: CGPoint, margin: CGFloat = 4) -> Bool {
        abs(p.x) < Self.plateHalf.width + margin && abs(p.y) < Self.plateHalf.height + margin
    }

    // External drag & drop
    func dragEntered(urls: [URL], at p: CGPoint) {
        wake()
        dragHover.forEach { $0.state = .vanishing }
        dragHover = urls.prefix(16).enumerated().map { i, url in
            let item = ScaleItem(url: url)
            item.state = .hovering
            item.opacity = 1
            item.scale = 0.2
            item.y = Self.hoverHeight + 6
            item.pos = clampToPlate(p)
            item.targetPos = item.pos
            item.dropDelay = Double(i) * 0.07
            addNodes(item)
            items.append(item)
            return item
        }
        dragUpdated(at: p)
        Sound.shared.play("lift")
    }

    func dragUpdated(at p: CGPoint) {
        wake()
        let n = CGFloat(dragHover.count)
        for (i, item) in dragHover.enumerated() {
            let fan = CGFloat(i) - (n - 1) / 2
            item.targetPos = clampToPlate(CGPoint(x: p.x + fan * 5, y: p.y - fan * 4))
        }
    }

    func dragExited() {
        dragHover.forEach { $0.state = .vanishing }
        dragHover = []
        wake()
    }

    func performDrop() -> Bool {
        guard !dragHover.isEmpty else { return false }
        for item in dragHover {
            item.state = .falling
            item.vy = 0
            startMeasuring(item)
        }
        dragHover = []
        wake()
        return true
    }

    // Picking items up with the mouse
    func item(named name: String) -> ScaleItem? { items.first { $0.id == name } }

    func pick(_ item: ScaleItem, at p: CGPoint) {
        wake()
        heldItem = item
        item.state = .held
        item.landed = false
        item.targetPos = CGPoint(x: item.pos.x, y: item.pos.y)
        grabOffset = CGPoint(x: item.pos.x - p.x, y: item.pos.y - p.y)
        // Move to the end so it lands on top of the stack when dropped again
        items.removeAll { $0 === item }
        items.append(item)
        Sound.shared.play("lift")
    }

    private var grabOffset = CGPoint.zero

    func dragHeld(to p: CGPoint) {
        guard let item = heldItem else { return }
        wake()
        item.targetPos = CGPoint(x: p.x + grabOffset.x, y: p.y + grabOffset.y)
    }

    func releaseHeld() {
        guard let item = heldItem else { return }
        heldItem = nil
        wake()
        if isOverPlate(item.pos, margin: 2) {
            item.targetPos = clampToPlate(item.pos)
            item.state = .falling
            item.vy = 0
        } else {
            item.state = .leaving
            let v = item.velocity
            let len = max(1, hypot(v.x, v.y))
            let out = CGPoint(x: item.pos.x, y: item.pos.y)
            let ol = max(1, hypot(out.x, out.y))
            item.velocity = CGPoint(x: v.x / len * 60 + out.x / ol * 60, y: v.y / len * 60 + out.y / ol * 60)
            item.vy = 40
        }
    }

    func clearPlate() {
        wake()
        for item in items where item.onStack {
            item.state = .leaving
            item.vy = CGFloat.random(in: 30...80)
            let dir = CGFloat.random(in: 0...(2 * .pi))
            item.velocity = CGPoint(x: cos(dir) * 50, y: sin(dir) * 50)
        }
    }

    // MARK: - Tick

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        var dt = lastTimestamp == 0 ? 1.0 / 60 : now - lastTimestamp
        lastTimestamp = now
        dt = min(dt, 1.0 / 20)
        // Fixed sub-steps keep the springs stable at any refresh rate.
        let steps = max(1, Int(ceil(dt / (1.0 / 120))))
        for _ in 0..<steps { simulate(dt / Double(steps)) }
        syncNodes()
        renderLCD(force: false)

        if isActive { idle = 0 } else { idle += dt }
        if idle > 0.6 {
            view?.rendersContinuously = false
            link.isPaused = true
            lastTimestamp = 0
        }
    }

    private var isActive: Bool {
        if !stable || bootTimer > 0 || messageTimer > 0 { return true }
        if abs(plateVel) > 0.001 || abs(plateDip - dipTarget) > 0.002 { return true }
        if abs(backlight - (powered ? 1 : 0)) > 0.001 { return true }
        if buttonDepth.values.contains(where: { $0 > 0.001 }) || buttonHeld != nil { return true }
        if items.contains(where: { $0.state != .resting || abs($0.y - restY(for: $0)) > 0.01 }) { return true }
        if items.contains(where: { !$0.measured && $0.landed }) { return true }
        return false
    }

    private var dipTarget: CGFloat { -CGFloat(min(0.6, 0.14 * log10(1 + grossTarget))) }

    private var stackHeights: [ObjectIdentifier: Int] = [:]

    private func restY(for item: ScaleItem) -> CGFloat {
        CGFloat(stackHeights[ObjectIdentifier(item)] ?? 0) * (ScaleItem.thickness + 0.1)
    }

    private var stackTop: CGFloat {
        CGFloat(items.filter(\.onStack).count) * (ScaleItem.thickness + 0.1)
    }

    private func simulate(_ dt: Double) {
        time += dt
        let fdt = CGFloat(dt)

        // Stack order
        var idx = 0
        stackHeights.removeAll(keepingCapacity: true)
        for item in items where item.onStack {
            stackHeights[ObjectIdentifier(item)] = idx
            idx += 1
        }

        // --- Items ---
        for item in items {
            let prev = item.pos
            switch item.state {
            case .hovering, .held:
                let k = 1 - exp(-fdt * (item.state == .held ? 22 : 15))
                item.pos.x += (item.targetPos.x - item.pos.x) * k
                item.pos.y += (item.targetPos.y - item.pos.y) * k
                let base = item.state == .held ? Self.hoverHeight + stackTop * 0.5 : Self.hoverHeight + stackTop
                let bob = CGFloat(sin(time * 2.3 + item.phase)) * 0.9
                item.y += (base + bob - item.y) * (1 - exp(-fdt * 9))
                item.opacity += (1 - item.opacity) * (1 - exp(-fdt * 14))
                // springy pop-in
                item.scaleVel += (260 * (1 - item.scale) - 16 * item.scaleVel) * fdt
                item.scale += item.scaleVel * fdt
            case .falling:
                if item.dropDelay > 0 {
                    item.dropDelay -= dt
                    break
                }
                let k = 1 - exp(-fdt * 12)
                item.pos.x += (item.targetPos.x - item.pos.x) * k * 0.4
                item.pos.y += (item.targetPos.y - item.pos.y) * k * 0.4
                item.vy -= Self.gravity * fdt
                item.y += item.vy * fdt
                let rest = restY(for: item)
                if item.y <= rest {
                    item.y = rest
                    let speed = -item.vy
                    if !item.landed || item.bounces == 0 { impact(item, speed: speed) }
                    item.landed = true
                    if speed > 90 && item.bounces < 2 {
                        item.vy = speed * 0.26
                        item.bounces += 1
                    } else {
                        item.vy = 0
                        item.bounces = 0
                        item.state = .resting
                    }
                }
            case .resting:
                let rest = restY(for: item)
                if item.y > rest + 0.25 {
                    item.state = .falling // something below was removed
                    item.vy = 0
                    item.bounces = 1
                } else {
                    item.y += (rest - item.y) * (1 - exp(-fdt * 20))
                }
            case .leaving:
                item.vy -= Self.gravity * 0.6 * fdt
                item.y += item.vy * fdt
                item.pos.x += item.velocity.x * fdt
                item.pos.y += item.velocity.y * fdt
                item.opacity -= fdt * 2.6
                item.scale = max(0.6, item.scale - fdt * 0.5)
            case .vanishing:
                item.opacity -= fdt * 7
                item.scale = max(0.05, item.scale - fdt * 4)
                item.y += fdt * 10
            }
            if item.state != .leaving {
                item.velocity = CGPoint(x: (item.pos.x - prev.x) / fdt, y: (item.pos.y - prev.y) / fdt)
            }
            // Lean into motion while carried
            let lean: CGPoint = (item.state == .held || item.state == .hovering)
                ? CGPoint(x: max(-0.35, min(0.35, item.velocity.y * 0.0022)), y: max(-0.35, min(0.35, -item.velocity.x * 0.0022)))
                : .zero
            let lk = 1 - exp(-fdt * 10)
            item.tilt.x += (lean.x - item.tilt.x) * lk
            item.tilt.y += (lean.y - item.tilt.y) * lk
        }
        let gone = items.filter { ($0.state == .leaving || $0.state == .vanishing) && $0.opacity <= 0 }
        if !gone.isEmpty {
            gone.forEach { $0.teardown() }
            items.removeAll { g in gone.contains { $0 === g } }
        }

        // --- Load cell ---
        let target = grossTarget
        let K = 60.0, C = 9.5
        readingVel += (K * (target - reading) - C * readingVel) * dt
        reading += readingVel * dt
        let ref = max(abs(target), 0.05)
        let measuring = items.contains { $0.landed && !$0.measured }
        if !measuring && abs(reading - target) < ref * 0.002 + 0.0008 && abs(readingVel) < ref * 0.03 + 0.004 {
            settleTime += dt
        } else {
            settleTime = 0
            stable = false
        }
        if settleTime > 0.32 && !stable {
            stable = true
            reading = target
            readingVel = 0
            shownGross = target
        }

        // --- Platform deflection ---
        plateVel += (260 * (dipTarget - plateDip) - 15 * plateVel) * fdt
        plateDip += plateVel * fdt

        // --- Backlight / boot ---
        let blTarget: CGFloat = powered ? 1 : 0
        backlight += (blTarget - backlight) * (1 - exp(-fdt * (powered ? 18 : 10)))
        if abs(backlight - blTarget) < 0.002 { backlight = blTarget }
        if bootTimer > 0 { bootTimer -= dt }
        if messageTimer > 0 { messageTimer -= dt; if messageTimer <= 0 { message = nil } }

        // --- Buttons ---
        for id in ButtonID.allCases {
            let target: CGFloat = buttonHeld == id ? 1 : 0
            let speed: CGFloat = target > buttonDepth[id]! ? 40 : 22
            buttonDepth[id]! += (target - buttonDepth[id]!) * (1 - exp(-fdt * speed))
        }

        // --- Displayed value (LCDs refresh a few times a second) ---
        displayClock += dt
        if !stable && displayClock > 0.09 {
            displayClock = 0
            let res = resolutionGrams(for: reading - tareGrams)
            shownGross = reading + Double.random(in: -1...1) * res * 0.9
        } else if stable {
            shownGross = target
        }
    }

    private func impact(_ item: ScaleItem, speed: CGFloat) {
        let mass = CGFloat(min(1.0, 0.25 + log10(1 + item.grams) * 0.2))
        plateVel -= speed * 0.012 * mass
        // A falling object momentarily reads heavier – overshoot proportional to impact
        readingVel += max(item.grams, 0.05) * Double(speed) / 90
        let vol = Float(min(1, 0.25 + speed / 500))
        Sound.shared.play("tap", volume: vol * 0.6)
    }

    // MARK: - Node sync

    private func syncNodes() {
        world.plateGroup.position.y = plateDip
        let planeY = world.plateTopNode.convertPosition(SCNVector3Zero, to: nil).y
        let rect = NSValue(scnVector4: SCNVector4(-Dim.plateW / 2, Dim.plateZ - Dim.plateL / 2,
                                                  Dim.plateW / 2, Dim.plateZ + Dim.plateL / 2))
        let top = stackTop
        for item in items {
            let n = item.node
            n.position = SCNVector3(item.pos.x, item.y, item.pos.y)
            n.eulerAngles = SCNVector3(item.tilt.x, item.yaw, item.tilt.y)
            n.scale = SCNVector3(item.scale, item.scale, item.scale)
            n.opacity = max(0, item.opacity)
            item.reflection.transform = n.transform
            item.reflection.opacity = n.opacity
            item.reflectionMaterial.setValue(NSNumber(value: Double(planeY)), forKey: "planeY")
            item.reflectionMaterial.setValue(rect, forKey: "plateRect")

            // Contact shadow on whatever surface is below
            let surface: CGFloat
            if item.onStack { surface = restY(for: item) } else { surface = top }
            let h = max(0, item.y - surface)
            let over = isOverPlate(item.pos, margin: -2) ? 1.0 : max(0, 1 - (outsideDistance(item.pos) / 8))
            item.shadow.position = SCNVector3(item.pos.x + 0.6 + h * 0.08, surface + 0.04, item.pos.y - 0.4 - h * 0.05)
            item.shadow.eulerAngles = SCNVector3(0, item.yaw, 0)
            let s = (1 + h * 0.014) * item.scale
            item.shadow.scale = SCNVector3(s, 1, s)
            item.shadow.opacity = max(0, item.opacity) * max(0.18, 0.9 - h * 0.026) * over
        }
        for id in ButtonID.allCases {
            guard let node = world.buttons[id], let rest = world.buttonRest[id] else { continue }
            node.position = SCNVector3(rest.x, rest.y - buttonDepth[id]! * 0.85, rest.z)
        }
    }

    private func outsideDistance(_ p: CGPoint) -> CGFloat {
        let dx = max(0, abs(p.x) - Self.plateHalf.width)
        let dz = max(0, abs(p.y) - Self.plateHalf.height)
        return hypot(dx, dz)
    }

    // MARK: - LCD

    private func decimals(for value: Double) -> Int? {
        let a = abs(value)
        if a < 99.9995 { return 3 }
        if a < 999.995 { return 2 }
        if a < 9999.95 { return 1 }
        if a < 99999.5 { return 0 }
        return nil
    }

    private func resolutionGrams(for netGrams: Double) -> Double {
        let unit = Units.all[unitIndex]
        let dec = decimals(for: netGrams * unit.perGram) ?? 0
        return pow(10, -Double(dec)) / unit.perGram
    }

    private func lcdState() -> LCDState {
        var s = LCDState()
        s.backlight = (backlight * 24).rounded() / 24
        if !powered && backlight < 0.01 { return .off }
        if powered && bootTimer > 0 {
            s.allOn = bootTimer > 0.35
            if !s.allOn {
                s.cells = Array("-----").map { LCDState.Cell(char: $0) }
                s.unit = nil
            }
            return s
        }
        s.unit = pcsMode ? nil : unitIndex
        s.pcs = pcsMode
        s.stable = stable
        s.net = tareGrams != 0 || tareCount != 0

        if pcsMode {
            let net = countTarget - tareCount
            let text = String(abs(net))
            if text.count > 5 {
                s.cells = Array(" -OL-").map { LCDState.Cell(char: $0) }
                return s
            }
            s.cells = Array(String(repeating: " ", count: 5 - text.count) + text).map { LCDState.Cell(char: $0) }
            s.minus = net < 0
            s.zero = net == 0
            return s
        }

        let unit = Units.all[unitIndex]
        let value = (shownGross - tareGrams) * unit.perGram
        guard let dec = decimals(for: value) else {
            s.cells = Array(" -OL-").map { LCDState.Cell(char: $0) }
            return s
        }
        let factor = pow(10, Double(dec))
        let rounded = (abs(value) * factor).rounded() / factor
        var text = String(format: "%.\(dec)f", rounded)
        var dotIndex: Int? = nil
        if let d = text.firstIndex(of: ".") {
            dotIndex = text.distance(from: text.startIndex, to: d) - 1
            text.remove(at: d)
        }
        let pad = 5 - text.count
        guard pad >= 0 else {
            s.cells = Array(" -OL-").map { LCDState.Cell(char: $0) }
            return s
        }
        var cells = Array(String(repeating: " ", count: pad) + text).map { LCDState.Cell(char: $0) }
        if let di = dotIndex { cells[di + pad].dot = true }
        s.cells = cells
        s.minus = value < 0 && rounded > 0
        s.zero = rounded == 0
        return s
    }

    private func renderLCD(force: Bool) {
        let s = lcdState()
        if !force, let last = lastLCD, last == s { return }
        lastLCD = s
        world.setLCD(LCDRenderer.render(s))
    }
}
