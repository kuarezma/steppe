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
