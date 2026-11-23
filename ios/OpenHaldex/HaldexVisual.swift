import SwiftUI

/// Drivetrain card: the car (real livery, x-ray drivetrain) beside a lock
/// gauge, target, steering and clutch temperature.
struct HaldexVisual: View {
    let lockActual: Int
    let lockTarget: Int
    let steeringDeg: Double?
    let off: Bool
    let live: Bool
    let split: (front: Int, rear: Int)?
    let clutchTemp: Int?
    let tempProtection: Bool
    var carHeight: CGFloat = 470
    var gaugeSize: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Drivetrain")
                Spacer()
                if !live {
                    tag("NOT CONNECTED", Theme.pink)
                } else if off {
                    tag("STOCK CONTROL", Theme.ice)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                HaldexCar(lockActual: lockActual, steeringDeg: steeringDeg, off: off, live: live,
                          split: split, height: carHeight)
                VStack(spacing: 22) {
                    LockGauge(actual: lockActual, target: lockTarget, live: live)
                        .frame(width: gaugeSize, height: gaugeSize)
                    VStack(alignment: .leading, spacing: 16) {
                        row("TARGET") {
                            Circle().fill(Theme.pink).frame(width: 6, height: 6)
                            Text("\(lockTarget)%").font(.subheadline.monospacedDigit().bold())
                        }
                        row("STEERING") {
                            Image(systemName: "steeringwheel")
                                .rotationEffect(.degrees(steeringDeg ?? 0))
                                .foregroundStyle(Theme.ice)
                            Text(steeringDeg.map { String(format: "%+.0f°", $0) } ?? "—")
                                .font(.subheadline.monospacedDigit().bold())
                        }
                        ClutchTempBar(tempC: clutchTemp, protection: tempProtection)
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(live ? 1 : 0.5)
            }
        }
        .animation(.easeOut(duration: 0.25), value: lockActual)
        .animation(.easeOut(duration: 0.3), value: live)
    }

    private func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.bold()).tracking(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(c)
            .background(c.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(c.opacity(0.4), lineWidth: 1))
    }

    /// Stacked stat (label over value) so the column stays narrow beside
    /// the big car.
    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 6) { value() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Haldex clutch temperature as a small thermometer bar; turns pink when
/// the controller's temperature protection is active or it runs hot.
struct ClutchTempBar: View {
    let tempC: Int?
    let protection: Bool
    private let maxC = 120.0
    private let hotC = 90.0

    var body: some View {
        let t = Double(tempC ?? 0)
        let frac = min(max(t / maxC, 0), 1)
        let hot = protection || t >= hotC
        VStack(alignment: .leading, spacing: 4) {
            Text("CLUTCH").font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: hot ? "thermometer.high" : "thermometer.medium")
                    .foregroundStyle(hot ? Theme.pink : Theme.ice)
                Text(tempC.map { "\($0)°C" } ?? "—").font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(hot ? Theme.pink : .primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.idle)
                    // Hot zone marker.
                    Rectangle().fill(Theme.pink.opacity(0.35))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * hotC / maxC)
                    Capsule()
                        .fill(LinearGradient(colors: hot ? [Theme.blue, Theme.pink] : [Theme.blue, Theme.cyan],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: tempC == nil ? 0 : max(geo.size.width * frac, 6))
                }
            }
            .frame(height: 6)
        }
        .animation(.easeOut(duration: 0.4), value: tempC)
    }
}

/// The car itself: livery image with the x-ray drivetrain on top. Dimmed and
/// frozen when the controller is not connected.
struct HaldexCar: View {
    let lockActual: Int
    let steeringDeg: Double?
    let off: Bool
    let live: Bool
    let split: (front: Int, rear: Int)?
    let height: CGFloat

