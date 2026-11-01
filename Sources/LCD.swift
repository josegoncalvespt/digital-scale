import AppKit

/// Everything the LCD shows. Rendering is driven purely by this value, so the
/// texture is only regenerated when something visible actually changes.
struct LCDState: Equatable {
    struct Cell: Equatable { var char: Character = " "; var dot = false }

    var backlight: CGFloat = 1          // 0 = off, 1 = fully lit
    var cells: [Cell] = Array(repeating: Cell(), count: 5)
    var minus = false
    var unit: Int? = 0                  // index into Units.all
    var pcs = false
    var net = false
    var stable = false
    var zero = false
    var allOn = false                   // power-on segment test

    static let off = LCDState(backlight: 0, cells: Array(repeating: Cell(), count: 5), unit: nil)
}

enum LCDRenderer {
    static let width = 1200
    static let height = 440

    private static let segmentsFor: [Character: String] = [
        "0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc", "5": "afgcd",
        "6": "afgedc", "7": "abc", "8": "abcdefg", "9": "abcdfg", "-": "g", " ": "",
        "o": "cdeg", "L": "def", "E": "adefg", "r": "eg", "P": "abefg", "C": "adef",
        "c": "deg", "S": "afgcd", "n": "ceg", "t": "defg", "A": "abcefg", "U": "bcdef",
        "u": "cde", "d": "bcdeg", "b": "cdefg", "F": "aefg", "H": "bcefg", "_": "d",
        "O": "abcdef", "h": "cefg", "y": "bcdfg", "i": "c", "Z": "abged",
    ]

    // Layout constants (texture pixels, top-left origin)
    private static let digitW: CGFloat = 150
    private static let digitH: CGFloat = 270
    private static let digitGap: CGFloat = 36
    private static let thick: CGFloat = 27
    private static let skew: CGFloat = tan(7 * .pi / 180)
    private static let digitsTop: CGFloat = 112
    private static let digitsLeft: CGFloat = 196

