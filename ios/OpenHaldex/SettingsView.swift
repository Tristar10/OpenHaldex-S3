import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var link: HaldexLink
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    HStack { Text("Status"); Spacer(); ConnectionBadge() }
                    Toggle("Demo data (no car)", isOn: Binding(
                        get: { link.state == .demo },
                        set: { link.setDemo($0) }))
                    Button("Reconnect") { link.disconnect(); link.startScan() }
                }
                Section {
                    Stepper("Warn at \(settings.shiftWarnRpm) rpm", value: $settings.shiftWarnRpm,
                            in: 2000...9000, step: 100)
                    Stepper("Shift at \(settings.shiftRpm) rpm", value: $settings.shiftRpm,
                            in: 2000...9000, step: 100)
                    Stepper("Gauge max \(settings.maxRpm) rpm", value: $settings.maxRpm,
                            in: 4000...10000, step: 250)
                    Toggle("Haptic", isOn: $settings.shiftHaptic)
                    Toggle("Tone", isOn: $settings.shiftTone)
                } header: {
                    Text("Shift cue")
                } footer: {
                    Text("Fires once per pull when rpm crosses the shift point; re-arms 500 rpm below it.")
                }
                Section("Units") {
                    Toggle("MPH", isOn: $settings.useMph)
                }
                Section {
                    Text("Mode changes and presets need the OpenHaldex control service (next firmware step). While this app is connected, RaceChrono can't connect at the same time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
