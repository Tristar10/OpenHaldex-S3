import SwiftUI

/// Colours taken from the car's livery: deep navy, electric royal blue, cyan
/// highlights, white panels and a hot-pink accent.
enum Theme {
    static let navy = Color(red: 0.020, green: 0.035, blue: 0.110)       // #05091C
    static let navyHigh = Color(red: 0.045, green: 0.075, blue: 0.230)   // #0B133B
    static let blue = Color(red: 0.150, green: 0.300, blue: 1.000)       // #264DFF royal blue
    static let cyan = Color(red: 0.400, green: 0.860, blue: 1.000)       // #66DBFF
    static let pink = Color(red: 1.000, green: 0.330, blue: 0.560)       // #FF548F
    static let ice = Color(red: 0.880, green: 0.930, blue: 1.000)        // #E0EDFF

    static let card = Color(red: 0.090, green: 0.140, blue: 0.380).opacity(0.38)
    static let cardStroke = Color(red: 0.400, green: 0.560, blue: 1.000).opacity(0.22)
    static let idle = Color.white.opacity(0.07)

    /// Active controls: royal blue into cyan, like the livery's fade.
    static let activeGradient = LinearGradient(colors: [blue, Color(red: 0.25, green: 0.55, blue: 1.0)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let lockGradient = LinearGradient(colors: [blue, cyan], startPoint: .leading, endPoint: .trailing)
}

/// App-wide background: navy with a soft blue glow from the top, the way the
/// livery fades from white into royal blue.
struct ThemeBackground: View {
    var body: some View {
        ZStack {
            Theme.navy
            RadialGradient(colors: [Theme.blue.opacity(0.35), .clear], center: .top, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [Theme.pink.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Navy livery background behind a ScrollView or Form.
    func themedBackground() -> some View {
        scrollContentBackground(.hidden).background(ThemeBackground())
    }
}

/// Form with the livery background and card-coloured rows.
struct ThemedForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { Group { content }.listRowBackground(Theme.card) }.themedBackground()
    }
}

/// List with the livery background and card-coloured rows.
struct ThemedList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        List { Group { content }.listRowBackground(Theme.card) }.themedBackground()
    }
}
