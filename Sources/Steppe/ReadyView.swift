import SteppeCore
import SwiftUI

struct ReadyView: View {
    @EnvironmentObject var controller: SteppeController
    @EnvironmentObject var updater: UpdaterModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Brand()
                Spacer()
                Button {
                    updater.check()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Check for Updates…")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!updater.canCheck)
                .help(Text("Check for Updates…"))

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(Text("Settings"))
            }

            Spacer()

            VStack(spacing: 8) {
                Text("Cossacks 3")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Ready to play")
                    .font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
            }

            Button {
                controller.play()
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .keyboardShortcut(.defaultAction)
            .padding(.top, 26)

            VStack(spacing: 10) {
                Picker("", selection: $controller.settings.preset) {
                    Text("Performance").tag(PerformancePreset.performance)
                    Text("Balanced").tag(PerformancePreset.balanced)
                    Text("Quality").tag(PerformancePreset.quality)
                    Text("Native").tag(PerformancePreset.native)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
                .disabled(controller.settings.useCustomResolution)

                Text(resolutionCaption)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 30)

            if let note = controller.lastSessionNote {
                Card(padding: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(Theme.warning)
                        Text(verbatim: note).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                    }
                }
                .padding(.top, 14)
            }

            Spacer()

            Text("Settings are applied for your current screen every time you press Play.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary.opacity(0.8))
        }
        .padding(28)
    }

    private var resolutionCaption: String {
        let res = controller.plannedResolution.description
        if let name = controller.display?.name {
            return String(localized: "Renders at \(res) on \(name)")
        }
        return String(localized: "Renders at \(res)")
    }
}
