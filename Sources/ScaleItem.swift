import AppKit
import SceneKit
import QuickLookThumbnailing

/// A file (or folder) sitting on the scale, represented as a small physical tile cut
/// out of its Finder icon. The tile has real thickness (stacked icon layers), a
/// contact shadow, and a planar reflection in the satin platform.
final class ScaleItem {
    enum State { case hovering, held, falling, resting, leaving, vanishing }

    static let size: CGFloat = 40
    static let thickness: CGFloat = 2.2
    static let layerCount = 18

    let id = UUID().uuidString
    let url: URL
    var bytes: Int64 = 0
    var fileCount = 0
    var measured = false
    var job: FileWeigher.Job?

    let node = SCNNode()
    let reflection = SCNNode()
    let shadow = SCNNode()

    private let topMaterial = SCNMaterial()
    private let edgeMaterial = SCNMaterial()
    let reflectionMaterial = SCNMaterial()
    private let shadowMaterial = SCNMaterial()

    // Motion state (plate-top coordinates, millimetres)
    var pos = CGPoint.zero          // x, z
    var targetPos = CGPoint.zero
    var y: CGFloat = 26
    var vy: CGFloat = 0
    var yaw: CGFloat = 0
    var tilt = CGPoint.zero
    var velocity = CGPoint.zero
    var state: State = .hovering
    var landed = false
    var opacity: CGFloat = 1
    var scale: CGFloat = 1
    var scaleVel: CGFloat = 0
    var dropDelay: Double = 0
    let phase = Double.random(in: 0...(2 * .pi))
    var bounces = 0

    var countsTowardWeight: Bool { landed && (state == .falling || state == .resting) }
    var onStack: Bool { state == .falling || state == .resting }
    var grams: Double { Double(bytes) / 1_000_000 }

