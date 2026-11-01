import AppKit
import SceneKit
import Metal

/// Offscreen rendering for design iteration: `DigitalScale --snapshot out.png [--az r] [--el r] [files...]`
enum Snapshot {
    static func run(args: [String]) {
        var out = "snapshot.png"
        var az: CGFloat? = nil, el: CGFloat? = nil
        var files: [String] = []
        var bg = true
        var size = CGSize(width: 1520, height: 1280)
        var dist: CGFloat? = nil
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--snapshot": out = args[i + 1]; i += 1
            case "--az": az = CGFloat(Double(args[i + 1])!); i += 1
            case "--el": el = CGFloat(Double(args[i + 1])!); i += 1
            case "--nobg": bg = false
            case "--size": size = CGSize(width: Double(args[i + 1])!, height: Double(args[i + 1])!); i += 1
            case "--dist": dist = CGFloat(Double(args[i + 1])!); i += 1
            default: if !args[i].hasPrefix("-") { files.append(args[i]) }
            }
            i += 1
        }
        let controller = ScaleController(snapshotMode: true)
        if let az { controller.world.cameraAzimuth = az }
        if let el { controller.world.cameraElevation = el }
        if let dist { controller.world.cameraDistance = dist }
        controller.world.updateCamera()
        controller.prepareSnapshot(files: files.map { URL(fileURLWithPath: $0) })

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = controller.world.scene
        renderer.pointOfView = controller.world.cameraNode
        renderer.autoenablesDefaultLighting = false
        let img = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        let final = NSImage(size: size)
        final.lockFocus()
        if bg {
            let g = NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.33, blue: 0.52, alpha: 1),
                               ending: NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.55, alpha: 1))!
            g.draw(in: NSRect(origin: .zero, size: size), angle: -60)
        }
        img.draw(in: NSRect(origin: .zero, size: size))
        final.unlockFocus()
        let rep = NSBitmapImageRep(data: final.tiffRepresentation!)!
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }
}
