import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    /// RPM where the shift light starts building (amber).
    @AppStorage("shiftWarnRpm") var shiftWarnRpm: Int = 5800
    /// RPM where the shift cue fires (red flash, haptic, tone).
    @AppStorage("shiftRpm") var shiftRpm: Int = 6600
    /// Gauge redline / max scale.
    @AppStorage("maxRpm") var maxRpm: Int = 7500
    @AppStorage("shiftHaptic") var shiftHaptic: Bool = true
    @AppStorage("shiftTone") var shiftTone: Bool = true
    @AppStorage("useMph") var useMph: Bool = true
}
