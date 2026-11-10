import XCTest
@testable import SteppeCore

/// A prefix that lost its marker or registry is rebuilt from scratch; what the player made in it must survive.
final class PrefixRecreationTests: XCTestCase {
    private var root: URL!
    private var paths: SteppePaths!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-recreate-\(UUID().uuidString)")
        paths = SteppePaths(root: root)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func files(named name: String) -> [URL] {
        let prefixes = paths.prefixDir.deletingLastPathComponent()
        let all = FileManager.default.enumerator(at: prefixes, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return all.filter { $0.lastPathComponent == name }
    }

    func testRecreatingADamagedPrefixKeepsGameSaves() async throws {
        let fm = FileManager.default
        let save = paths.driveC.appendingPathComponent("users/steppe/Documents/cossacks/save/campaign.sav")
        try fm.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: save)

        // No engine is installed here, so creation fails right after the old prefix was dealt with.
        do {
            try await PrefixBuilder.create(runner: WineRunner(paths: paths), environment: [:])
            XCTFail("expected creation to fail without an engine")
        } catch {}

        let kept = files(named: "campaign.sav")
        XCTAssertEqual(kept.count, 1, "the save must still exist")
        XCTAssertEqual(try kept.first.map { try Data(contentsOf: $0) }, Data("progress".utf8))
        XCTAssertFalse(fm.fileExists(atPath: save.path), "the new prefix starts empty")
    }

    func testAnIncompletePrefixWithoutDocumentsIsReplacedWithoutLeftovers() throws {
        let fm = FileManager.default
        let leftover = paths.driveC.appendingPathComponent("windows/win.ini")
        try fm.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: leftover)

        XCTAssertNil(try PrefixBuilder.clearForCreation(paths: paths))

        XCTAssertFalse(fm.fileExists(atPath: paths.prefixDir.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: paths.prefixDir.deletingLastPathComponent().path), [])
    }

    func testNothingToClearWhenNoPrefixExists() throws {
        XCTAssertNil(try PrefixBuilder.clearForCreation(paths: paths))
    }
}
