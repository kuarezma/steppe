import XCTest
@testable import SteppeCore

final class ResolutionPlannerTests: XCTestCase {
    func testBalancedKeepsSmallDisplaysUntouched() {
        let r = ResolutionPlanner.plan(display: Resolution(width: 1710, height: 1112), preset: .balanced)
        XCTAssertEqual(r, Resolution(width: 1710, height: 1112))
        let air = ResolutionPlanner.plan(display: Resolution(width: 1470, height: 956), preset: .balanced)
        XCTAssertEqual(air, Resolution(width: 1470, height: 956))
    }

    func testBalancedScalesLargeDisplaysToPixelBudgetKeepingAspect() {
        let r = ResolutionPlanner.plan(display: Resolution(width: 2560, height: 1440), preset: .balanced)
        XCTAssertLessThanOrEqual(r.pixels, 1_710 * 1_112)
        XCTAssertGreaterThan(r.pixels, 1_710 * 1_112 * 95 / 100)
        XCTAssertEqual(Double(r.width) / Double(r.height), 2560.0 / 1440.0, accuracy: 0.01)
        XCTAssertEqual(r.width % 2, 0)
        XCTAssertEqual(r.height % 2, 0)
    }

    func testPresetsAreOrderedByPixelCount() {
        let display = Resolution(width: 3456, height: 2234)
        let pixels = PerformancePreset.allCases.map { ResolutionPlanner.plan(display: display, preset: $0).pixels }
        XCTAssertEqual(pixels, pixels.sorted())
        XCTAssertEqual(ResolutionPlanner.plan(display: display, preset: .native), Resolution(width: 3456, height: 2234))
    }

    func testNeverGoesBelowMinimum() {
        let r = ResolutionPlanner.plan(display: Resolution(width: 800, height: 600), preset: .performance)
        XCTAssertGreaterThanOrEqual(r.width, ResolutionPlanner.minimum.width)
        XCTAssertGreaterThanOrEqual(r.height, ResolutionPlanner.minimum.height)
    }

    func testChoicesAreUniqueAndSorted() {
        let c = ResolutionPlanner.choices(display: Resolution(width: 3024, height: 1964))
        XCTAssertEqual(Set(c).count, c.count)
        XCTAssertEqual(c.map(\.pixels), c.map(\.pixels).sorted())
    }
}

final class DisplayModesTests: XCTestCase {
    /// `list-modes.exe` output from issue 1: external 1920×1080 display primary, built-in panel 3420×2212 pixels.
    static let issue1Output = """
    current 1920 1080
    mode 800 600
    mode 960 540
    mode 1024 576
    mode 1024 768
    mode 1152 648
    mode 1280 720
    mode 1280 960
    mode 1280 1024
    mode 1344 756
    mode 1344 1008
    mode 1360 768
    mode 1504 846
    mode 1600 900
    mode 1600 1200
    mode 1680 945
    mode 1920 1080
    mode 1920 1080
    mode 2048 1080
    mode 2048 1152
    mode 2304 1296
    mode 2560 1440
    mode 3008 1692
    mode 3200 1800
    mode 3360 1890
    mode 3840 2160

    """

    func testParsesHelperOutputAndDropsDuplicates() throws {
        let modes = try XCTUnwrap(DisplayModes.parse(Self.issue1Output))
        XCTAssertEqual(modes.current, Resolution(width: 1920, height: 1080))
        XCTAssertEqual(modes.all.count, 24)
        XCTAssertEqual(Set(modes.all).count, modes.all.count)
    }

    func testParseIgnoresNoiseAndRejectsEmptyOutput() throws {
        XCTAssertNil(DisplayModes.parse(""))
        XCTAssertNil(DisplayModes.parse("mode 800 600\n"), "without the current mode the primary monitor is unknown")
        XCTAssertNil(DisplayModes.parse("current 0 0\n"))
        let modes = try XCTUnwrap(DisplayModes.parse("wine: noise\r\ncurrent 1280 800\r\nmode x y\r\n"))
        XCTAssertEqual(modes.all, [Resolution(width: 1280, height: 800)], "the current mode is always a valid mode")
    }

    func testSnapKeepsAnEnumeratedMode() throws {
        let modes = try XCTUnwrap(DisplayModes.parse(Self.issue1Output))
        XCTAssertEqual(modes.snap(Resolution(width: 1600, height: 900)), Resolution(width: 1600, height: 900))
    }

