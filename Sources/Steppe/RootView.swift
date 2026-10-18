import SteppeCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject var controller: SteppeController

    var body: some View {
        ZStack {
            Theme.background
            content
                .transition(.opacity)
        }
        .frame(width: 780, height: 600)
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: phaseKey)
        .task { await controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.refresh() }
        }
    }

    private var phaseKey: String {
        switch controller.phase {
        case .unsupported: return "unsupported"
        case .needsSetup: return "welcome"
        case .settingUp, .failed: return "setup"
        case .ready: return "ready"
        case .playing: return "playing"
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .unsupported(let reason): UnsupportedView(reason: reason)
        case .needsSetup: WelcomeView()
        case .settingUp, .failed: SetupView()
        case .ready: ReadyView()
        case .playing(let detail): PlayingView(detail: detail)
        }
    }
}

struct UnsupportedView: View {
    let reason: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(Theme.warning)
            Text("This Mac can't run Steppe").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
            Text(verbatim: reason).font(.system(size: 14)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

struct PlayingView: View {
    @EnvironmentObject var controller: SteppeController
    let detail: String

    var body: some View {
        VStack(spacing: 18) {
            Brand()
            Spacer()
            ProgressView().controlSize(.large).tint(Theme.amber)
            Text(verbatim: detail)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Cossacks 3 is running. Steppe tidies up when you quit the game.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Force Quit Game") { controller.forceStop() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(32)
    }
}
