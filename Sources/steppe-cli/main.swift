import AppKit
import Foundation
import SteppeCore

// Developer / CI helper: drives the same code the app uses, without a window.
//
//   steppe-cli status      [--root DIR] [--native DIR]
//   steppe-cli setup       [--root DIR] [--native DIR] [--stop-at-sign-in]
//   steppe-cli repair      [--root DIR] [--native DIR] [--stop-at-sign-in]
//   steppe-cli play        [--root DIR] [--native DIR]
//   steppe-cli diagnostics [--root DIR]
//   steppe-cli resolution  WIDTH HEIGHT [preset]
//   steppe-cli notch-hud   [--root DIR] [--enable | --disable]

let usageText = """
Usage:
  steppe-cli status      [--root DIR] [--native DIR]
  steppe-cli setup       [--root DIR] [--native DIR] [--stop-at-sign-in]
  steppe-cli repair      [--root DIR] [--native DIR] [--stop-at-sign-in]
  steppe-cli play        [--root DIR] [--native DIR]
  steppe-cli diagnostics [--root DIR]
  steppe-cli resolution  WIDTH HEIGHT [preset]
  steppe-cli notch-hud   [--root DIR] [--enable | --disable]
  steppe-cli --help
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

setvbuf(stdout, nil, _IOLBF, 0)
let rawArgs = Array(CommandLine.arguments.dropFirst())

if rawArgs.contains("--help") || rawArgs.contains("-h") || rawArgs.first == "help" {
    print(usageText)
    exit(0)
}

let command = rawArgs.first ?? "status"
if command.hasPrefix("-") {
    fail("unknown option: \(command)", code: 2)
}

if command == "resolution" {
    let args = Array(rawArgs.dropFirst())
    for arg in args where arg.hasPrefix("-") {
        fail("unknown option: \(arg)", code: 2)
    }
    guard args.count >= 2, let w = Int(args[0]), let h = Int(args[1]) else {
        fail("usage: steppe-cli resolution WIDTH HEIGHT [preset]", code: 2)
    }
    let presets: [PerformancePreset]
    if args.count > 2 {
        guard args.count == 3, let preset = PerformancePreset(rawValue: args[2]) else {
            fail("unknown preset: \(args[2])", code: 2)
        }
        presets = [preset]
    } else {
        presets = PerformancePreset.allCases
    }
    for preset in presets {
        print("\(preset.rawValue): \(ResolutionPlanner.plan(display: Resolution(width: w, height: h), preset: preset))")
    }
    exit(0)
}

var root: URL?
var native: URL?
var stopAtSignIn = false
var forceEnableNotch: Bool?

var idx = 1
while idx < rawArgs.count {
    let arg = rawArgs[idx]
    switch arg {
    case "--root", "--native":
        guard idx + 1 < rawArgs.count, !rawArgs[idx + 1].hasPrefix("--") else {
            fail("missing value for \(arg)", code: 2)
        }
        let dir = URL(fileURLWithPath: rawArgs[idx + 1], isDirectory: true)
        if arg == "--root" { root = dir } else { native = dir }
        idx += 2
    case "--stop-at-sign-in":
        stopAtSignIn = true
        idx += 1
    case "--enable":
        if forceEnableNotch == false { fail("cannot pass both --enable and --disable", code: 2) }
        forceEnableNotch = true
        idx += 1
    case "--disable":
        if forceEnableNotch == true { fail("cannot pass both --enable and --disable", code: 2) }
        forceEnableNotch = false
        idx += 1
    default:
        if arg.hasPrefix("-") {
            fail("unknown option: \(arg)", code: 2)
        }
        fail("unexpected argument: \(arg)", code: 2)
    }
}

func describe(_ state: StageState) -> String {
    switch state {
    case .pending: return "pending"
    case .running(let p, let d): return "running \(p.map { String(format: "%3.0f%%", $0 * 100) } ?? " ...") \(d)"
    case .waitingForUser(let m): return "WAITING FOR USER: \(m)"
    case .done: return "done"
    case .failed(let m): return "FAILED: \(m)"
    }
}

@MainActor
func monitorSetup(_ controller: SteppeController, stopAtSignIn: Bool) async {
    guard case .settingUp = controller.phase else {
        fail("Setup did not start (phase: \(controller.phase)). Is another Steppe using this folder, or is the Mac unsupported?", code: 2)
    }
    var last = ""
    while true {
        let line = SetupStage.allCases.map { "\($0)=\(describe(controller.stages[$0] ?? .pending))" }.joined(separator: " | ")
        if line != last { print(line); last = line }
        switch controller.phase {
        case .ready: print("READY"); return
        case .failed(let m): fail("SETUP FAILED: \(m)")
        case .needsSetup, .unsupported: fail("SETUP STOPPED (phase: \(controller.phase))", code: 2)
        default: break
        }
        if stopAtSignIn, case .waitingForUser = controller.stages[.signIn] ?? .pending {
            print("STOPPED at Steam sign-in as requested")
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
}

@MainActor
func run() async {
    let controller = SteppeController(nativeDir: native, defaults: UserDefaults(suiteName: "steppe-cli") ?? .standard, rootOverride: root)
    await controller.refresh(allowAutoSetup: false)

    switch command {
    case "status":
        print("phase: \(controller.phase)")
        for stage in SetupStage.allCases { print("  \(stage): \(describe(controller.stages[stage] ?? .pending))") }
        print("planned resolution: \(controller.plannedResolution)")
        print("disk status: \(controller.diskStatus)")
    case "setup":
        controller.startSetup()
        await monitorSetup(controller, stopAtSignIn: stopAtSignIn)
    case "repair":
        controller.repair()
        await monitorSetup(controller, stopAtSignIn: stopAtSignIn)
    case "play":
        controller.play()
        guard case .playing = controller.phase else {
            if let note = controller.lastSessionNote {
                fail("PLAY FAILED: \(note)", code: 2)
            }
            if case .ready = controller.phase {
                fail("Play did not start.", code: 2)
            }
            fail("Play did not start (phase: \(controller.phase)). Run `steppe-cli setup` first.", code: 2)
        }
        var last = ""
        while true {
            let line = "\(controller.phase)"
            if line != last { print(line); last = line }
            if case .ready = controller.phase {
                if let note = controller.lastSessionNote { fail("PLAY FAILED: \(note)") }
                return
            }
            if case .failed(let m) = controller.phase { fail("PLAY FAILED: \(m)") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    case "diagnostics":
        do { print(try controller.exportDiagnostics().path) } catch { fail("\(error)") }
    case "notch-hud":
        guard let gameDir = SteamKit(paths: controller.paths, manifest: RuntimeManifest.current).gameDirectory else {
            fail("Cossacks 3 is not installed in this prefix")
        }
        let enabled = forceEnableNotch ?? DisplayInfo.primary().hasNotch
        let statuses = GameFiles.applyNotchHUD(in: gameDir, enabled: enabled)
        print("notch-hud (\(enabled ? "enabled" : "disabled")): \(statuses)")
    default:
        fail("unknown command: \(command)", code: 2)
    }
}

NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in
    await run()
    exit(0)
}
RunLoop.main.run()
