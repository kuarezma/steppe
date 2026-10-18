import AppKit
import Combine
import Sparkle
import SteppeCore
import SwiftUI

@main
struct SteppeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = SteppeController(nativeDir: Bundle.main.resourceURL?.appendingPathComponent("Native"))
    @StateObject private var updater = UpdaterModel()

    init() {
        AppLanguage.applyStoredChoice()
    }

    var body: some Scene {
        Window("Steppe", id: "main") {
            RootView()
                .environmentObject(controller)
                .onAppear { delegate.controller = controller }
                .onChange(of: controller.phase) { _, phase in
                    switch phase {
                    case .settingUp, .playing: UpdaterModel.setBusy(true)
                    default: UpdaterModel.setBusy(false)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
            }
            CommandGroup(replacing: .help) {
                Link("Steppe on GitHub", destination: URL(string: "https://github.com/kuarezma/steppe")!)
                Link("Report a Problem", destination: URL(string: "https://github.com/kuarezma/steppe/issues/new/choose")!)
            }
        }

        Settings {
            SettingsView().environmentObject(controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var controller: SteppeController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        let message: (String, String)?
        switch controller.phase {
        case .settingUp:
            message = (String(localized: "Setup is still running"),
                       String(localized: "Downloads continue where they stopped the next time you open Steppe."))
        case .playing:
            message = (String(localized: "Cossacks 3 is still running"),
                       String(localized: "If you quit Steppe now, the game keeps running but Steam will not be closed for you afterwards."))
        default:
            message = nil
        }
        guard let (title, info) = message else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// Wraps Sparkle so updates are checked automatically but never interrupt a setup or a game.
@MainActor
final class UpdaterModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?

    // Sparkle calls the delegate from its own threads, so the busy flag and the held relaunch block share a lock.
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var busy = false
    private nonisolated(unsafe) static var pendingRelaunch: (() -> Void)?

    static func setBusy(_ value: Bool) {
        lock.lock()
        busy = value
        let release = value ? nil : pendingRelaunch
        if !value { pendingRelaunch = nil }
        lock.unlock()
        release?()
    }

    override init() {
        super.init()
        // Development builds (no feed in Info.plist) do not start the updater.
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        let c = SPUStandardUpdaterController(startingUpdater: configured, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        if configured {
            c.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheck)
        }
    }

    func check() { controller?.checkForUpdates(nil) }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        Self.lock.lock()
        let isBusy = Self.busy
        Self.lock.unlock()
        if isBusy && updateCheck == .updatesInBackground {
            throw NSError(domain: "Steppe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Busy with setup or a game"])
        }
    }

    /// An installed update never restarts Steppe underneath a running game or an unfinished setup;
    /// it waits until the app is idle again.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard Self.busy else { return false }
        Self.pendingRelaunch = installHandler
        return true
    }
}


/// The interface language. "Automatic" follows macOS (English unless the system language is Turkish).
/// The choice is stored under its own key and applied at launch, before any text is looked up.
enum AppLanguage: String, CaseIterable, Identifiable {
    case automatic, english, turkish
    var id: String { rawValue }

    static let defaultsKey = "steppeLanguage"

    static var stored: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
    }

    static func applyStoredChoice() {
        switch stored {
        case .automatic: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        case .turkish: UserDefaults.standard.set(["tr"], forKey: "AppleLanguages")
        }
    }

    static func choose(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        applyStoredChoice()
    }

    /// Starts a fresh copy of the app a moment after this one quits.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "sh", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
