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
                axleTag("FRONT \(split.front)%")
                    .position(x: geo.size.width * CarGeometry.centerX, y: geo.size.height * CarGeometry.frontY - 22)
                axleTag("REAR \(split.rear)%")
                    .position(x: geo.size.width * CarGeometry.centerX, y: geo.size.height * CarGeometry.rearY + 24)
            }
        }
    }

    private func axleTag(_ t: String) -> some View {
        Text(t).font(.footnote.monospacedDigit().weight(.heavy))
            .padding(.horizontal, 8).padding(.vertical, 3)
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

    /// Rear drive drawn so it reads at a glance over the busy livery:
    /// - a dark chassis "H" (axles + propshaft) underneath gives contrast;
    /// - the propshaft fills from the front toward the coupling in
    ///   proportion to the lock (how far the drive reaches the rear);
    /// - bold chevrons run rearward along the filled part, faster with more lock;
    /// - the rear axle and tyres go from grey to bright cyan with the lock;
    /// - the coupling carries the lock number itself.
    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let g = CarGeometry.self
        let w = size.width, h = size.height
        let cx = g.centerX * w
        let fy = g.frontY * h, ry = g.rearY * h
        let fl = CGPoint(x: cx - g.frontHalfTrack * w, y: fy), fr = CGPoint(x: cx + g.frontHalfTrack * w, y: fy)
        let rl = CGPoint(x: cx - g.rearHalfTrack * w, y: ry), rr = CGPoint(x: cx + g.rearHalfTrack * w, y: ry)
        let tyre = CGSize(width: g.tyre.width * w, height: g.tyre.height * h)
        let axleW = max(6, w * 0.022)
        let shaftW = max(9, w * 0.032)
        let couplingSize = CGSize(width: max(46, w * 0.15), height: max(30, w * 0.095))
        let coupling = CGPoint(x: cx, y: ry - couplingSize.height / 2 - axleW)
        let shaftTop = CGPoint(x: cx, y: fy + axleW / 2)
        let shaftBottom = CGPoint(x: cx, y: coupling.y - couplingSize.height / 2)

        let f = live && !off ? fraction : 0
        let lit = f > 0
        let grey = Color(red: 0.55, green: 0.60, blue: 0.70)
        let frontColor = !live ? Color.white.opacity(0.45) : Theme.ice

        if live { steeringTrace(ctx, from: CGPoint(x: cx, y: fy), wheelbase: ry - fy) }

        func seg(_ a: CGPoint, _ b: CGPoint) -> Path { Path { $0.move(to: a); $0.addLine(to: b) } }

        // 1. Dark chassis underlay for contrast.
        let under = StrokeStyle(lineWidth: shaftW + 10, lineCap: .round)
        for p in [seg(fl, fr), seg(rl, rr), seg(shaftTop, shaftBottom)] {
            ctx.stroke(p, with: .color(Theme.navy.opacity(0.78)), style: under)
        }

        // 2. Front axle: always driven.
        ctx.stroke(seg(fl, fr), with: .color(frontColor), style: StrokeStyle(lineWidth: axleW, lineCap: .round))

        // 3. Propshaft: grey track, then the lit part from the front.
        ctx.stroke(seg(shaftTop, shaftBottom), with: .color(grey.opacity(0.45)),
                   style: StrokeStyle(lineWidth: shaftW, lineCap: .round))
        if lit {
            let len = shaftBottom.y - shaftTop.y
            let litEnd = CGPoint(x: cx, y: shaftTop.y + len * f)
            var c = ctx
            c.addFilter(.shadow(color: Theme.cyan.opacity(0.8), radius: 8))
            c.stroke(seg(shaftTop, litEnd),
                     with: .linearGradient(Gradient(colors: [Theme.blue, Theme.cyan]), startPoint: shaftTop, endPoint: litEnd),
                     style: StrokeStyle(lineWidth: shaftW, lineCap: .round))

            // Chevrons pointing rearward, travelling down the lit part.
            let spacing = shaftW * 2.2
            let speed = 30 + 120 * f
            let offset = CGFloat(phase * speed).truncatingRemainder(dividingBy: spacing)
            var y = shaftTop.y + offset
            var chev = Path()
            let half = shaftW * 0.38
            while y < litEnd.y - half {
                chev.move(to: CGPoint(x: cx - half, y: y - half * 0.6))
                chev.addLine(to: CGPoint(x: cx, y: y + half * 0.6))
                chev.addLine(to: CGPoint(x: cx + half, y: y - half * 0.6))
                y += spacing
            }
            ctx.stroke(chev, with: .color(.white.opacity(0.95)),
                       style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }

        // 4. Rear axle: grey base, cyan over it with the lock.
        ctx.stroke(seg(rl, rr), with: .color(grey.opacity(live ? 0.6 : 0.4)),
                   style: StrokeStyle(lineWidth: axleW, lineCap: .round))
        if lit {
            var c = ctx
            c.addFilter(.shadow(color: Theme.cyan.opacity(0.9 * f), radius: 10))
            c.stroke(seg(rl, rr), with: .color(Theme.cyan.opacity(0.25 + 0.75 * f)),
                     style: StrokeStyle(lineWidth: axleW, lineCap: .round))
        }

        // 5. Wheels.
        wheel(ctx, fl, tyre, roadAngle, stroke: frontColor, fill: Theme.navy.opacity(0.75))
        wheel(ctx, fr, tyre, roadAngle, stroke: frontColor, fill: Theme.navy.opacity(0.75))
        let rearStroke = lit ? Theme.cyan.opacity(0.4 + 0.6 * f) : grey.opacity(live ? 0.7 : 0.45)
        let rearFill = lit ? Theme.cyan.opacity(0.12 + 0.55 * f) : Theme.navy.opacity(0.75)
        wheel(ctx, rl, tyre, .zero, stroke: rearStroke, fill: rearFill)
        wheel(ctx, rr, tyre, .zero, stroke: rearStroke, fill: rearFill)

        // 6. Coupling with the lock number in it.
        let box = CGRect(x: coupling.x - couplingSize.width / 2, y: coupling.y - couplingSize.height / 2,
                         width: couplingSize.width, height: couplingSize.height)
        let boxPath = Path(roundedRect: box, cornerRadius: 7)
        var cg = ctx
        if lit { cg.addFilter(.shadow(color: Theme.cyan.opacity(0.9), radius: 4 + 10 * f)) }
        cg.fill(boxPath, with: .color(Theme.navy.opacity(0.95)))
        ctx.stroke(boxPath, with: .color(lit ? Theme.cyan : grey.opacity(0.7)), lineWidth: 2)
        // Fill level along the bottom of the box.
        let bar = CGRect(x: box.minX + 4, y: box.maxY - 6, width: (box.width - 8) * f, height: 3)
        ctx.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(Theme.cyan))
        let label: String = !live ? "—" : (off ? "OFF" : "\(Int((fraction * 100).rounded()))%")
        ctx.draw(Text(label).font(.system(size: couplingSize.height * 0.48, weight: .heavy, design: .rounded)
                    .monospacedDigit())
                    .foregroundColor(lit ? .white : grey),
                 at: CGPoint(x: box.midX, y: box.midY - 2))
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

    private func wheel(_ ctx: GraphicsContext, _ c: CGPoint, _ size: CGSize, _ angle: Angle,
                       stroke: Color, fill: Color) {
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: angle)
        let r = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        let p = Path(roundedRect: r, cornerRadius: size.width * 0.35)
        g.fill(p, with: .color(Theme.navy.opacity(0.8)))
        g.fill(p, with: .color(fill))
        g.stroke(p, with: .color(stroke), lineWidth: 3)
        for i in 1..<4 {
            let y = r.minY + r.height * CGFloat(i) / 4
            g.stroke(Path { $0.move(to: CGPoint(x: r.minX + 4, y: y)); $0.addLine(to: CGPoint(x: r.maxX - 4, y: y)) },
                     with: .color(stroke.opacity(0.45)), lineWidth: 1.2)
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