    init(url: URL) {
        self.url = url
        yaw = CGFloat.random(in: -0.22...0.22)
        build()
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 512, height: 512)
        apply(image: Textures.cgImage(from: icon, size: 512))
        loadThumbnail()
    }

    // MARK: - Nodes

    private static let alphaTest = """
    #pragma body
    float a = _surface.diffuse.a;
    if (a < 0.5) { discard_fragment(); }
    _surface.diffuse = float4(_surface.diffuse.rgb / max(a, 0.001), 1.0);
    """

    static let reflectionShader = """
    #pragma arguments
    float planeY;
    float4 plateRect;
    float reflStrength;

    #pragma body
    float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 cam = (scn_frame.inverseViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float3 d = wp - cam;
    float t = (planeY - cam.y) / d.y;
    float3 hit = cam + d * t;
    float2 c = float2(plateRect.x + plateRect.z, plateRect.y + plateRect.w) * 0.5;
    float2 hs = float2(plateRect.z - plateRect.x, plateRect.w - plateRect.y) * 0.5;
    float r = 3.2;
    float2 q = abs(hit.xz - c) - (hs - r);
    float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    if (sdf > 0.0) { discard_fragment(); }
    float depth = max(planeY - wp.y, 0.0);
    float fade = exp(-depth / 34.0);
    float edge = clamp(-sdf / 1.0, 0.0, 1.0);
    _output.color *= reflStrength * fade * edge;
    """

    private func build() {
        let S = Self.size
        for m in [topMaterial, edgeMaterial] {
            m.lightingModel = .physicallyBased
            m.metalness.contents = 0.0
            m.shaderModifiers = [.surface: Self.alphaTest]
            m.isDoubleSided = false
        }
        topMaterial.roughness.contents = 0.38
        topMaterial.clearCoat.contents = 0.55
        topMaterial.clearCoatRoughness.contents = 0.1
        edgeMaterial.roughness.contents = 0.6

        let tile = SCNNode()
        for i in 0..<Self.layerCount {
            let isTop = i == Self.layerCount - 1
            let plane = SCNPlane(width: S, height: S)
            plane.materials = [isTop ? topMaterial : edgeMaterial]
            let layer = SCNNode(geometry: plane)
            layer.eulerAngles.x = -.pi / 2
            layer.position.y = Self.thickness * CGFloat(i) / CGFloat(Self.layerCount - 1)
            layer.name = id
            layer.categoryBitMask = ScaleScene.itemMask
            layer.renderingOrder = 30
            tile.addChildNode(layer)
        }
        node.addChildNode(tile)

        // Reflection: a single blurred plane at the underside of the tile.
        reflectionMaterial.lightingModel = .constant
        reflectionMaterial.multiply.contents = NSColor(red: 0.80, green: 0.83, blue: 0.88, alpha: 1)
        reflectionMaterial.writesToDepthBuffer = false
        reflectionMaterial.readsFromDepthBuffer = false
        reflectionMaterial.isDoubleSided = true
        reflectionMaterial.shaderModifiers = [.fragment: Self.reflectionShader]
        reflectionMaterial.setValue(NSNumber(value: 0.62), forKey: "reflStrength")
        let rp = SCNPlane(width: S, height: S)
        rp.materials = [reflectionMaterial]
        let rnode = SCNNode(geometry: rp)
        rnode.eulerAngles.x = -.pi / 2
        rnode.renderingOrder = 10
        rnode.categoryBitMask = ScaleScene.noHitMask // never hit-tested
        reflection.addChildNode(rnode)

        // Contact shadow
        shadowMaterial.lightingModel = .constant
        shadowMaterial.writesToDepthBuffer = false
        let sp = SCNPlane(width: S * 1.4, height: S * 1.4)
        sp.materials = [shadowMaterial]
        let snode = SCNNode(geometry: sp)
        snode.eulerAngles.x = -.pi / 2
        snode.renderingOrder = 20
        snode.categoryBitMask = ScaleScene.noHitMask
        shadow.addChildNode(snode)
    }

    private func apply(image: CGImage) {
        let edge = Textures.darkened(image, factor: 0.5, desaturate: 0.25)
        let small = Textures.cgImage(from: NSImage(cgImage: image, size: NSSize(width: 256, height: 256)), size: 256)
        let refl = Textures.softBlur(small, radius: 3.0)
        // Shadow texture is 1.4× the tile; pad accordingly (256 * 0.2 = ~51px each side)
        let shadowTex = Textures.silhouetteShadow(small, blur: 9, pad: 51)
        topMaterial.diffuse.contents = image
        edgeMaterial.diffuse.contents = edge
        reflectionMaterial.diffuse.contents = refl
        shadowMaterial.diffuse.contents = shadowTex
    }

    /// Finder-style preview (real thumbnails for images, PDFs, etc.)
    private func loadThumbnail() {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 256, height: 256), scale: 2,
                                               representationTypes: .thumbnail)
        req.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let self, let cg = rep?.cgImage else { return }
            // Re-render into a square 512 canvas, centred, preserving aspect.
            let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let square = Textures.draw(512, 512, flipped: false) { _ in
                let s = 512 / CGFloat(max(cg.width, cg.height))
                let w = CGFloat(cg.width) * s, h = CGFloat(cg.height) * s
                ns.draw(in: NSRect(x: (512 - w) / 2, y: (512 - h) / 2, width: w, height: h))
            }
            DispatchQueue.main.async { self.apply(image: square) }
        }
    }

    func teardown() {
        job?.cancelled = true
        node.removeFromParentNode()
        reflection.removeFromParentNode()
        shadow.removeFromParentNode()
    }
}

// MARK: - Measuring

enum FileWeigher {
    final class Job { var cancelled = false }
    private static let queue = DispatchQueue(label: "scale.weigher", qos: .userInitiated, attributes: .concurrent)

    /// Measures a file or folder (recursively). Reports progress on the main queue.
    static func weigh(_ url: URL, progress: @escaping (_ bytes: Int64, _ files: Int, _ done: Bool) -> Void) -> Job {
        let job = Job()
        queue.async {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey, .totalFileSizeKey]
            var total: Int64 = 0
            var count = 0
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                       errorHandler: { _, _ in true })
                var n = 0
                var last = CFAbsoluteTimeGetCurrent()
                while let f = e?.nextObject() as? URL {
                    if job.cancelled { return }
                    if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true {
                        total += Int64(v.totalFileSize ?? v.fileSize ?? 0)
                        count += 1
                    }
                    n += 1
                    if n % 256 == 0 {
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - last > 0.06 {
                            last = now
                            let t = total, c = count
                            DispatchQueue.main.async { if !job.cancelled { progress(t, c, false) } }
                        }
                    }
                }
            } else {
                total = Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
                count = 1
            }
            let t = total, c = count
            DispatchQueue.main.async { if !job.cancelled { progress(t, c, true) } }
        }
        return job
    }
}
