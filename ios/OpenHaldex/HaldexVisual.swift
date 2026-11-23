import SwiftUI

/// Top-down view of the car (the real livery) with an x-ray drivetrain drawn
/// on top: front wheels follow the steering, the propshaft and rear axle light
/// up with the actual Haldex lock, and torque "flows" rearward while engaged.
/// Beside it a lock gauge with the target marked.
struct HaldexVisual: View {
    let lockActual: Int
    let lockTarget: Int
    let steeringDeg: Double?
    let off: Bool

    /// Typical VW steering ratio, only used to draw the road-wheel angle.
    private let steeringRatio = 15.0
    private let carHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DRIVETRAIN").font(.caption.bold()).tracking(1.5).foregroundStyle(Theme.cyan.opacity(0.9))
                Spacer()
                if off {
                    Text("STOCK CONTROL").font(.caption2.bold()).tracking(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.idle, in: Capsule())
                }
            }
            HStack(alignment: .center, spacing: 14) {
                car
                VStack(spacing: 18) {
                    LockGauge(actual: lockActual, target: lockTarget)
                        .frame(width: 150, height: 150)
                    VStack(spacing: 10) {
                        stat("TARGET", "\(lockTarget)%", Theme.pink)
                        HStack {
                            Text("STEERING").font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "steeringwheel")
                                .rotationEffect(.degrees(steeringDeg ?? 0))
                                .foregroundStyle(Theme.ice)
                            Text(steeringText).font(.subheadline.monospacedDigit().bold())
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: lockActual)
        .animation(.easeOut(duration: 0.15), value: steeringDeg)
    }

    private var car: some View {
        let w = carHeight * CarGeometry.aspect
        return TimelineView(.animation(minimumInterval: 1 / 30, paused: fraction == 0)) { tl in
            let phase = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                Image("CarTop").resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                Canvas { ctx, size in
                    DrivetrainOverlay(fraction: fraction, off: off,
                                      roadAngle: .degrees((steeringDeg ?? 0) / steeringRatio),
                                      phase: phase).draw(ctx, size)
                }
            }
        }
        .frame(width: w, height: carHeight)
        .accessibilityLabel("Haldex lock \(lockActual) percent, steering \(steeringText)")
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
            Spacer()
            Circle().fill(color).frame(width: 6, height: 6)
            Text(value).font(.subheadline.monospacedDigit().bold())
        }
    }

    private var steeringText: String {
        guard let s = steeringDeg else { return "—" }
        return String(format: "%+.0f°", s)
    }

    private var fraction: Double { Double(min(max(lockActual, 0), 100)) / 100 }
}

/// Where the drivetrain sits on CarTop.png (Audi TT 8S proportions: 4177 mm
/// long, 2505 mm wheelbase, ~1570 mm track), as fractions of the image.
enum CarGeometry {
    static let aspect: CGFloat = 660.0 / 1360.0
    static let centerX: CGFloat = 0.495
    static let frontY: CGFloat = 0.232
    static let rearY: CGFloat = 0.788
    static let frontHalfTrack: CGFloat = 0.359
    static let rearHalfTrack: CGFloat = 0.353
    static let tyre = CGSize(width: 0.105, height: 0.140)
}

private struct DrivetrainOverlay {
    let fraction: Double
    let off: Bool
    let roadAngle: Angle
    let phase: TimeInterval

    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let g = CarGeometry.self
        let w = size.width, h = size.height
        let cx = g.centerX * w
        let fy = g.frontY * h, ry = g.rearY * h
        let fl = CGPoint(x: cx - g.frontHalfTrack * w, y: fy), fr = CGPoint(x: cx + g.frontHalfTrack * w, y: fy)
        let rl = CGPoint(x: cx - g.rearHalfTrack * w, y: ry), rr = CGPoint(x: cx + g.rearHalfTrack * w, y: ry)
        let tyre = CGSize(width: g.tyre.width * w, height: g.tyre.height * h)
        let coupling = CGPoint(x: cx, y: ry - 0.045 * h)

        let lit = fraction > 0
        let rearColor = lit ? Theme.cyan.opacity(0.35 + 0.65 * fraction) : Color.white.opacity(0.35)
        let frontColor = off ? Theme.ice.opacity(0.7) : Theme.ice

