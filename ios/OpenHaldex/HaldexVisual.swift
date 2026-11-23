import SwiftUI

/// Top-down drivetrain view: front wheels follow the steering wheel, and the
/// driveshaft / rear axle fill with the actual Haldex engagement (target shown
/// as a tick on the bar).
struct HaldexVisual: View {
    let lockActual: Int
    let lockTarget: Int
    let steeringDeg: Double?
    let off: Bool

    /// Typical VW steering ratio, only used to draw the road-wheel angle.
    private let steeringRatio = 15.0

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("HALDEX ENGAGEMENT").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("\(lockActual)%").font(.headline.monospacedDigit())
            }
            Canvas { ctx, size in draw(ctx, size) }
                .frame(height: 230)
                .animation(.easeOut(duration: 0.2), value: lockActual)
            engagementBar
            HStack {
                Label(steeringText, systemImage: "steeringwheel")
                Spacer()
                Text("Target \(lockTarget)%").foregroundStyle(.secondary)
            }
            .font(.subheadline.monospacedDigit())
        }
    }

    private var steeringText: String {
        guard let s = steeringDeg else { return "—" }
        return String(format: "%.0f°", s)
    }

    private var fraction: Double { Double(min(max(lockActual, 0), 100)) / 100 }

    private var engagementBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color.orange).frame(width: geo.size.width * fraction)
                Rectangle().fill(Color.white)
                    .frame(width: 2, height: 16)
                    .offset(x: geo.size.width * Double(min(max(lockTarget, 0), 100)) / 100 - 1)
            }
        }
        .frame(height: 12)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let cx = w / 2
        let trackHalf = min(w * 0.28, 90.0)
        let frontY = h * 0.18, rearY = h * 0.82
        let wheel = CGSize(width: 18, height: 40)
        let dim = Color.white.opacity(0.18)
        let drive = Color.orange.opacity(off ? 0.35 : 0.25 + 0.75 * fraction)

        // Body outline.
        let body = CGRect(x: cx - trackHalf + 14, y: frontY - 34, width: (trackHalf - 14) * 2, height: rearY - frontY + 68)
        ctx.stroke(Path(roundedRect: body, cornerRadius: 26), with: .color(dim), lineWidth: 2)

        // Front axle is always driven (orange); driveshaft + rear axle scale with engagement.
        ctx.stroke(Path { p in p.move(to: CGPoint(x: cx - trackHalf, y: frontY)); p.addLine(to: CGPoint(x: cx + trackHalf, y: frontY)) },
                   with: .color(.orange), lineWidth: 5)
        ctx.stroke(Path { p in p.move(to: CGPoint(x: cx, y: frontY)); p.addLine(to: CGPoint(x: cx, y: rearY)) },
                   with: .color(dim), lineWidth: 6)
        if fraction > 0 {
            let len = (rearY - frontY) * fraction
            ctx.stroke(Path { p in p.move(to: CGPoint(x: cx, y: frontY)); p.addLine(to: CGPoint(x: cx, y: frontY + len)) },
                       with: .color(drive), lineWidth: 6)
        }
        ctx.stroke(Path { p in p.move(to: CGPoint(x: cx - trackHalf, y: rearY)); p.addLine(to: CGPoint(x: cx + trackHalf, y: rearY)) },
                   with: .color(fraction > 0 ? drive : dim), lineWidth: 5)

        // Haldex coupling box at the rear.
        let box = CGRect(x: cx - 16, y: rearY - 28, width: 32, height: 22)
        ctx.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(fraction > 0 ? drive : dim))

        // Wheels: fronts rotate with road-wheel angle (steering / ratio).
        let roadAngle = Angle.degrees((steeringDeg ?? 0) / steeringRatio)
        for side in [-1.0, 1.0] {
            drawWheel(ctx, at: CGPoint(x: cx + side * trackHalf, y: frontY), size: wheel, angle: roadAngle, color: .orange)
            drawWheel(ctx, at: CGPoint(x: cx + side * trackHalf, y: rearY), size: wheel, angle: .zero,
                      color: fraction > 0 ? drive : dim)
        }
    }

    private func drawWheel(_ ctx: GraphicsContext, at c: CGPoint, size: CGSize, angle: Angle, color: Color) {
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: angle)
        let r = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        g.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(color))
    }
}