    /// Typical VW steering ratio, only used to draw the road-wheel angle.
    private let steeringRatio = 15.0
    private var fraction: Double { live ? Double(min(max(lockActual, 0), 100)) / 100 : 0 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: fraction == 0)) { tl in
            let phase = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                Image("CarTop").resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .saturation(live ? 1 : 0.15)
                    .opacity(live ? 1 : 0.55)
                Canvas { ctx, size in
                    DrivetrainOverlay(fraction: fraction, off: off, live: live,
                                      roadAngle: .degrees((live ? steeringDeg ?? 0 : 0) / steeringRatio),
                                      phase: phase).draw(ctx, size)
                }
                if live { splitTags }
            }
        }
        .frame(width: height * CarGeometry.aspect, height: height)
        .animation(.easeOut(duration: 0.15), value: steeringDeg)
        .accessibilityElement()
        .accessibilityLabel(live ? "Haldex lock \(lockActual) percent" : "Not connected")
    }

    /// Torque-split tags at each axle, only where the split is known.
    private var splitTags: some View {
        GeometryReader { geo in
            if let split {
                axleTag("F \(split.front)%")
                    .position(x: geo.size.width * CarGeometry.centerX, y: geo.size.height * CarGeometry.frontY - 16)
                axleTag("R \(split.rear)%")
                    .position(x: geo.size.width * CarGeometry.centerX, y: geo.size.height * CarGeometry.rearY + 18)
            } else if lockActual > 0 {
                axleTag("\(lockActual)%")
                    .position(x: geo.size.width * CarGeometry.centerX, y: geo.size.height * CarGeometry.rearY + 18)
            }
        }
    }

    private func axleTag(_ t: String) -> some View {
        Text(t).font(.caption2.monospacedDigit().bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.navy.opacity(0.85), in: Capsule())
            .overlay(Capsule().stroke(Theme.cyan.opacity(0.6), lineWidth: 1))
            .foregroundStyle(Theme.ice)
    }
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
    let live: Bool
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
        let rearColor = lit ? Theme.cyan.opacity(0.35 + 0.65 * fraction) : Color.white.opacity(live ? 0.35 : 0.25)
        let frontColor = !live ? Color.white.opacity(0.4) : (off ? Theme.ice.opacity(0.7) : Theme.ice)

        if live { steeringTrace(ctx, from: CGPoint(x: cx, y: fy), wheelbase: ry - fy) }

        // Dark under-strokes keep the lines readable over the busy livery.
        func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: CGFloat, glow: Bool) {
            let p = Path { $0.move(to: a); $0.addLine(to: b) }
            ctx.stroke(p, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: width + 4, lineCap: .round))
            var c = ctx
            if glow { c.addFilter(.shadow(color: Theme.cyan.opacity(0.9), radius: 6)) }
            c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }

        line(fl, fr, frontColor, 3.5, glow: false)
        line(CGPoint(x: cx, y: fy), coupling, lit ? rearColor : Color.white.opacity(0.3), 3, glow: lit)
        line(rl, rr, rearColor, 3.5, glow: lit)

        // Torque flow: dashes travelling rearward, faster with more lock.
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

        wheel(ctx, fl, tyre, roadAngle, frontColor, glow: false)
        wheel(ctx, fr, tyre, roadAngle, frontColor, glow: false)
        wheel(ctx, rl, tyre, .zero, rearColor, glow: lit)
        wheel(ctx, rr, tyre, .zero, rearColor, glow: lit)
    }

    /// Faint path ahead of the car: a bicycle-model arc for the current
    /// road-wheel angle, fading out toward the nose.
    private func steeringTrace(_ ctx: GraphicsContext, from start: CGPoint, wheelbase: CGFloat) {
        let a = roadAngle.radians
        guard abs(a) > 0.004 else {
            ctx.stroke(Path { $0.move(to: start); $0.addLine(to: CGPoint(x: start.x, y: 0)) },
                       with: .linearGradient(Gradient(colors: [Theme.cyan.opacity(0.0), Theme.cyan.opacity(0.35)]),
                                             startPoint: CGPoint(x: start.x, y: 0), endPoint: start),
                       style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
            return
        }
        // Turning radius of the front axle centre (bicycle model).
        let r = wheelbase / sin(a)
        // Centre lies on the normal to the wheel heading (signed r: right turn > 0).
        let centre = CGPoint(x: start.x + r * cos(a), y: start.y + r * sin(a))
        let length = start.y  // trace up to the top of the image
        let sweep = length / abs(r)
        var p = Path()
        let steps = 24
        for i in 0...steps {
            let t = Double(i) / Double(steps) * sweep
            // Clockwise on screen for a right turn, anticlockwise for a left.
            let ang = (a > 0 ? 1.0 : -1.0) * t
            let dx = start.x - centre.x, dy = start.y - centre.y
            let x = centre.x + dx * cos(ang) - dy * sin(ang)
            let y = centre.y + dx * sin(ang) + dy * cos(ang)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(p, with: .linearGradient(Gradient(colors: [Theme.cyan.opacity(0.0), Theme.cyan.opacity(0.45)]),
                                            startPoint: CGPoint(x: start.x, y: 0), endPoint: start),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))
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
    var live = true

    private let start = 0.125, span = 0.75  // 270° arc, open at the bottom

    var body: some View {
        let a = live ? Double(min(max(actual, 0), 100)) / 100 : 0
        let t = Double(min(max(target, 0), 100)) / 100
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let lw = side * 0.08
            ZStack {
                Circle().trim(from: start, to: start + span)
                    .stroke(Theme.idle, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(90))
                // Scale ticks every 10 %.
                ForEach(0..<11) { i in
                    let ang = Angle.degrees(90 + 360 * (start + span * Double(i) / 10))
                    Capsule().fill(Color.white.opacity(i % 5 == 0 ? 0.5 : 0.2))
                        .frame(width: 1.5, height: i % 5 == 0 ? lw * 0.9 : lw * 0.5)
                        .offset(y: -(side / 2 - lw * 1.6))
                        .rotationEffect(ang + .degrees(90))
                }
                Circle().trim(from: start, to: start + span * max(a, 0.001))
                    .stroke(AngularGradient(colors: [Theme.blue, Theme.cyan], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * span)),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .shadow(color: Theme.cyan.opacity(a > 0 ? 0.6 : 0), radius: 8)
                if live {
                    let r = side / 2
                    let ang = Angle.degrees(90 + 360 * (start + span * t))
                    Circle().fill(Theme.pink).frame(width: lw * 0.85, height: lw * 0.85)
                        .overlay(Circle().stroke(Theme.navy, lineWidth: 2))
                        .offset(x: r * cos(ang.radians), y: r * sin(ang.radians))
                }
                VStack(spacing: 0) {
                    Text(live ? "\(actual)" : "—")
                        .font(.system(size: side * 0.31, weight: .heavy, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("% LOCK").font(.system(size: max(side * 0.075, 10), weight: .bold)).tracking(1.5)
                        .foregroundStyle(Theme.cyan)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .opacity(live ? 1 : 0.5)
        .animation(.easeOut(duration: 0.25), value: actual)
        .animation(.easeOut(duration: 0.25), value: target)
    }
}
