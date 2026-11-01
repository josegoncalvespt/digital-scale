import AppKit
import SceneKit

/// Physical dimensions in millimetres. The scene uses 1 unit = 1 mm.
enum Dim {
    static let bodyW: CGFloat = 66
    static let bodyL: CGFloat = 118
    static let bodyR: CGFloat = 10
    static let bodyTop: CGFloat = 14

    static let plateW: CGFloat = 58
    static let plateL: CGFloat = 66
    static let plateR: CGFloat = 3.5
    static let plateZ: CGFloat = -22          // centre of the weighing platform
    static let plateBottom: CGFloat = 15.6
    static let plateThick: CGFloat = 2.6
    static var plateTop: CGFloat { plateBottom + plateThick }

    static let lcdZ: CGFloat = 28.5
    static let buttonZ: CGFloat = 50.5
}

enum ButtonID: String, CaseIterable { case tare, unit, pcs, power }

final class ScaleScene {
    let scene = SCNScene()
    let root = SCNNode()
    let cameraNode = SCNNode()

    /// Everything that moves when the load cell deflects.
    let plateGroup = SCNNode()
    let itemsRoot = SCNNode()
    let reflectionRoot = SCNNode()
    let shadowsRoot = SCNNode()
    let plateTopNode = SCNNode()

    var buttons: [ButtonID: SCNNode] = [:]
    var buttonRest: [ButtonID: SCNVector3] = [:]
    let lcdMaterial = SCNMaterial()
    let groundShadow = SCNNode()

    static let interactiveMask = 1 << 1
    static let itemMask = 1 << 2
    static let decorMask = 1 << 3
    static let noHitMask = 1 << 8

    init() {
        scene.background.contents = nil
        let env = Textures.studioEnvironment()
        scene.lightingEnvironment.contents = env
        scene.lightingEnvironment.intensity = 1.55
        scene.rootNode.addChildNode(root)

        buildBody()
        buildPlatform()
        buildDisplay()
        buildButtons()
        buildGroundShadow()
        buildLights()
        buildCamera()
    }

    // MARK: - Materials

