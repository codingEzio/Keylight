import SwiftUI

// One appearance and geometry contract for app search and inline commands.
struct LauncherAppearance {
    static let width: CGFloat = 560
    static let headerHeight: CGFloat = 68
    static let resultsHeight: CGFloat = 350
    static let height = headerHeight + resultsHeight

    let theme: String
    let dark: Bool
    var cyber: Bool { theme == "Cyberpunk 2077" }
    var nothing: Bool { theme == "Nothing" }
    var xp: Bool { theme == "Windows XP" }
    var foreground: Color { cyber || nothing || xp ? (dark ? .white : .black) : .primary }
    var headerForeground: Color { xp ? .white : foreground }
    var accent: Color {
        if nothing { return dark ? Color(red: 0.91, green: 0.35, blue: 0.30) : Color(red: 0.70, green: 0.15, blue: 0.13) }
        if cyber { return dark ? Color(red: 1, green: 0.48, blue: 0.48) : Color(red: 0.55, green: 0.04, blue: 0.08) }
        return .accentColor
    }
    var selection: Color {
        if cyber { return dark ? Color(red: 0.36, green: 0.34, blue: 0.20) : Color(red: 0.80, green: 0.76, blue: 0.59) }
        if nothing { return dark ? .white.opacity(0.12) : .black.opacity(0.07) }
        if xp { return dark ? Color(red: 0.15, green: 0.30, blue: 0.53) : Color(red: 0.78, green: 0.86, blue: 0.97) }
        return Color.accentColor.opacity(0.2)
    }
    var rowForeground: Color { cyber ? accent : foreground }
    var background: Color {
        if cyber { return dark ? Color(red: 0.055, green: 0.055, blue: 0.065) : Color(red: 0.96, green: 0.94, blue: 0.90) }
        if nothing { return dark ? Color(red: 0.055, green: 0.055, blue: 0.06) : Color(red: 0.96, green: 0.96, blue: 0.95) }
        return dark ? Color(red: 0.12, green: 0.15, blue: 0.20) : Color(red: 0.94, green: 0.95, blue: 0.98)
    }
    var cornerRadius: CGFloat { xp ? 6 : cyber ? 5 : 18 }
    var rowCornerRadius: CGFloat { nothing ? 22 : xp ? 2 : cyber ? 3 : 9 }
    var border: Color {
        if nothing { return foreground.opacity(dark ? 0.16 : 0.10) }
        return cyber ? .red.opacity(dark ? 0.30 : 0.20) : .blue.opacity(dark ? 0.38 : 0.25)
    }
    var rowFont: Font { cyber ? .custom("AvenirNextCondensed-DemiBold", size: 18) : nothing ? .system(size: 16, weight: .medium) : xp ? .custom("Tahoma", size: 16) : .system(size: 17, weight: .medium) }
    var inputFont: Font { cyber ? .custom("AvenirNextCondensed-DemiBold", size: 23) : nothing ? .custom("Doto-Black", size: 22) : xp ? .custom("Tahoma", size: 21) : .system(size: 22) }
    var placeholderFont: Font { .system(size: 15, weight: .regular) }
}

struct LauncherHeader<Content: View>: View {
    let appearance: LauncherAppearance
    var showSearchIcon = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 12) {
            if showSearchIcon {
                if appearance.nothing { NothingSearchIcon() }
                else { Image(systemName: "magnifyingglass").font(.system(size: 20)) }
            }
            content()
        }
        .font(appearance.inputFont).foregroundStyle(appearance.headerForeground)
        .frame(height: 44).padding(.horizontal, appearance.nothing ? 15 : 18)
        .background {
            if appearance.nothing {
                Capsule().fill(appearance.foreground.opacity(appearance.dark ? 0.07 : 0.05))
                    .overlay(Capsule().stroke(appearance.foreground.opacity(0.10), lineWidth: 1))
            }
        }
        .padding(.horizontal, appearance.nothing ? 14 : 0)
        .frame(height: LauncherAppearance.headerHeight)
        .background { if appearance.xp { Color(red: 0.16, green: 0.25, blue: 0.39) } }
        .overlay(alignment: .bottom) { if !appearance.nothing { Divider() } }
    }
}