        // Dark under-strokes keep the lines readable over the busy livery.
        func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: CGFloat, glow: Bool) {
            let p = Path { $0.move(to: a); $0.addLine(to: b) }
            ctx.stroke(p, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: width + 4, lineCap: .round))
            var c = ctx
            if glow { c.addFilter(.shadow(color: Theme.cyan.opacity(0.9), radius: 6)) }
            c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }

        // Front axle: always driven.
        line(fl, fr, frontColor, 3.5, glow: false)
        // Propshaft from the front diff back to the coupling.
        line(CGPoint(x: cx, y: fy), coupling, lit ? rearColor : Color.white.opacity(0.3), 3, glow: lit)
        // Rear axle, lit with engagement.
        line(rl, rr, rearColor, 3.5, glow: lit)

        // Torque flow: dashes travelling rearward, denser/faster with more lock.
        if lit {
            let dash = Path { $0.move(to: CGPoint(x: cx, y: fy)); $0.addLine(to: coupling) }
            let speed = 40 + 90 * fraction
            ctx.stroke(dash, with: .color(.white.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 11],
                                          dashPhase: -CGFloat(phase * speed).truncatingRemainder(dividingBy: 14)))
        }

        // Haldex coupling: a glowing block ahead of the rear diff.
        let box = CGRect(x: coupling.x - 12, y: coupling.y - 9, width: 24, height: 18)
        var cg = ctx
        if lit { cg.addFilter(.shadow(color: Theme.cyan, radius: 4 + 10 * fraction)) }
        cg.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(Theme.navy.opacity(0.9)))
        cg.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(lit ? rearColor : .white.opacity(0.4)), lineWidth: 2)
        let fill = CGRect(x: box.minX + 3, y: box.minY + 3, width: (box.width - 6) * fraction, height: box.height - 6)
        cg.fill(Path(roundedRect: fill, cornerRadius: 2), with: .color(Theme.cyan.opacity(0.9)))

        // Wheels (x-ray): fronts rotate with the road-wheel angle.
        wheel(ctx, fl, tyre, roadAngle, frontColor, glow: false)
        wheel(ctx, fr, tyre, roadAngle, frontColor, glow: false)
        wheel(ctx, rl, tyre, .zero, rearColor, glow: lit)
        wheel(ctx, rr, tyre, .zero, rearColor, glow: lit)
    }

    private func wheel(_ ctx: GraphicsContext, _ c: CGPoint, _ size: CGSize, _ angle: Angle, _ color: Color, glow: Bool) {
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: angle)
        let r = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        let p = Path(roundedRect: r, cornerRadius: size.width * 0.35)
        g.fill(p, with: .color(Theme.navy.opacity(0.72)))
        if glow { g.addFilter(.shadow(color: Theme.cyan.opacity(0.9), radius: 6)) }
        g.stroke(p, with: .color(color), lineWidth: 2.5)
        // Tread lines.
        for i in 1..<4 {
            let y = r.minY + r.height * CGFloat(i) / 4
            g.stroke(Path { $0.move(to: CGPoint(x: r.minX + 3, y: y)); $0.addLine(to: CGPoint(x: r.maxX - 3, y: y)) },
                     with: .color(color.opacity(0.35)), lineWidth: 1)
        }
    }
}

/// Ring gauge for the actual lock, with the target as a pink marker.
struct LockGauge: View {
    let actual: Int
    let target: Int

    private let start = 0.125, span = 0.75  // 270° arc, open at the bottom

    var body: some View {
        let a = Double(min(max(actual, 0), 100)) / 100
        let t = Double(min(max(target, 0), 100)) / 100
        ZStack {
            Circle().trim(from: start, to: start + span)
                .stroke(Theme.idle, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle().trim(from: start, to: start + span * max(a, 0.001))
                .stroke(AngularGradient(colors: [Theme.blue, Theme.cyan], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * span)),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(90))
                .shadow(color: Theme.cyan.opacity(a > 0 ? 0.6 : 0), radius: 8)
            // Target marker.
            GeometryReader { geo in
                let r = min(geo.size.width, geo.size.height) / 2
                let ang = Angle.degrees(90 + 360 * (start + span * t))
                Circle().fill(Theme.pink).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Theme.navy, lineWidth: 2))
                    .position(x: geo.size.width / 2 + r * cos(ang.radians), y: geo.size.height / 2 + r * sin(ang.radians))
            }
            VStack(spacing: 0) {
                Text("\(actual)")
                    .font(.system(size: 46, weight: .heavy, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("% LOCK").font(.caption2.bold()).tracking(1.5).foregroundStyle(Theme.cyan)
            }
        }
        .animation(.easeOut(duration: 0.25), value: actual)
        .animation(.easeOut(duration: 0.25), value: target)
    }
}