    static func chrome() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(white: 0.96, alpha: 1)
        m.metalness.contents = 1.0
        m.roughness.contents = 0.07
        return m
    }

    static func satinSteel() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        let brushed = Textures.brushedSteel(base: 0.80, contrast: 0.09)
        m.diffuse.contents = brushed
        m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        m.metalness.contents = 1.0
        m.roughness.contents = 0.2
        return m
    }

    static func glossBlack(_ base: CGFloat = 0.012, roughness: CGFloat = 0.32) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(white: base, alpha: 1)
        m.metalness.contents = 0.0
        m.roughness.contents = roughness
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.04
        return m
    }

    /// Glossy black with a controlled reflection strength (PBR dielectrics reflect too much of a bright studio).
    static func pianoBlack(env: Any?, reflect: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = NSColor(white: 0.01, alpha: 1)
        m.specular.contents = NSColor(white: 0.5, alpha: 1)
        m.shininess = 0.9
        m.reflective.contents = env
        m.reflective.intensity = reflect
        m.fresnelExponent = 1.6
        return m
    }

    static func matte(_ white: CGFloat, roughness: CGFloat = 0.8) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(white: white, alpha: 1)
        m.metalness.contents = 0.0
        m.roughness.contents = roughness
        return m
    }

    // MARK: - Geometry helpers

    static let roundProfile: NSBezierPath = {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: 1))
        // Quarter circle bulging outward
        p.curve(to: NSPoint(x: 1, y: 0), controlPoint1: NSPoint(x: 0.552, y: 1), controlPoint2: NSPoint(x: 1, y: 0.552))
        return p
    }()

    static func rrect(_ w: CGFloat, _ l: CGFloat, _ r: CGFloat) -> NSBezierPath {
        let p = NSBezierPath(roundedRect: NSRect(x: -w / 2, y: -l / 2, width: w, height: l), xRadius: r, yRadius: r)
        p.flatness = 0.03
        return p
    }

    /// Extruded slab lying flat. Origin of the returned node is at the slab's bottom centre.
    static func slab(_ path: NSBezierPath, height: CGFloat, chamfer: CGFloat = 0, mode: SCNChamferMode = .front,
                     materials: [SCNMaterial]) -> SCNNode {
        let s = SCNShape(path: path, extrusionDepth: height)
        s.chamferRadius = chamfer
        s.chamferMode = mode
        if chamfer > 0 { s.chamferProfile = roundProfile }
        s.materials = materials
        let n = SCNNode(geometry: s)
        n.eulerAngles.x = -.pi / 2
        n.position.y = height / 2
        let c = SCNNode()
        c.addChildNode(n)
        return c
    }

    static func flatPlane(_ w: CGFloat, _ l: CGFloat, material: SCNMaterial) -> SCNNode {
        let p = SCNPlane(width: w, height: l)
        p.materials = [material]
        let n = SCNNode(geometry: p)
        n.eulerAngles.x = -.pi / 2
        return n
    }

    // MARK: - Body

    private func buildBody() {
        let chrome = Self.chrome()
        let dark = Self.matte(0.02, roughness: 0.5)

        // Rubber foot plate
        let base = Self.slab(Self.rrect(Dim.bodyW - 4, Dim.bodyL - 4, Dim.bodyR - 2), height: 2.4, chamfer: 0.8,
                             mode: .both, materials: [Self.matte(0.03, roughness: 0.7)])
        base.position.y = 0
        root.addChildNode(base)

        // Lower chrome shell (rounded bottom edge)
        let lower = Self.slab(Self.rrect(Dim.bodyW, Dim.bodyL, Dim.bodyR), height: 6.8, chamfer: 2.2, mode: .back,
                              materials: [chrome])
        lower.position.y = 1.4
        root.addChildNode(lower)

        // Lid-rail groove: a dark recessed band around the body
        let groove = Self.slab(Self.rrect(Dim.bodyW - 1.1, Dim.bodyL - 1.1, Dim.bodyR - 0.55), height: 0.9,
                               materials: [dark])
        groove.position.y = 8.2
        root.addChildNode(groove)

        // Upper chrome shell (rounded top edge, slightly rounded bottom edge to read as a separate part)
        let upper = Self.slab(Self.rrect(Dim.bodyW, Dim.bodyL, Dim.bodyR), height: Dim.bodyTop - 9.1, chamfer: 2.4,
                              mode: .front, materials: [chrome])
        upper.position.y = 9.1
        root.addChildNode(upper)

        // Thin raised lip just inside the outer edge – catches a crisp highlight like the real part.
        let ring = NSBezierPath()
        ring.append(Self.rrect(Dim.bodyW - 5.0, Dim.bodyL - 5.0, Dim.bodyR - 2.5))
        ring.append(Self.rrect(Dim.bodyW - 7.4, Dim.bodyL - 7.4, Dim.bodyR - 3.7).reversed)
        ring.windingRule = .evenOdd
        ring.flatness = 0.03
        let lip = Self.slab(ring, height: 0.45, chamfer: 0.2, mode: .front, materials: [chrome])
        lip.position.y = Dim.bodyTop - 0.05
        root.addChildNode(lip)

        [base, lower, groove, upper, lip].forEach { $0.categoryBitMask = Self.decorMask }
        root.enumerateChildNodes { n, _ in n.categoryBitMask = Self.decorMask }
    }

    // MARK: - Platform

    private func buildPlatform() {
        // Dark well beneath the plate: shows as a shadow gap between plate and body.
        let wellMat = Self.matte(0.01, roughness: 0.9)
        let well = Self.slab(Self.rrect(Dim.plateW + 2.4, Dim.plateL + 2.4, Dim.plateR + 1.2), height: 0.25,
                             materials: [wellMat])
        well.position = SCNVector3(0, Dim.bodyTop + 0.02, Dim.plateZ)
        well.categoryBitMask = Self.decorMask
        root.addChildNode(well)
        // Soft ambient-occlusion halo around the plate on the chrome
        let aoTex = Textures.roundedShadow(aspect: (Dim.plateW + 12) / (Dim.plateL + 12), radiusFrac: 0.08, blur: 14, pad: 0.07, alpha: 0.55)
        let aoMat = SCNMaterial()
        aoMat.lightingModel = .constant
        aoMat.diffuse.contents = aoTex
        aoMat.writesToDepthBuffer = false
        let ao = Self.flatPlane(Dim.plateW + 12, Dim.plateL + 12, material: aoMat)
        ao.position = SCNVector3(0, Dim.bodyTop + 0.012, Dim.plateZ)
        ao.renderingOrder = 1
        root.addChildNode(ao)

        plateGroup.position = SCNVector3(0, 0, 0)
        root.addChildNode(plateGroup)

        // Support post (barely visible through the gap)
        let post = SCNNode(geometry: SCNCylinder(radius: 6, height: 2))
        post.geometry?.materials = [Self.matte(0.05)]
        post.position = SCNVector3(0, Dim.bodyTop + 0.8, Dim.plateZ)
        plateGroup.addChildNode(post)

        let steel = Self.satinSteel()
        let edge = Self.chrome()
        edge.roughness.contents = 0.16
        let plate = Self.slab(Self.rrect(Dim.plateW, Dim.plateL, Dim.plateR), height: Dim.plateThick, chamfer: 0.8,
                              mode: .front, materials: [steel, edge, edge, edge, edge])
        plate.position = SCNVector3(0, Dim.plateBottom, Dim.plateZ)
        plate.categoryBitMask = Self.interactiveMask
        plate.enumerateChildNodes { n, _ in n.categoryBitMask = Self.interactiveMask }
        plate.name = "plate"
        plateGroup.addChildNode(plate)

        plateTopNode.position = SCNVector3(0, Dim.plateTop, Dim.plateZ)
        plateGroup.addChildNode(plateTopNode)

        // Items, their reflections and contact shadows live in plate-top space.
        reflectionRoot.position = plateTopNode.position
        reflectionRoot.scale = SCNVector3(1, -1, 1)
        shadowsRoot.position = plateTopNode.position
        itemsRoot.position = plateTopNode.position
        plateGroup.addChildNode(reflectionRoot)
        plateGroup.addChildNode(shadowsRoot)
        plateGroup.addChildNode(itemsRoot)
    }

    // MARK: - Display

    private func buildDisplay() {
        let bezelMat = Self.pianoBlack(env: scene.lightingEnvironment.contents, reflect: 0.16)
        let bezel = Self.slab(Self.rrect(57, 27, 4.2), height: 0.9, chamfer: 0.45, mode: .front,
                              materials: [bezelMat])
        bezel.position = SCNVector3(0, Dim.bodyTop - 0.1, Dim.lcdZ)
        root.addChildNode(bezel)

        lcdMaterial.lightingModel = .physicallyBased
        lcdMaterial.diffuse.contents = NSColor(white: 0.0, alpha: 1)
        lcdMaterial.emission.contents = LCDRenderer.render(.off)
        lcdMaterial.metalness.contents = 0.0
        lcdMaterial.roughness.contents = 0.12
        lcdMaterial.clearCoat.contents = 1.0
        lcdMaterial.clearCoatRoughness.contents = 0.02
        let lcd = Self.flatPlane(50, 50 * CGFloat(LCDRenderer.height) / CGFloat(LCDRenderer.width), material: lcdMaterial)
        lcd.position = SCNVector3(0, Dim.bodyTop + 0.82, Dim.lcdZ - 0.4)
        root.addChildNode(lcd)

        // Inner shadow of the bezel cast onto the LCD glass edges
        let innerTex = Textures.draw(1000, 380) { ctx in
            let r = CGRect(x: 0, y: 0, width: 1000, height: 380)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addRect(r.insetBy(dx: -200, dy: -200))
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 6, dy: 6), cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath(using: .evenOdd)
        }
        let innerMat = SCNMaterial()
        innerMat.lightingModel = .constant
        innerMat.diffuse.contents = Textures.softBlur(innerTex, radius: 9)
        innerMat.writesToDepthBuffer = false
        let inner = Self.flatPlane(50.2, 50.2 * 380 / 1000, material: innerMat)
        inner.position = SCNVector3(0, Dim.bodyTop + 0.84, Dim.lcdZ - 0.4)
        inner.renderingOrder = 2
        root.addChildNode(inner)
    }

    func setLCD(_ image: CGImage) {
        lcdMaterial.emission.contents = image
    }

    // MARK: - Buttons

    private func buildButtons() {
        let order: [ButtonID] = [.tare, .unit, .pcs, .power]
        let w: CGFloat = 12.4, l: CGFloat = 7.8
        for (i, id) in order.enumerated() {
            let x = -21 + CGFloat(i) * 14
            // Gap well around the key
            let well = Self.slab(Self.rrect(w + 1.0, l + 1.0, 2.8), height: 0.1, materials: [Self.matte(0.01, roughness: 0.9)])
            well.position = SCNVector3(x, Dim.bodyTop + 0.01, Dim.buttonZ)
            root.addChildNode(well)

            let mat = Self.glossBlack(0.018, roughness: 0.38)
            let key = Self.slab(Self.rrect(w, l, 2.4), height: 2.3, chamfer: 1.05, mode: .front, materials: [mat])
            key.position = SCNVector3(x, Dim.bodyTop - 0.2, Dim.buttonZ)
            key.name = "button:" + id.rawValue
            key.categoryBitMask = Self.interactiveMask
            key.enumerateChildNodes { n, _ in
                n.categoryBitMask = Self.interactiveMask
                n.name = "button:" + id.rawValue
            }

            let legendMat = SCNMaterial()
            legendMat.lightingModel = .constant
            legendMat.diffuse.contents = Textures.buttonLegend(id == .power ? nil : id.rawValue.uppercased(), power: id == .power)
            legendMat.writesToDepthBuffer = false
            legendMat.transparencyMode = .aOne
            let legend = Self.flatPlane(w - 2.6, (w - 2.6) * 320 / 520, material: legendMat)
            legend.position = SCNVector3(0, 2.32, 0)
            legend.renderingOrder = 5
            legend.name = "button:" + id.rawValue
            legend.categoryBitMask = Self.interactiveMask
            key.addChildNode(legend)

            root.addChildNode(key)
            buttons[id] = key
            buttonRest[id] = key.position
        }
    }

    // MARK: - Shadow on the desktop

    private func buildGroundShadow() {
        let w = Dim.bodyW * 1.9, l = Dim.bodyL * 1.45
        let tex = Textures.roundedShadow(aspect: w / l, radiusFrac: 0.2, blur: 34, pad: 0.2, alpha: 0.62)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = tex
        m.writesToDepthBuffer = false
        groundShadow.geometry = SCNPlane(width: w, height: l)
        groundShadow.geometry?.materials = [m]
        groundShadow.eulerAngles.x = -.pi / 2
        groundShadow.position = SCNVector3(4, -10, 3)
        groundShadow.renderingOrder = -10
        groundShadow.categoryBitMask = Self.noHitMask
        root.addChildNode(groundShadow)
    }

    // MARK: - Lights & camera

    private func buildLights() {
        let key = SCNLight()
        key.type = .directional
        key.intensity = 450
        key.color = NSColor(white: 1, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-1.05, 0.5, 0)
        scene.rootNode.addChildNode(keyNode)
    }

    var cameraAzimuth: CGFloat = 0.62   // radians, around Y
    var cameraElevation: CGFloat = 0.74 // radians above horizon
    var cameraDistance: CGFloat = 370

    private func buildCamera() {
        let cam = SCNCamera()
        cam.fieldOfView = 24
        cam.zNear = 20
        cam.zFar = 3000
        cam.wantsHDR = false
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        updateCamera()
    }

    func updateCamera() {
        let target = SCNVector3(0, 6, 0)
        let d = cameraDistance
        cameraNode.position = SCNVector3(
            target.x + d * cos(cameraElevation) * sin(cameraAzimuth),
            target.y + d * sin(cameraElevation),
            target.z + d * cos(cameraElevation) * cos(cameraAzimuth))
        cameraNode.look(at: target, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
    }
}
