import Foundation

public struct Resolution: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    public var pixels: Int { width * height }
    public var description: String { "\(width)×\(height)" }
}

public enum PerformancePreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case performance, balanced, quality, native
    public var id: String { rawValue }

    /// Upper bound for the number of pixels rendered per frame. `nil` = no limit.
    ///
    /// `balanced` equals 1710×1112, the setting measured to run smoothest on an M3 MacBook Pro.
    public var pixelBudget: Int? {
        switch self {
        case .performance: return 1_280 * 720
        case .balanced: return 1_710 * 1_112
        case .quality: return 2_560 * 1_440
        case .native: return nil
        }
    }
}

public enum ResolutionPlanner {
    public static let minimum = Resolution(width: 1024, height: 576)

    /// Picks the game's render resolution for a display, keeping its aspect ratio.
    public static func plan(display: Resolution, preset: PerformancePreset) -> Resolution {
        let base = Resolution(width: max(display.width, minimum.width), height: max(display.height, minimum.height))
        guard let budget = preset.pixelBudget, base.pixels > budget else { return even(base) }
        let scale = (Double(budget) / Double(base.pixels)).squareRoot()
        let scaled = Resolution(
            width: Int((Double(base.width) * scale).rounded(.down)),
            height: Int((Double(base.height) * scale).rounded(.down))
        )
        return even(Resolution(width: max(scaled.width, minimum.width), height: max(scaled.height, minimum.height)))
    }

    private static func even(_ r: Resolution) -> Resolution {
        Resolution(width: r.width & ~1, height: r.height & ~1)
    }

    /// Resolutions offered in the settings picker for a display.
    public static func choices(display: Resolution) -> [Resolution] {
        var seen = Set<Resolution>()
        var result: [Resolution] = []
        for preset in PerformancePreset.allCases {
            let r = plan(display: display, preset: preset)
            if seen.insert(r).inserted { result.append(r) }
        }
        return result.sorted { $0.pixels < $1.pixels }
    }
}

/// The display modes Windows programs in the prefix can enumerate, as reported by `list-modes.exe`.
///
/// The game looks its configured resolution up among these modes and crashes (null write at 00427A2B)
/// when it is missing, so Steppe only writes a resolution from this list.
public struct DisplayModes: Equatable, Sendable {
    /// Current mode of the primary Windows monitor: the display the game runs on.
    public let current: Resolution
    /// Unique modes in the order reported; always contains `current`.
    public let all: [Resolution]

    /// Parses `current W H` and `mode W H` lines; other lines are ignored. `nil` without a usable current mode.
    public static func parse(_ output: String) -> DisplayModes? {
        var current: Resolution?
        var all: [Resolution] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 3, let w = Int(fields[1]), let h = Int(fields[2]), w > 0, h > 0 else { continue }
            let mode = Resolution(width: w, height: h)
            switch fields[0] {
            case "current": current = mode
            case "mode": if !all.contains(mode) { all.append(mode) }
            default: continue
            }
        }
        guard let current else { return nil }
        if !all.contains(current) { all.insert(current, at: 0) }
        return DisplayModes(current: current, all: all)
    }

    /// `planned` if Windows can enumerate it; otherwise the largest mode of the monitor's shape that is
    /// no bigger, or the smallest mode of that shape when none fits.
    public func snap(_ planned: Resolution) -> Resolution {
        if all.contains(planned) { return planned }
        let shape = Self.aspect(current)
        let sameShape = all.filter { abs(Self.aspect($0) - shape) <= shape * 0.03 }
        let fitting = sameShape.filter { $0.pixels <= planned.pixels }
        return fitting.max { $0.pixels < $1.pixels } ?? sameShape.min { $0.pixels < $1.pixels } ?? current
    }

    private static func aspect(_ r: Resolution) -> Double { Double(r.width) / Double(r.height) }
}
