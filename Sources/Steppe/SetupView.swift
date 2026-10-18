import AppKit
import SteppeCore
import SwiftUI

struct SetupView: View {
    @EnvironmentObject var controller: SteppeController

    private static let titles: [SetupStage: LocalizedStringKey] = [
        .checkMac: "Check your Mac",
        .engine: "Download the game engine",
        .frameworks: "Graphics libraries",
        .prefix: "Windows environment",
        .steamClient: "Install Steam",
        .signIn: "Sign in to Steam",
        .game: "Download Cossacks 3",
    ]

    private var failedMessage: String? {
        if case .failed(let message) = controller.phase { return message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Brand()
                Spacer()
                Text(verbatim: "\(Int(overall * 100))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            ThinProgress(value: overall)

            Card {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(SetupStage.allCases) { stage in
                        StageRow(title: Self.titles[stage] ?? "", state: controller.stages[stage] ?? .pending)
                    }
                }
            }

            prompt

            Spacer(minLength: 0)

            HStack {
                if failedMessage == nil {
                    if controller.downloadSpeed > 0, isDownloading {
                        Text("\(speedText)/s")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                if failedMessage != nil {
                    Button("Copy Diagnostics") { copyDiagnostics() }.buttonStyle(SecondaryButtonStyle())
                    Button("Try Again") { controller.startSetup() }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Cancel") { controller.cancelSetup() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(32)
    }

    private var speedText: String { ByteCountFormatter.gigabytes(Int64(controller.downloadSpeed)) }

    private var isDownloading: Bool {
        for stage in [SetupStage.engine, .frameworks, .steamClient] {
            if case .running(let p, _) = controller.stages[stage] ?? .pending, p != nil { return true }
        }
        return false
    }

    /// Weighted overall progress across all stages.
    private var overall: Double {
        let weights: [SetupStage: Double] = [.checkMac: 0.02, .engine: 0.20, .frameworks: 0.10, .prefix: 0.08, .steamClient: 0.10, .signIn: 0.05, .game: 0.45]
        var total = 0.0
        for stage in SetupStage.allCases {
            let weight = weights[stage] ?? 0
            switch controller.stages[stage] ?? .pending {
            case .done: total += weight
            case .running(let p, _): total += weight * (p ?? 0.5)
            default: break
            }
        }
        return min(1, total)
    }

    @ViewBuilder private var prompt: some View {
        if controller.rosettaMissing {
            promptCard(symbol: "cpu", title: "Rosetta 2 is needed",
                       text: "Steppe runs the Windows version of the game through Rosetta, Apple's translation layer. macOS will ask for your password to install it.") {
                Button("Install Rosetta") { controller.installRosetta() }.buttonStyle(PrimaryButtonStyle())
            }
        } else if case .waitingForUser = controller.stages[.signIn] ?? .pending {
            promptCard(symbol: "person.badge.key.fill", title: "Sign in to Steam",
                       text: "A Steam window opens in a moment. Sign in with your own account. Your password goes only to Steam and never touches Steppe.") {
                Button("Show Steam Window") { controller.openSteam() }.buttonStyle(SecondaryButtonStyle())
            }
        } else if case .waitingForUser(let message) = controller.stages[.game] ?? .pending {
            if message == L("Steam is not running — open it to continue") {
                promptCard(symbol: "exclamationmark.arrow.circlepath", title: "Steam needs your attention",
                           text: "Steam was closed. Open it again and the download continues where it stopped.") {
                    Button("Show Steam Window") { controller.openSteam() }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                promptCard(symbol: "arrow.down.app.fill", title: "Install Cossacks 3",
                           text: "Click Install in the Steam window. Steam then downloads the game here. This can take a while.") {
                    Button("Show Steam Window") { controller.openSteam() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func promptCard<Actions: View>(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey, @ViewBuilder actions: () -> Actions) -> some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Theme.amber).frame(width: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    actions().padding(.top, 4)
                }
            }
        }
    }

    private func copyDiagnostics() {
        guard let url = try? controller.exportDiagnostics(), let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