    func testSnapPicksTheLargestModeOfTheMonitorsShapeThatIsNotBigger() throws {
        let modes = try XCTUnwrap(DisplayModes.parse(Self.issue1Output))
        XCTAssertEqual(modes.snap(Resolution(width: 1838, height: 1034)), Resolution(width: 1680, height: 945))
        XCTAssertEqual(modes.snap(Resolution(width: 1710, height: 1106)), Resolution(width: 1680, height: 945),
                       "a 16:9 monitor gets a 16:9 mode, not the 4:3 one closest to the planned shape")
    }

    func testSnapNeverReturnsAModeOutsideTheList() throws {
        let modes = try XCTUnwrap(DisplayModes.parse(Self.issue1Output))
        for planned in [Resolution(width: 1710, height: 1106), Resolution(width: 1710, height: 1112), Resolution(width: 640, height: 480),
                        Resolution(width: 7000, height: 3000)] {
            XCTAssertTrue(modes.all.contains(modes.snap(planned)), "\(planned)")
        }
        XCTAssertEqual(modes.snap(Resolution(width: 640, height: 480)), Resolution(width: 960, height: 540), "nothing fits: smallest mode of the monitor's shape")
        XCTAssertEqual(modes.snap(Resolution(width: 7000, height: 3000)), Resolution(width: 3840, height: 2160))
    }

    func testIssue1PlansForTheWindowsMonitorNotTheBuiltInPanel() throws {
        let modes = try XCTUnwrap(DisplayModes.parse(Self.issue1Output))
        let builtIn = Resolution(width: 1710, height: 1106) // NSScreen frame of the 3420×2212 panel, in points
        var settings = AppSettings()
        XCTAssertEqual(settings.resolution(for: builtIn), Resolution(width: 1710, height: 1106), "the crashing value from the issue")
        XCTAssertEqual(settings.resolution(for: builtIn, modes: modes), Resolution(width: 1680, height: 945))

        settings.preset = .native
        XCTAssertEqual(settings.resolution(for: builtIn, modes: modes), Resolution(width: 1920, height: 1080))

        settings.useCustomResolution = true
        XCTAssertEqual(settings.resolution(for: builtIn, modes: modes), Resolution(width: 1680, height: 945),
                       "the default custom 1710×1112 is not a mode here either")
        XCTAssertEqual(settings.resolution(for: builtIn, modes: nil), Resolution(width: 1710, height: 1112), "without a probe nothing changes")
    }
}

final class ProfileConfigTests: XCTestCase {
    static let sample = """
    section.begin
       Engine : struct.begin
          ScreenResolution : struct.begin
             Width = 2560
             Height = 1440
             Frequency = 0
          struct.end
          HDRType = htPseudoHDR
          Sound : struct.begin
             Master = 0.28999999165535
          struct.end
       struct.end
    section.end

    """

    func testReadsResolution() {
        XCTAssertEqual(ProfileConfig.screenResolution(in: Self.sample), Resolution(width: 2560, height: 1440))
    }

    func testReplacesOnlyTheResolutionValues() throws {
        let updated = try XCTUnwrap(ProfileConfig.settingScreenResolution(Resolution(width: 1838, height: 1034), in: Self.sample))
        XCTAssertEqual(ProfileConfig.screenResolution(in: updated), Resolution(width: 1838, height: 1034))
        XCTAssertEqual(
            updated.replacingOccurrences(of: "1838", with: "2560").replacingOccurrences(of: "1034", with: "1440"),
            Self.sample
        )
    }

    func testPreservesWindowsLineEndings() throws {
        let crlf = Self.sample.replacingOccurrences(of: "\n", with: "\r\n")
        let updated = try XCTUnwrap(ProfileConfig.settingScreenResolution(Resolution(width: 1280, height: 720), in: crlf))
        XCTAssertEqual(updated.components(separatedBy: "\r\n").count, crlf.components(separatedBy: "\r\n").count)
        XCTAssertFalse(updated.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
    }

    func testReturnsNilWithoutBlock() {
        XCTAssertNil(ProfileConfig.settingScreenResolution(Resolution(width: 1, height: 1), in: "section.begin\nsection.end\n"))
    }

    func testTunerUpdatesProfilesBacksUpOnceAndIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-tuner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = dir.appendingPathComponent("Alice")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("NoConfig"), withIntermediateDirectories: true)
        let cfg = profile.appendingPathComponent("profile.cfg")
        try Self.sample.write(to: cfg, atomically: true, encoding: .utf8)

