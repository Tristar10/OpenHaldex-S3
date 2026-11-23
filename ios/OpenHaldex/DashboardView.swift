import AudioToolbox
import SwiftUI
import UIKit

struct DashboardView: View {
    @EnvironmentObject var link: HaldexLink
    @EnvironmentObject var settings: AppSettings
    @State private var shiftArmed = true
    @State private var flashOn = false

    private var t: Telemetry { link.telemetry }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if shiftActive && flashOn {
                    Color.red.opacity(0.35).ignoresSafeArea()
                }
                VStack(spacing: 12) {
                    HStack {
                        ConnectionBadge()
                        Spacer()
                        Text(HaldexMode.label(for: t.mode))
                            .font(.headline.monospaced().bold())
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color.orange.opacity(0.25), in: Capsule())
                    }
                    ShiftLightBar(rpm: t.rpm, warn: settings.shiftWarnRpm, shift: settings.shiftRpm)
                        .frame(height: 22)
                    if landscape {
                        HStack(spacing: 16) {
                            rpmBlock
                            haldexBlock.frame(maxWidth: 280)
                        }
                    } else {
                        rpmBlock
                        haldexBlock
                    }
                    Spacer(minLength: 0)
                }
                .padding()
            }
        }
        .onChange(of: t.rpm) { _, rpm in handleShiftCue(rpm: rpm) }
        .onReceive(Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()) { _ in
            flashOn.toggle()
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var shiftActive: Bool { t.rpm >= settings.shiftRpm }

    private var rpmBlock: some View {
        VStack(spacing: 4) {
            RpmArc(rpm: t.rpm, maxRpm: settings.maxRpm, warn: settings.shiftWarnRpm, shift: settings.shiftRpm)
                .frame(maxWidth: .infinity)
                .aspectRatio(1.25, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Text(verbatim: String(t.rpm))
                            .font(.system(size: 56, weight: .heavy, design: .rounded).monospacedDigit())
                            .foregroundStyle(shiftActive ? .red : .white)
                        Text("RPM").font(.caption).foregroundStyle(.secondary)
                    }
                }
            HStack {
                stat(speedText, settings.useMph ? "MPH" : "KM/H")
                stat(String(format: "%.0f", t.pedalPercent), "PEDAL %")
            }
        }
    }

    private var haldexBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HALDEX").font(.caption.bold()).foregroundStyle(.secondary)
            LockBar(title: "Target", value: t.lockTarget, color: .orange.opacity(0.6))
            LockBar(title: "Actual", value: t.lockActual, color: .orange)
        }
        .padding()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private var speedText: String {
        let v = settings.useMph ? t.speedKmh * 0.621371 : t.speedKmh
        return String(format: "%.0f", v)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Fires once per pull: re-arms when rpm drops 500 below the shift point.
    private func handleShiftCue(rpm: Int) {
        if shiftArmed && rpm >= settings.shiftRpm {
            shiftArmed = false
            if settings.shiftHaptic {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            if settings.shiftTone {
                AudioServicesPlaySystemSound(1016)
            }
        } else if !shiftArmed && rpm < settings.shiftRpm - 500 {
            shiftArmed = true
        }
    }
}

struct ShiftLightBar: View {
    let rpm: Int
    let warn: Int
    let shift: Int
    private let count = 10

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4).fill(color(for: i))
            }
        }
    }

    private func color(for i: Int) -> Color {
        let step = Double(shift - warn) / Double(count)
        let threshold = Double(warn) + step * Double(i)
        guard Double(rpm) >= threshold else { return .white.opacity(0.08) }
        if rpm >= shift { return .red }
        return i < count / 2 ? .green : (i < count - 2 ? .yellow : .red)
    }
}

struct RpmArc: View {
    let rpm: Int
    let maxRpm: Int
    let warn: Int
    let shift: Int

    var body: some View {
        GeometryReader { geo in
            let lw: CGFloat = 16
            ZStack {
                arc(from: 0, to: 1).stroke(Color.white.opacity(0.08), style: .init(lineWidth: lw, lineCap: .round))
                arc(from: frac(shift), to: 1).stroke(Color.red.opacity(0.35), style: .init(lineWidth: lw, lineCap: .butt))
                arc(from: 0, to: frac(rpm))
                    .stroke(rpm >= shift ? Color.red : (rpm >= warn ? .yellow : .orange),
                            style: .init(lineWidth: lw, lineCap: .round))
            }
            .padding(lw)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func frac(_ v: Int) -> Double { min(max(Double(v) / Double(max(maxRpm, 1)), 0), 1) }

    private func arc(from a: Double, to b: Double) -> ArcShape { ArcShape(start: a, end: b) }
}

struct ArcShape: Shape {
    var start: Double
    var end: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width / 2, rect.height / 1.25)
        let c = CGPoint(x: rect.midX, y: rect.minY + r)
        let a0 = Angle.degrees(150 + 240 * start)
        let a1 = Angle.degrees(150 + 240 * end)
        p.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
        return p
    }
}

struct LockBar: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(value)%").font(.subheadline.monospacedDigit().bold())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(max(value, 0), 100)) / 100)
                }
            }
            .frame(height: 12)
        }
    }
}
