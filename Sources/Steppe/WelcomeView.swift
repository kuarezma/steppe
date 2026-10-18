import AppKit
import SteppeCore
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var controller: SteppeController

    private var enoughSpace: Bool { controller.freeBytes >= controller.requiredFreeBytesNow }
    private var canInstall: Bool { controller.hasCheckedDisk && enoughSpace }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Brand()

            VStack(alignment: .leading, spacing: 6) {
                Text("Play Cossacks 3 on your Mac")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("One click sets everything up for your Mac and screen. You sign in to your own Steam account; nothing else to configure.")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Chip(symbol: "cpu", text: controller.systemInfo.chipName.replacingOccurrences(of: "Apple ", with: ""))
                Chip(symbol: "memorychip", text: "\(controller.systemInfo.memoryGB) GB")
                if let display = controller.display {
                    Chip(symbol: "display", text: display.size.description)
                }
                Chip(symbol: "sparkles", text: String(localized: "Plays at \(controller.plannedResolution.description)"))
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    bullet("arrow.down.circle", "Downloads a Wine-based engine (about 250 MB) from its official source and checks it")
                    bullet("person.crop.circle.badge.checkmark", "Installs Steam in a separate Windows environment and asks you to sign in")
                    bullet("shippingbox", "Steam downloads Cossacks 3 (about 9 GB) to your Mac. You need to own the game")
                    bullet("lock.shield", "Your Mac's files stay out of reach of the Windows environment")
                }
            }

            Card(padding: 12) {
                HStack {
                    Image(systemName: "externaldrive").foregroundStyle(Theme.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Install location").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(verbatim: controller.paths.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if controller.hasCheckedDisk {
                        Text("\(ByteCountFormatter.gigabytes(controller.freeBytes)) free")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(enoughSpace ? Theme.textSecondary : Theme.danger)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking the disk…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if controller.canChangeInstallLocation {
                        Button("Change…") { chooseFolder() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if controller.hasCheckedDisk && !enoughSpace {
                        Text("About \(ByteCountFormatter.gigabytes(controller.requiredFreeBytesNow)) of free space is needed. Free up space or choose another disk.")
                            .font(.system(size: 11)).foregroundStyle(Theme.danger)
                    }
                    Text("Steppe is an independent project. It is not affiliated with GSC Game World, Valve or Apple.")
                        .font(.system(size: 10)).foregroundStyle(Theme.textSecondary.opacity(0.8))
                }
                Spacer()
                Button("Install & Play") { controller.startSetup() }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInstall)
            }
        }
        .padding(32)
    }

    private func bullet(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(Theme.amber)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where Steppe should keep its files. A folder named Steppe is created there.")
        if panel.runModal() == .OK, let url = panel.url {
            controller.setInstallLocation(url)
            Task { await controller.refresh() }
        }
    }
}
