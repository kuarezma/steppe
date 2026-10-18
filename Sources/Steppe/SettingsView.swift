import AppKit
import SteppeCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: SteppeController
    @State private var confirmUninstall = false
    @State private var confirmRepair = false
    @State private var toast: String?

    private var busy: Bool {
        switch controller.phase {
        case .settingUp, .playing: return true
        default: return false
        }
    }

    private var resolutionChoices: [Resolution] {
        var list = ResolutionPlanner.choices(display: controller.display?.size ?? Resolution(width: 1440, height: 900))
        if !list.contains(controller.settings.customResolution) { list.append(controller.settings.customResolution) }
        return list.sorted { $0.pixels < $1.pixels }
    }

    var body: some View {
        Form {
            Section("Performance") {
                Picker("Preset", selection: $controller.settings.preset) {
                    Text("Performance").tag(PerformancePreset.performance)
                    Text("Balanced").tag(PerformancePreset.balanced)
                    Text("Quality").tag(PerformancePreset.quality)
                    Text("Native").tag(PerformancePreset.native)
                }
                .disabled(controller.settings.useCustomResolution)
                Text(presetHelp).font(.caption).foregroundStyle(.secondary)

                Toggle("Choose the resolution myself", isOn: $controller.settings.useCustomResolution)
                if controller.settings.useCustomResolution {
                    Picker("Resolution", selection: $controller.settings.customResolution) {
                        ForEach(resolutionChoices, id: \.self) { Text(verbatim: $0.description).tag($0) }
                    }
                }
                LabeledContent("Right now", value: controller.plannedResolution.description)
            }

            Section("Game") {
                Toggle("Quit Steam when the game closes", isOn: $controller.settings.quitSteamAfterGame)
            }

            Section("Advanced") {
                Toggle("Faster geometry code (experimental)", isOn: $controller.settings.experimentalMathPatches)
                Text("Speeds up some of the game's 3D math. It has not been verified for multiplayer, so leave it off if you play online.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Record frame times", isOn: $controller.settings.recordFrameTimes)
                Text("Writes per-frame timings to the logs folder, useful for benchmarks and bug reports.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Speed patches", value: controller.patchReport.isEmpty
                    ? String(localized: "Shown after the first launch")
                    : controller.patchReport.summary)
                LabeledContent("Install folder") {
                    Text(verbatim: controller.paths.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
            }

            Section("Maintenance") {
                HStack {
                    Button("Repair…") { confirmRepair = true }.disabled(busy)
                    Button("Restore Original Audio Files") { restoreAudio() }.disabled(busy)
                }
                HStack {
                    Button("Export Diagnostics") { exportDiagnostics() }
                    Button("Show Logs") { NSWorkspace.shared.open(controller.paths.logsDir) }
                    Button("Open Steppe Folder") { NSWorkspace.shared.open(controller.paths.root) }
                }
                Button("Uninstall Everything…", role: .destructive) { confirmUninstall = true }.disabled(busy)
                if let toast { Text(verbatim: toast).font(.caption).foregroundStyle(.secondary) }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                Link("Project on GitHub", destination: URL(string: "https://github.com/kuarezma/steppe")!)
                Text("Steppe is not affiliated with GSC Game World, Valve or Apple. Cossacks is a trademark of its owners.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
        .preferredColorScheme(.dark)
        .alert("Repair Steppe?", isPresented: $confirmRepair) {
            Button("Repair") { controller.repair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Steppe re-checks the engine and the Windows environment and fixes anything that is missing or damaged. Your game and Steam sign-in are kept.")
        }
        .alert("Uninstall everything?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { Task { await controller.uninstall() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes Steppe's engine, the Windows environment, Steam and the downloaded game from this Mac. Your Steam account and Steam Cloud saves are not affected.")
        }
    }

    private var presetHelp: LocalizedStringKey {
        switch controller.settings.preset {
        case .performance: return "Lowest resolution. Smoothest on any Mac."
        case .balanced: return "Recommended. Sharp enough and smooth on most Macs."
        case .quality: return "Sharper picture; needs a stronger Mac."
        case .native: return "Your screen's full resolution. Can be slow on large displays."
        }
    }

    private func exportDiagnostics() {
        do {
            let url = try controller.exportDiagnostics()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            toast = String(localized: "Diagnostics saved. Personal data is removed from the file.")
        } catch {
            toast = error.localizedDescription
        }
    }

    private func restoreAudio() {
        guard let gameDir = SteamKit(paths: controller.paths).gameDirectory else { return }
        let count = String(GameFiles.restoreOriginals(in: gameDir))
        toast = String(localized: "Restored \(count) original files. They are replaced again on the next launch.")
    }
}