    static func render(_ s: LCDState) -> CGImage {
        Textures.draw(width, height) { ctx in
            let W = CGFloat(width), H = CGFloat(height)
            let bl = s.backlight
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!

            // --- Backlight -------------------------------------------------------
            let offColor = NSColor(red: 0.030, green: 0.040, blue: 0.055, alpha: 1)
            let edge = blend(offColor, NSColor(red: 0.05, green: 0.20, blue: 0.70, alpha: 1), bl)
            let mid = blend(offColor, NSColor(red: 0.13, green: 0.40, blue: 0.98, alpha: 1), bl)
            let hot = blend(offColor, NSColor(red: 0.62, green: 0.86, blue: 1.00, alpha: 1), bl)
            ctx.setFillColor(edge.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            let g1 = CGGradient(colorsSpace: cs, colors: [mid.cgColor, edge.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g1, startCenter: CGPoint(x: W * 0.42, y: H * 0.45), startRadius: 0,
                                   endCenter: CGPoint(x: W * 0.42, y: H * 0.45), endRadius: W * 0.62, options: [.drawsAfterEndLocation])
            // LED hot spot (edge-lit backlights are brighter near the LED)
            let g2 = CGGradient(colorsSpace: cs, colors: [hot.withAlphaComponent(0.9 * bl).cgColor, hot.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g2, startCenter: CGPoint(x: W * 0.08, y: H * 0.22), startRadius: 0,
                                   endCenter: CGPoint(x: W * 0.08, y: H * 0.22), endRadius: W * 0.36, options: [])

            // --- Ghost segments (unlit segments are faintly visible on real LCDs) --
            let ghost = NSColor(red: 0.0, green: 0.03, blue: 0.20, alpha: 0.10 + 0.06 * (1 - bl))
            for i in 0..<5 {
                fillSegments(ctx, origin: digitOrigin(i), segs: "abcdefg", color: ghost.cgColor)
                fillDot(ctx, cell: i, color: ghost.cgColor)
            }
            fillMinus(ctx, color: ghost.cgColor)

            guard bl > 0.02 else {
                drawLegends(ctx, s, litAlpha: 0, ghost: ghost)
                return
            }

            // --- Lit segments ------------------------------------------------------
            let ink = NSColor(red: 0.93, green: 0.97, blue: 1.0, alpha: min(1, bl * 1.1))
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 18, color: NSColor(red: 0.75, green: 0.9, blue: 1, alpha: 0.55 * bl).cgColor)
            for (i, cell) in s.cells.enumerated() {
                let segs = s.allOn ? "abcdefg" : (segmentsFor[cell.char] ?? "")
                fillSegments(ctx, origin: digitOrigin(i), segs: segs, color: ink.cgColor)
                if cell.dot || s.allOn { fillDot(ctx, cell: i, color: ink.cgColor) }
            }
            if s.minus || s.allOn { fillMinus(ctx, color: ink.cgColor) }
            ctx.restoreGState()

            drawLegends(ctx, s, litAlpha: bl, ghost: ghost)
        }
    }

    // MARK: - Segment geometry

    private static func digitOrigin(_ i: Int) -> CGPoint {
        CGPoint(x: digitsLeft + CGFloat(i) * (digitW + digitGap), y: digitsTop)
    }

    private static func skewed(_ p: CGPoint, baseY: CGFloat) -> CGPoint {
        CGPoint(x: p.x + (baseY - p.y) * skew, y: p.y)
    }

    private static func fillSegments(_ ctx: CGContext, origin o: CGPoint, segs: String, color: CGColor) {
        let t = thick, w = digitW, h = digitH, gap: CGFloat = 4.5
        let tl = CGPoint(x: o.x + t / 2, y: o.y + t / 2)
        let tr = CGPoint(x: o.x + w - t / 2, y: o.y + t / 2)
        let ml = CGPoint(x: o.x + t / 2, y: o.y + h / 2)
        let mr = CGPoint(x: o.x + w - t / 2, y: o.y + h / 2)
        let bl = CGPoint(x: o.x + t / 2, y: o.y + h - t / 2)
        let br = CGPoint(x: o.x + w - t / 2, y: o.y + h - t / 2)
        let lines: [Character: (CGPoint, CGPoint)] = [
            "a": (tl, tr), "b": (tr, mr), "c": (mr, br), "d": (bl, br),
            "e": (ml, bl), "f": (tl, ml), "g": (ml, mr),
        ]
        ctx.setFillColor(color)
        let baseY = o.y + h
        for s in segs {
            guard let (p1, p2) = lines[s] else { continue }
            let horizontal = abs(p1.y - p2.y) < 0.5
            var pts: [CGPoint]
            let ht = t / 2
            if horizontal {
                let y = p1.y, x1 = p1.x + gap, x2 = p2.x - gap
                pts = [CGPoint(x: x1, y: y), CGPoint(x: x1 + ht, y: y - ht), CGPoint(x: x2 - ht, y: y - ht),
                       CGPoint(x: x2, y: y), CGPoint(x: x2 - ht, y: y + ht), CGPoint(x: x1 + ht, y: y + ht)]
            } else {
                let x = p1.x, y1 = p1.y + gap, y2 = p2.y - gap
                pts = [CGPoint(x: x, y: y1), CGPoint(x: x + ht, y: y1 + ht), CGPoint(x: x + ht, y: y2 - ht),
                       CGPoint(x: x, y: y2), CGPoint(x: x - ht, y: y2 - ht), CGPoint(x: x - ht, y: y1 + ht)]
            }
            let sk = pts.map { skewed($0, baseY: baseY) }
            ctx.move(to: sk[0]); sk.dropFirst().forEach { ctx.addLine(to: $0) }; ctx.closePath()
            ctx.fillPath()
        }
    }

    private static func fillDot(_ ctx: CGContext, cell i: Int, color: CGColor) {
        guard i < 4 else { return }
        let o = digitOrigin(i)
        let size: CGFloat = 26
        let c = CGPoint(x: o.x + digitW + digitGap / 2, y: o.y + digitH - size / 2 - 2)
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size))
    }

    private static func fillMinus(_ ctx: CGContext, color: CGColor) {
        let y = digitsTop + digitH / 2
        let r = CGRect(x: 92, y: y - thick / 2, width: 76, height: thick)
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
    }

    // MARK: - Legends (printed indicators)

