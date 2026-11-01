import AppKit
import CoreImage

/// Procedurally generated textures. Everything the scale needs is painted in code
/// so the app ships without image assets.
enum Textures {

    // MARK: - Bitmap helpers

    static func makeContext(_ w: Int, _ h: Int) -> CGContext {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        return ctx
    }

    /// Draw with a top-left origin coordinate system (like UIKit) – easier for layouts.
    static func draw(_ w: Int, _ h: Int, flipped: Bool = true, _ body: (CGContext) -> Void) -> CGImage {
        let ctx = makeContext(w, h)
        if flipped {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: flipped)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static func blur(_ image: CGImage, radius: Double) -> CGImage {
        let input = CIImage(cgImage: image)
        let out = input.clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: input.extent)
        return ciContext.createCGImage(out, from: input.extent)!
    }

    /// Blur that lets transparent edges stay transparent (no clamping).
    static func softBlur(_ image: CGImage, radius: Double) -> CGImage {
        let input = CIImage(cgImage: image)
        let out = input.applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        return ciContext.createCGImage(out, from: input.extent)!
    }

    // MARK: - Studio environment (equirectangular)

    /// A photographic-studio style environment: bright soft boxes, a light ceiling, dark flags
    /// and a dark floor. Chrome reflects this, so the contrast here *is* the look of the metal.
    static func studioEnvironment() -> CGImage {
        let W = 2048, H = 1024
        let img = draw(W, H) { ctx in
            // Vertical gradient: ceiling → horizon → floor.
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let stops: [(CGFloat, CGFloat)] = [
                (0.00, 0.80), (0.25, 0.74), (0.42, 0.56), (0.49, 0.40),
                (0.50, 0.12), (0.54, 0.16), (0.58, 0.80), (0.66, 0.92), (0.72, 0.42),
                (0.80, 0.22), (0.90, 0.34), (1.00, 0.40),
            ]
            let colors = stops.map { CGColor(gray: $0.1, alpha: 1) } as CFArray
            let locs = stops.map { $0.0 }
            let grad = CGGradient(colorsSpace: cs, colors: colors, locations: locs)!
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: H), options: [])

