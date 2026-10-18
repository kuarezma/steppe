import AppKit
import SwiftUI

/// Visual language of Steppe: a night sky over the steppe, ember-orange accents.
enum Theme {
    static let nightTop = Color(red: 0.047, green: 0.055, blue: 0.110)
    static let nightMid = Color(red: 0.090, green: 0.100, blue: 0.200)
    static let ember = Color(red: 0.240, green: 0.120, blue: 0.100)
    static let amber = Color(red: 0.965, green: 0.690, blue: 0.290)
    static let amberDeep = Color(red: 0.886, green: 0.475, blue: 0.180)
    static let success = Color(red: 0.357, green: 0.816, blue: 0.541)
    static let warning = Color(red: 0.949, green: 0.757, blue: 0.306)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.369)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.62)
    static let panel = Color.white.opacity(0.055)
    static let panelBorder = Color.white.opacity(0.10)

    static var background: some View {
        ZStack {
            LinearGradient(colors: [nightTop, nightMid, ember], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [amberDeep.opacity(0.28), .clear], center: .init(x: 0.5, y: 1.05), startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 20 : 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.10, green: 0.07, blue: 0.03))
            .padding(.horizontal, large ? 44 : 22)
            .padding(.vertical, large ? 15 : 9)
            .background(
                Capsule().fill(LinearGradient(colors: [Theme.amber, Theme.amberDeep], startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
            .shadow(color: Theme.amberDeep.opacity(isEnabled ? 0.45 : 0), radius: configuration.isPressed ? 6 : 16, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .overlay(Capsule().strokeBorder(Theme.panelBorder, lineWidth: 0.5))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.panelBorder, lineWidth: 0.5))
    }
}

struct Chip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.amber)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Theme.panelBorder, lineWidth: 0.5))
    }
}

/// Lets the whole window background drag the window and hides the zoom button (the window has a fixed size).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.backgroundColor = NSColor(red: 0.047, green: 0.055, blue: 0.110, alpha: 1)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
