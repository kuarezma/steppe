import AppKit
import Foundation
import SteppeCore

// Developer / CI helper: drives the same code the app uses, without a window.
//
//   steppe-cli status      [--root DIR] [--native DIR]
//   steppe-cli setup       [--root DIR] [--native DIR]   installs; stops being interactive at the Steam sign-in
//   steppe-cli play        [--root DIR] [--native DIR]
//   steppe-cli diagnostics [--root DIR]
//   steppe-cli resolution  WIDTH HEIGHT [preset]

func argument(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

setvbuf(stdout, nil, _IOLBF, 0)
let command = CommandLine.arguments.dropFirst().first ?? "status"

if command == "resolution" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count >= 2, let w = Int(args[0]), let h = Int(args[1]) else { fail("usage: steppe-cli resolution WIDTH HEIGHT [preset]") }
    let presets: [PerformancePreset] = args.count > 2 ? PerformancePreset(rawValue: args[2]).map { [$0] } ?? [] : PerformancePreset.allCases
    for preset in presets {
        print("\(preset.rawValue): \(ResolutionPlanner.plan(display: Resolution(width: w, height: h), preset: preset))")
    }
    exit(0)
}

let root = argument("--root").map { URL(fileURLWithPath: $0, isDirectory: true) }
let native = argument("--native").map { URL(fileURLWithPath: $0, isDirectory: true) }
let stopAtSignIn = CommandLine.arguments.contains("--stop-at-sign-in")

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
func run() async {
    let controller = SteppeController(nativeDir: native, defaults: UserDefaults(suiteName: "steppe-cli") ?? .standard, rootOverride: root)
    await controller.refresh()

    switch command {
    case "status":
        print("phase: \(controller.phase)")
        for stage in SetupStage.allCases { print("  \(stage): \(describe(controller.stages[stage] ?? .pending))") }
        print("planned resolution: \(controller.plannedResolution)")
    case "setup":
        controller.startSetup()
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
    case "play":
        controller.play()
        guard case .playing = controller.phase else {
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
    default:
        fail("unknown command \(command)")
    }
}

NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in
    await run()
    exit(0)
}
RunLoop.main.run()