    private static func drawLegends(_ ctx: CGContext, _ s: LCDState, litAlpha: CGFloat, ghost: NSColor) {
        let font = NSFont(name: "DIN Condensed Bold", size: 66) ?? NSFont.boldSystemFont(ofSize: 54)
        let small = NSFont(name: "DIN Condensed Bold", size: 50) ?? NSFont.boldSystemFont(ofSize: 40)
        let lit = NSColor(red: 0.95, green: 0.98, blue: 1.0, alpha: litAlpha)

        func label(_ text: String, at p: CGPoint, on: Bool, f: NSFont = font) {
            let color = on ? lit : ghost
            let shadow = NSShadow()
            shadow.shadowBlurRadius = on ? 10 : 0
            shadow.shadowColor = NSColor(red: 0.7, green: 0.9, blue: 1, alpha: 0.5 * litAlpha)
            let a = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color, .shadow: shadow])
            a.draw(at: p)
        }

        // Unit legends across the top
        let names = Units.all.map { $0.legend }
        var x: CGFloat = 200
        for (i, n) in names.enumerated() {
            label(n, at: CGPoint(x: x, y: 18), on: s.allOn || s.unit == i)
            x += 128
        }
        label("PCS", at: CGPoint(x: x + 20, y: 18), on: s.allOn || s.pcs)

        // Left column
        label("NET", at: CGPoint(x: 50, y: 112), on: s.allOn || s.net, f: small)
        // Stable indicator: a little ring
        let stableOn = s.allOn || s.stable
        ctx.saveGState()
        ctx.setStrokeColor((stableOn ? lit : ghost).cgColor)
        ctx.setLineWidth(8)
        if stableOn { ctx.setShadow(offset: .zero, blur: 10, color: NSColor(red: 0.7, green: 0.9, blue: 1, alpha: 0.5 * litAlpha).cgColor) }
        ctx.strokeEllipse(in: CGRect(x: 66, y: 316, width: 44, height: 44))
        ctx.restoreGState()
        // Zero arrows  ▸0◂
        let zeroOn = s.allOn || s.zero
        ctx.setFillColor((zeroOn ? lit : ghost).cgColor)
        let zy: CGFloat = 395
        tri(ctx, CGPoint(x: 56, y: zy), right: true)
        label("0", at: CGPoint(x: 77, y: zy - 26), on: zeroOn, f: small)
        tri(ctx, CGPoint(x: 120, y: zy), right: false)

        // Battery outline (always lit when on – just a nice detail)
        let bat = CGRect(x: 1090, y: 36, width: 70, height: 32)
        ctx.setStrokeColor((s.backlight > 0.02 ? lit.withAlphaComponent(litAlpha * 0.9) : ghost).cgColor)
        ctx.setLineWidth(5)
        ctx.stroke(bat)
        ctx.setFillColor((s.backlight > 0.02 ? lit.withAlphaComponent(litAlpha * 0.9) : ghost).cgColor)
        ctx.fill(CGRect(x: bat.maxX + 2, y: bat.midY - 7, width: 7, height: 14))
        for k in 0..<3 { ctx.fill(CGRect(x: bat.minX + 8 + CGFloat(k) * 20, y: bat.minY + 7, width: 15, height: bat.height - 14)) }
    }

    private static func tri(_ ctx: CGContext, _ c: CGPoint, right: Bool) {
        let s: CGFloat = 14
        ctx.move(to: CGPoint(x: c.x + (right ? s : -s), y: c.y))
        ctx.addLine(to: CGPoint(x: c.x - (right ? s : -s), y: c.y - s))
        ctx.addLine(to: CGPoint(x: c.x - (right ? s : -s), y: c.y + s))
        ctx.closePath(); ctx.fillPath()
    }

    private static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let a = a.usingColorSpace(.sRGB)!, b = b.usingColorSpace(.sRGB)!
        return NSColor(red: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
    }
}

// MARK: - Units

struct Units {
    let legend: String
    let perGram: Double   // display units per megabyte
    static let defaultIndex = 2

    static let all: [Units] = [
        // Internally the load is tracked in megabytes (decimal, like Finder).
        Units(legend: "B", perGram: 1_000_000),
        Units(legend: "KB", perGram: 1_000),
        Units(legend: "MB", perGram: 1),
        Units(legend: "GB", perGram: 0.001),
        Units(legend: "TB", perGram: 0.000_001),
    ]
}
