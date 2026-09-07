import XCTest
@testable import Remit

/// A drag cannot be synthesised in a test, but everything a drag *does* lives in the store, so
/// that is what these pin down: moving a label into and out of a folder, reordering, and the rule
/// that a folder never owns the labels inside it.
@MainActor
final class LabelFolderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RemitFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> MetadataStore { MetadataStore(directory: dir) }

    func testNewLabelsStartUnfiled() throws {
        let sut = store()
        let a = try XCTUnwrap(sut.addLabel(name: "waiting"))

        XCTAssertNil(a.folderID)
        XCTAssertEqual(sut.labels(inFolder: nil).map(\.name), ["waiting"])
    }

    func testMovingALabelIntoAFolder() throws {
        let sut = store()
        let label = try XCTUnwrap(sut.addLabel(name: "Sam"))
        let folder = sut.addLabelFolder(name: "People")

        sut.setFolder(folder.id, forLabel: label.id)

        XCTAssertEqual(sut.labels(inFolder: folder.id).map(\.name), ["Sam"])
        XCTAssertTrue(sut.labels(inFolder: nil).isEmpty)
    }

    func testMovingALabelBackOutOfAFolder() throws {
        let sut = store()
        let label = try XCTUnwrap(sut.addLabel(name: "Sam"))
        let folder = sut.addLabelFolder(name: "People")
        sut.setFolder(folder.id, forLabel: label.id)

        sut.setFolder(nil, forLabel: label.id)

        XCTAssertTrue(sut.labels(inFolder: folder.id).isEmpty)
        XCTAssertEqual(sut.labels(inFolder: nil).map(\.name), ["Sam"])
    }

    /// The rule that makes a folder organisation rather than ownership: deleting it must not take
    /// the labels — or the tasks carrying them — with it.
    func testDeletingAFolderKeepsItsLabels() throws {
        let sut = store()
        let folder = sut.addLabelFolder(name: "People")
        let a = try XCTUnwrap(sut.addLabel(name: "Sam"))
        let b = try XCTUnwrap(sut.addLabel(name: "Leo"))
        sut.setFolder(folder.id, forLabel: a.id)
        sut.setFolder(folder.id, forLabel: b.id)

        sut.removeLabelFolder(folder.id)

        XCTAssertEqual(sut.labels.count, 2)
        XCTAssertEqual(Set(sut.labels(inFolder: nil).map(\.name)), ["Sam", "Leo"])
        XCTAssertTrue(sut.labelFolders.isEmpty)
    }

    func testReorderingWithinAFolder() throws {
        let sut = store()
        let a = try XCTUnwrap(sut.addLabel(name: "a"))
        let b = try XCTUnwrap(sut.addLabel(name: "b"))
        let c = try XCTUnwrap(sut.addLabel(name: "c"))
        XCTAssertEqual(sut.labels(inFolder: nil).map(\.name), ["a", "b", "c"])

        sut.moveLabel(a.id, after: c.id)

        XCTAssertEqual(sut.labels(inFolder: nil).map(\.name), ["b", "c", "a"])
        _ = b
    }

    /// Dropping a label onto one that lives in a folder should file it there, not just reorder it.
    func testDroppingOntoALabelInAFolderMovesItIn() throws {
        let sut = store()
        let folder = sut.addLabelFolder(name: "People")
        let inside = try XCTUnwrap(sut.addLabel(name: "Sam"))
        let outside = try XCTUnwrap(sut.addLabel(name: "waiting"))
        sut.setFolder(folder.id, forLabel: inside.id)

        sut.moveLabel(outside.id, after: inside.id)

        XCTAssertEqual(sut.labels(inFolder: folder.id).map(\.name), ["Sam", "waiting"])
        XCTAssertTrue(sut.labels(inFolder: nil).isEmpty)
    }

    func testDroppingALabelOnItselfIsANoOp() throws {
        let sut = store()
        let a = try XCTUnwrap(sut.addLabel(name: "a"))
        _ = try XCTUnwrap(sut.addLabel(name: "b"))

        sut.moveLabel(a.id, after: a.id)

        XCTAssertEqual(sut.labels(inFolder: nil).map(\.name), ["a", "b"])
    }

    func testFolderOrderingMoves() {
        let sut = store()
        let first = sut.addLabelFolder(name: "First")
        let second = sut.addLabelFolder(name: "Second")
        XCTAssertEqual(sut.labelFolders.map(\.name), ["First", "Second"])

        sut.moveLabelFolder(first.id, by: 1)

        XCTAssertEqual(sut.labelFolders.map(\.name), ["Second", "First"])
        _ = second
    }

    func testMovingAFolderPastTheEndIsClamped() {
        let sut = store()
        let a = sut.addLabelFolder(name: "A")
        _ = sut.addLabelFolder(name: "B")

        sut.moveLabelFolder(a.id, by: 99)

        XCTAssertEqual(sut.labelFolders.map(\.name), ["B", "A"])
    }

    /// Folders arrived after labels did, so an older file has no labelFolders key and no folderID
    /// on its labels. Both must still load.
    func testFileWrittenBeforeFoldersExistedStillLoads() throws {
        let legacy = """
        {
          "labels": [{"id":"l1","name":"waiting","color":"purple","order":0}],
          "projects": {}
        }
        """
        try legacy.write(
            to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8
        )

        let sut = store()

        XCTAssertNil(sut.storageWarning)
        XCTAssertEqual(sut.labels.map(\.name), ["waiting"])
        XCTAssertNil(sut.labels.first?.folderID)
        XCTAssertTrue(sut.labelFolders.isEmpty)
    }

    func testFoldersSurviveReload() throws {
        let sut = store()
        let folder = sut.addLabelFolder(name: "People")
        let label = try XCTUnwrap(sut.addLabel(name: "Sam"))
        sut.setFolder(folder.id, forLabel: label.id)

        let reloaded = store()

        XCTAssertEqual(reloaded.labelFolders.map(\.name), ["People"])
        XCTAssertEqual(reloaded.labels(inFolder: folder.id).map(\.name), ["Sam"])
    }
}