        let first = try ProfileTuner.apply(resolution: Resolution(width: 1838, height: 1034), profilesDir: dir)
        XCTAssertEqual(first.updated, ["Alice"])
        let backup = cfg.appendingPathExtension("steppe-orig")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), Self.sample)

        let second = try ProfileTuner.apply(resolution: Resolution(width: 1838, height: 1034), profilesDir: dir)
        XCTAssertEqual(second.unchanged, ["Alice"])

        _ = try ProfileTuner.apply(resolution: Resolution(width: 1280, height: 720), profilesDir: dir)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), Self.sample, "backup must keep the very first original")
    }
}

final class GameBootstrapTests: XCTestCase {
    func testGeneratedConfigIsParsedByTheTuner() throws {
        let cfg = GameBootstrap.profileConfig(resolution: Resolution(width: 1838, height: 1034))
        XCTAssertEqual(ProfileConfig.screenResolution(in: cfg), Resolution(width: 1838, height: 1034))
        XCTAssertTrue(cfg.contains("DOFEnable = False"))
        XCTAssertTrue(cfg.contains("SSAOEnable = False"))
    }

    func testSeedCreatesEverythingOnceAndNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-boot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = Resolution(width: 1710, height: 1112)
        let first = try GameBootstrap.seed(documentsGameDir: dir, profileName: "Alex", locale: "tu", resolution: res)
        XCTAssertEqual(Set(first), ["hardware.info", "video.info", "profiles/Cossack/profile.dat", "profiles/Cossack/profile.cfg",
                                    "profiles/Alex/profile.dat", "profiles/Alex/profile.cfg"])
        let dat = try String(contentsOf: dir.appendingPathComponent("profiles/Alex/profile.dat"), encoding: .utf8)
        XCTAssertTrue(dat.contains("name = Alex"))
        XCTAssertTrue(dat.contains(#"lang = .\data\locale\tu\table.lng"#))
        XCTAssertTrue(dat.contains("\r\n"))

        // A second call must not touch anything, and an existing named profile suppresses a new one.
        let marker = dir.appendingPathComponent("profiles/Alex/profile.cfg")
        try Data("custom".utf8).write(to: marker)
        XCTAssertTrue(try GameBootstrap.seed(documentsGameDir: dir, profileName: "Other", locale: "en", resolution: res).isEmpty)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "custom")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("profiles/Other").path))
    }

    func testLocaleMappingAndFallback() {
        let available = ["cs", "de", "en", "es", "fr", "it", "pl", "po", "ru", "tu", "uk"]
        XCTAssertEqual(GameBootstrap.localeFolder(languageCode: "tr", available: available), "tu")
        XCTAssertEqual(GameBootstrap.localeFolder(languageCode: "pt", available: available), "po")
        XCTAssertEqual(GameBootstrap.localeFolder(languageCode: "de", available: available), "de")
        XCTAssertEqual(GameBootstrap.localeFolder(languageCode: "ja", available: available), "en")
        XCTAssertEqual(GameBootstrap.localeFolder(languageCode: "tr", available: []), "en")
    }

    func testProfileNameSanitizing() {
        XCTAssertEqual(GameBootstrap.sanitizedProfileName("Ayşe ../Yılmaz!"), "Aye Ylmaz")
        XCTAssertEqual(GameBootstrap.sanitizedProfileName(nil), "Player")
        XCTAssertEqual(GameBootstrap.sanitizedProfileName("***"), "Player")
        XCTAssertEqual(GameBootstrap.sanitizedProfileName("cossack"), "Player", "must not collide with the default profile folder")
        XCTAssertEqual(GameBootstrap.sanitizedProfileName("COSSACK"), "Player")
        XCTAssertLessThanOrEqual(GameBootstrap.sanitizedProfileName(String(repeating: "a", count: 80)).count, 24)
    }

    func testPersonaNameParsing() {
        let vdf = """
        "users"
        {
        \t"76561198000000001"
        \t{
        \t\t"AccountName"\t\t"old"
        \t\t"PersonaName"\t\t"Old Name"
        \t\t"MostRecent"\t\t"0"
        \t}
        \t"76561198000000002"
        \t{
        \t\t"AccountName"\t\t"new"
        \t\t"PersonaName"\t\t"Fresh"
        \t\t"MostRecent"\t\t"1"
        \t}
        }
        """
        XCTAssertEqual(GameBootstrap.personaName(fromLoginUsers: vdf), "Fresh")
        XCTAssertNil(GameBootstrap.personaName(fromLoginUsers: "garbage"))
    }

    func testHardwareInfoKeepsConservativeGLFlags() {
        XCTAssertTrue(GameBootstrap.hardwareInfo.contains("GLFBOSupport = False"))
        XCTAssertTrue(GameBootstrap.hardwareInfo.contains(#"AdapterDeviceName = \\.\DISPLAY1"#))
    }
}
