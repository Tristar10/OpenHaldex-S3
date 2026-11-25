import SwiftUI

/// Full-screen launch sequence driven by the board's launch detector
/// (firmware v1.1.23+, live status bytes 18-26):
///   ARMED   pulsing red stage, shaking car, RPM LED bar, rear-lock meter,
///           "READY" stamp once the coupling is locked (>= 90 %)
///   RUNNING speed streaks, a running clock, progress to 100 km/h
///   DONE    shockwave rings and the 0-100 km/h time
///   ABORTED a short grey "ABORTED"
struct LaunchOverlay: View {
    let state: Int
    let ms: Int
    let rpm: Int
    let speed: Int
    let throttle: Int
    let brakeBar: Double
    let lock: Int
    var onDismiss: () -> Void = {}

    @State private var msAt = Date()
    @State private var doneAt = Date()

    private var ready: Bool { lock >= 90 }

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                background(t)
                switch state {
                case 1: armed(t)
                case 2: running(t, now: tl.date)
                case 3: done(t, now: tl.date)
                default: aborted
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { if state >= 3 { onDismiss() } }
        .onChange(of: ms) { _, _ in msAt = Date() }
        .onChange(of: state) { _, s in if s == 3 { doneAt = Date() } }
        .sensoryFeedback(trigger: state) { _, s in
            switch s {
            case 1: .impact(weight: .heavy, intensity: 1)
            case 2: .impact(flexibility: .rigid, intensity: 1)
            case 3: .success
            case 4: .warning
            default: nil
            }
        }
        .sensoryFeedback(.success, trigger: ready) { _, r in r && state == 1 }
        .statusBarHidden()
    }

    // MARK: Background

    private func background(_ t: Double) -> some View {
        let pulse = 0.5 + 0.5 * sin(t * (ready ? 9 : 5))
        let glow: Color = switch state {
        case 1: ready ? .green : .red
        case 2: Theme.cyan
        case 3: Theme.cyan
        default: .gray
        }
        return ZStack {
            Color.black
            RadialGradient(colors: [glow.opacity(state == 1 ? 0.25 + 0.3 * pulse : 0.35), .clear],
                           center: .center, startRadius: 20, endRadius: 520)
            if state == 2 { SpeedStreaks(speed: speed, t: t) }
            if state == 3 { Shockwave(age: Date().timeIntervalSince(doneAt)) }
            // Vignette.
            RadialGradient(colors: [.clear, .black.opacity(0.85)], center: .center, startRadius: 200, endRadius: 600)
        }
    }

    // MARK: Armed

    private func armed(_ t: Double) -> some View {
        let shake = Double(min(rpm, 7000)) / 7000 * 3.5
        return VStack(spacing: 18) {
            Spacer()
            Text("LAUNCH")
                .font(.system(size: 76, weight: .black, design: .rounded)).italic()
                .tracking(4)
                .foregroundStyle(LinearGradient(colors: [.white, ready ? .green : Theme.pink],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: (ready ? Color.green : .red).opacity(0.8), radius: 18)
            Text(ready ? "READY — RELEASE THE BRAKE" : "ARMED — BUILDING LOCK")
                .font(.headline.weight(.heavy)).tracking(2)
                .foregroundStyle(ready ? .green : Theme.pink)
                .opacity(0.6 + 0.4 * sin(t * 8))

            Image("CarTop").resizable().aspectRatio(contentMode: .fit)
                .frame(height: 260)
                .offset(x: sin(t * 61) * shake, y: cos(t * 47) * shake)
                .shadow(color: (ready ? Color.green : .red).opacity(0.7), radius: 24)
                .overlay(alignment: .bottom) { rearGlow.offset(y: -40) }

            RPMBar(rpm: rpm).frame(height: 26).padding(.horizontal, 28)
            HStack(spacing: 26) {
                stat("\(rpm)", "RPM")
                stat("\(lock)%", "REAR LOCK", ready ? .green : Theme.cyan)
                stat(String(format: "%.0f", brakeBar), "BRAKE BAR")
                stat("\(throttle)%", "THROTTLE")
            }
            Spacer()
        }
        .overlay {
            if ready {
                Text("READY").font(.system(size: 64, weight: .black)).tracking(8)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 24).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.green, lineWidth: 6))
                    .rotationEffect(.degrees(-12))
                    .opacity(0.9)
                    .shadow(color: .green, radius: 12)
                    .transition(.scale(scale: 2.5).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: ready)
    }

    /// Rear axle glow that grows with the lock.
    private var rearGlow: some View {
        Capsule().fill((ready ? Color.green : Theme.cyan).opacity(0.25 + 0.6 * Double(lock) / 100))
            .frame(width: 170, height: 16).blur(radius: 10)
    }

