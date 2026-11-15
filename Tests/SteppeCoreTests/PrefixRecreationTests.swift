import XCTest
@testable import SteppeCore

/// A prefix that lost its marker or registry must never be rebuilt over what the player made in it.
final class PrefixRecreationTests: XCTestCase {
    private var root: URL!
    private var paths: SteppePaths!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-recreate-\(UUID().uuidString)")
        paths = SteppePaths(root: root)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testRecreatingAPrefixThatHoldsGameSavesIsRefusedAndKeepsThem() async throws {
        let fm = FileManager.default
        let save = paths.driveC.appendingPathComponent("users/steppe/Documents/cossacks/save/campaign.sav")
        try fm.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: save)

        do {
            try await PrefixBuilder.create(runner: WineRunner(paths: paths), environment: [:])
            XCTFail("expected the creation to be refused")
        } catch PrefixError.refusingToDeleteGameData {
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: save), Data("progress".utf8), "the save must still be there")
    }
}