            // Helpers in (azimuth°, elevation°) space. x = az/360*W, y = (90-el)/180*H
            func rect(az: CGFloat, el: CGFloat, w: CGFloat, h: CGFloat, gray: CGFloat, alpha: CGFloat = 1, radius: CGFloat = 6) {
                let cx = az / 360 * CGFloat(W), cy = (90 - el) / 180 * CGFloat(H)
                let rw = w / 360 * CGFloat(W), rh = h / 180 * CGFloat(H)
                for dx in [-CGFloat(W), 0, CGFloat(W)] { // wrap-around
                    let r = CGRect(x: cx - rw / 2 + dx, y: cy - rh / 2, width: rw, height: rh)
                    ctx.setFillColor(CGColor(gray: gray, alpha: alpha))
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, rw / 2), cornerHeight: min(radius, rh / 2), transform: nil))
                    ctx.fillPath()
                }
            }
            // Big overhead softbox (gives the bright top faces)
            rect(az: 180, el: 70, w: 360, h: 40, gray: 0.97)
            rect(az: 30, el: 62, w: 70, h: 26, gray: 1.0)
            rect(az: 210, el: 55, w: 80, h: 30, gray: 1.0)
            // Strip lights around the horizon (these become the crisp streaks on the chrome sides)
            rect(az: 90, el: 18, w: 24, h: 34, gray: 1.0)
            rect(az: 128, el: 12, w: 10, h: 20, gray: 0.92)
            rect(az: 270, el: 20, w: 34, h: 38, gray: 1.0)
            rect(az: 330, el: 16, w: 16, h: 26, gray: 0.95)
            rect(az: 0, el: 30, w: 30, h: 18, gray: 0.9)
            // Black flags (give chrome its deep contrast bands)
            rect(az: 50, el: 20, w: 26, h: 50, gray: 0.06)
            rect(az: 160, el: 22, w: 34, h: 46, gray: 0.08)
            rect(az: 235, el: 14, w: 18, h: 30, gray: 0.10)
            rect(az: 300, el: 30, w: 14, h: 40, gray: 0.12)
            // Thin bright horizon line (table edge bounce)
            rect(az: 180, el: 1.5, w: 360, h: 2.0, gray: 0.85, radius: 0)
            // Floor bounce card
            rect(az: 110, el: -30, w: 40, h: 16, gray: 0.20)
            rect(az: 290, el: -24, w: 30, h: 14, gray: 0.25)
            rect(az: 20, el: -40, w: 50, h: 10, gray: 0.35)
        }
        return blur(img, radius: 3.5)
    }

    // MARK: - Brushed steel

    static func brushedSteel(size: Int = 1024, base: CGFloat = 0.78, contrast: CGFloat = 0.10) -> CGImage {
        // Rows of random brightness, stretched horizontally → long brushing streaks.
        var rng = SystemRandomNumberGenerator()
        let raw = draw(size, size, flipped: false) { ctx in
            ctx.setFillColor(CGColor(gray: base, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            for _ in 0..<5000 {
                let y = CGFloat(Int.random(in: 0..<size, using: &rng))
                let x = CGFloat(Int.random(in: -size..<size, using: &rng))
                let len = CGFloat.random(in: 80...1400, using: &rng)
                let g = base + CGFloat.random(in: -contrast...contrast, using: &rng)
                ctx.setFillColor(CGColor(gray: max(0, min(1, g)), alpha: CGFloat.random(in: 0.15...0.5, using: &rng)))
                ctx.fill(CGRect(x: x, y: y, width: len, height: CGFloat.random(in: 0.6...1.6, using: &rng)))
            }
        }
        // Slight horizontal blur to merge the streaks.
        let ci = CIImage(cgImage: raw)
        let blurred = ci.clampedToExtent()
            .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 6.0, kCIInputAngleKey: 0.0])
            .cropped(to: ci.extent)
        return ciContext.createCGImage(blurred, from: ci.extent)!
    }

    // MARK: - Soft shadows

    /// Soft drop shadow for a rounded rectangle; returns texture with transparent padding `pad` (fraction).
    static func roundedShadow(aspect: CGFloat, radiusFrac: CGFloat, blur: Double, pad: CGFloat, alpha: CGFloat) -> CGImage {
        let H = 512
        let W = Int(CGFloat(H) * aspect)
        let img = draw(W, H) { ctx in
            let inset = CGRect(x: CGFloat(W) * pad, y: CGFloat(H) * pad,
                               width: CGFloat(W) * (1 - 2 * pad), height: CGFloat(H) * (1 - 2 * pad))
            ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
            let r = radiusFrac * inset.width
            ctx.addPath(CGPath(roundedRect: inset, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
        return softBlur(img, radius: blur)
    }

    // MARK: - Button legends

    static func buttonLegend(_ text: String?, power: Bool = false, w: Int = 520, h: Int = 320) -> CGImage {
        draw(w, h) { ctx in
            let ink = NSColor(white: 0.86, alpha: 0.92)
            if power {
                let c = CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2 + 4)
                let r: CGFloat = CGFloat(h) * 0.24
                ctx.setStrokeColor(ink.cgColor)
                ctx.setLineWidth(CGFloat(h) * 0.07)
                ctx.setLineCap(.round)
                ctx.addArc(center: c, radius: r, startAngle: -.pi / 2 - 0.62 + .pi, endAngle: -.pi / 2 + 0.62 + .pi, clockwise: true)
                ctx.strokePath()
                ctx.move(to: CGPoint(x: c.x, y: c.y - r * 1.18))
                ctx.addLine(to: CGPoint(x: c.x, y: c.y - r * 0.15))
                ctx.strokePath()
            } else if let text {
                let font = NSFont(name: "Avenir Next Condensed Demi Bold", size: CGFloat(h) * 0.42)
                    ?? NSFont.boldSystemFont(ofSize: CGFloat(h) * 0.42)
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: ink, .kern: CGFloat(h) * 0.02, .paragraphStyle: para,
                ]
                let s = NSAttributedString(string: text, attributes: attrs)
                let size = s.size()
                s.draw(in: CGRect(x: 0, y: (CGFloat(h) - size.height) / 2 + 2, width: CGFloat(w), height: size.height))
            }
        }
    }

    // MARK: - Small printed legend on the chrome ("0.001g / 500g")

    static func printedLabel(_ text: String, w: Int = 1024, h: Int = 96, gray: CGFloat = 0.18, alpha: CGFloat = 0.7) -> CGImage {
        draw(w, h) { _ in
            let font = NSFont(name: "Avenir Next Demi Bold", size: CGFloat(h) * 0.55) ?? NSFont.boldSystemFont(ofSize: 40)
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let s = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor(white: gray, alpha: alpha), .kern: CGFloat(h) * 0.08, .paragraphStyle: para,
            ])
            let size = s.size()
            s.draw(in: CGRect(x: 0, y: (CGFloat(h) - size.height) / 2, width: CGFloat(w), height: size.height))
        }
    }

    // MARK: - Icon processing

    static func cgImage(from image: NSImage, size: Int) -> CGImage {
        draw(size, size, flipped: false) { ctx in
            image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// Multiply RGB (keeps alpha) – used for the darker "edge" layers of an icon tile.
    static func darkened(_ image: CGImage, factor: CGFloat, desaturate: CGFloat = 0.3) -> CGImage {
        let ci = CIImage(cgImage: image)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - desaturate])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0),
            ])
        return ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))!
    }

    /// Black silhouette of an image's alpha, blurred – contact shadow for an icon tile.
    static func silhouetteShadow(_ image: CGImage, blur radius: Double, pad: Int) -> CGImage {
        let size = image.width + pad * 2
        let base = draw(size, size, flipped: false) { ctx in
            ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        return softBlur(base, radius: radius)
    }
}