    // MARK: Running

    private func running(_ t: Double, now: Date) -> some View {
        let shown = Double(ms) / 1000 + now.timeIntervalSince(msAt)
        return VStack(spacing: 10) {
            Spacer()
            Text("GO").font(.system(size: 40, weight: .black, design: .rounded)).italic().tracking(6)
                .foregroundStyle(Theme.cyan)
            Text(String(format: "%.2f", shown))
                .font(.system(size: 110, weight: .black, design: .rounded).monospacedDigit()).italic()
                .foregroundStyle(.white)
                .shadow(color: Theme.cyan, radius: 20)
            Text("SECONDS").font(.caption.bold()).tracking(4).foregroundStyle(.secondary)
            Text("\(speed) km/h").font(.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.ice).padding(.top, 20)
            ProgressBar(fraction: Double(speed) / 100).frame(height: 10).padding(.horizontal, 40)
            Text("0 → 100 km/h").font(.caption.bold()).tracking(2).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Done

    private func done(_ t: Double, now: Date) -> some View {
        let age = now.timeIntervalSince(doneAt)
        let pop = min(1, age / 0.35)
        return VStack(spacing: 8) {
            Spacer()
            Text("0 – 100 km/h").font(.title3.weight(.heavy)).tracking(3).foregroundStyle(Theme.cyan)
            Text(String(format: "%.2f s", Double(ms) / 1000))
                .font(.system(size: 96, weight: .black, design: .rounded).monospacedDigit()).italic()
                .foregroundStyle(LinearGradient(colors: [.white, Theme.cyan], startPoint: .top, endPoint: .bottom))
                .shadow(color: Theme.cyan, radius: 24)
                .scaleEffect(1.6 - 0.6 * pop)
                .opacity(pop)
            Spacer()
            Text("TAP TO CLOSE").font(.caption.bold()).tracking(3).foregroundStyle(.secondary)
                .padding(.bottom, 60)
        }
    }

    // MARK: Aborted

    private var aborted: some View {
        Text("ABORTED").font(.system(size: 60, weight: .black, design: .rounded)).italic().tracking(4)
            .foregroundStyle(.gray)
            .overlay(Rectangle().fill(Theme.pink).frame(height: 5).rotationEffect(.degrees(-8)))
    }

    private func stat(_ v: String, _ l: String, _ c: Color = Theme.ice) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3.monospacedDigit().weight(.heavy)).foregroundStyle(c)
            Text(l).font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
        }
    }
}

/// Segmented LED RPM bar: cyan, then amber, then pink near the limiter.
private struct RPMBar: View {
    let rpm: Int
    private let segments = 24
    private let maxRpm = 7000.0

    var body: some View {
        let lit = Int((Double(rpm) / maxRpm * Double(segments)).rounded())
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { i in
                let f = Double(i) / Double(segments)
                let c: Color = f < 0.6 ? Theme.cyan : (f < 0.85 ? .orange : Theme.pink)
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < lit ? c : Color.white.opacity(0.08))
                    .shadow(color: i < lit ? c : .clear, radius: 4)
            }
        }
    }
}

private struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(LinearGradient(colors: [Theme.blue, Theme.cyan], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * min(max(fraction, 0), 1))
                    .shadow(color: Theme.cyan, radius: 6)
            }
        }
    }
}

/// Speed streaks rushing past, faster and denser with speed.
private struct SpeedStreaks: View {
    let speed: Int
    let t: Double

    var body: some View {
        Canvas { ctx, size in
            let v = 300 + Double(speed) * 22
            let n = 40
            for i in 0..<n {
                // Stable pseudo-random column and phase per streak.
                let seed = Double((i * 7919) % 1000) / 1000
                let x = size.width * Double((i * 104729) % 997) / 997
                let len = 40 + 120 * seed + Double(speed) * 1.2
                let y = (t * v * (0.6 + seed) + seed * size.height).truncatingRemainder(dividingBy: size.height + len) - len
                var p = Path()
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x, y: y + len))
                ctx.stroke(p, with: .linearGradient(Gradient(colors: [.clear, Theme.cyan.opacity(0.7)]),
                                                    startPoint: CGPoint(x: x, y: y), endPoint: CGPoint(x: x, y: y + len)),
                           lineWidth: 1 + 2 * seed)
            }
        }
    }
}

/// Expanding rings when the run finishes.
private struct Shockwave: View {
    let age: Double

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for k in 0..<4 {
                let a = age - Double(k) * 0.18
                guard a > 0, a < 1.6 else { continue }
                let r = a * 520
                let op = max(0, 1 - a / 1.6)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(Theme.cyan.opacity(op)), lineWidth: 6 * op + 1)
            }
        }
    }
}
