import XCTest
@testable import Remit

/// These cover the two failure modes that used to silently destroy the Remit metadata layer:
/// a file written by an older build (missing keys the current struct declares), and a file that
/// will not decode at all. Both previously resolved to "start empty", and because every mutation
/// calls `persist()`, starting empty meant the next trivial edit overwrote the real file.
@MainActor
final class MetadataStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RemitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var primary: URL { dir.appendingPathComponent("metadata.json") }
    private var backup: URL { dir.appendingPathComponent("metadata.backup.json") }

    private func quarantineFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("metadata.corrupt-") }
    }

    // MARK: - Forward compatibility

    /// A file written by v0.1, before labels/labelAssignments/templates/filters existed. Swift's
    /// synthesised decoder throws `keyNotFound` on the first of those, which is precisely how the
    /// old code lost data.
    func testDecodesFileFromOlderSchemaWithoutLosingKnownFields() throws {
        let legacy = """
        {
          "projects": { "cal-1": { "emoji": "🏠", "sortOrder": 3 } },
          "tasks": {},
          "sections": [],
          "favoriteProjectIDs": ["cal-1"]
        }
        """
        try legacy.write(to: primary, atomically: true, encoding: .utf8)

        let store = MetadataStore(directory: dir)

        XCTAssertNil(store.storageWarning, "a readable older file is not a failure")
        XCTAssertEqual(store.data.projects["cal-1"]?.emoji, "🏠")
        XCTAssertEqual(store.data.projects["cal-1"]?.sortOrder, 3)
        XCTAssertEqual(store.data.favoriteProjectIDs, ["cal-1"])
        // Fields that did not exist in the old file default rather than throwing.
        XCTAssertTrue(store.data.labels.isEmpty)
        XCTAssertTrue(store.data.templates.isEmpty)
        XCTAssertTrue(store.data.filters.isEmpty)
        XCTAssertTrue(store.data.labelAssignments.isEmpty)
        // A file with no version marker is schema 0, not silently claimed as current.
        XCTAssertEqual(store.data.schemaVersion, 0)
    }

    /// The mirror case: a file from a *newer* build carrying keys this build has never heard of
    /// must still load, rather than being treated as corrupt.
    func testUnknownFutureKeysAreIgnoredRatherThanTreatedAsCorruption() throws {
        let future = """
        {
          "schemaVersion": 99,
          "projects": { "cal-9": { "emoji": "🚀", "sortOrder": 1 } },
          "somethingAddedLater": [1, 2, 3]
        }
        """
        try future.write(to: primary, atomically: true, encoding: .utf8)

        let store = MetadataStore(directory: dir)

        XCTAssertNil(store.storageWarning)
        XCTAssertEqual(store.data.projects["cal-9"]?.emoji, "🚀")
        XCTAssertEqual(store.data.schemaVersion, 99)
        XCTAssertTrue(try quarantineFiles().isEmpty, "a loadable file must never be quarantined")
    }

    // MARK: - Corruption handling

    func testCorruptFileIsQuarantinedAndBackupRestored() throws {
        let good = """
        { "schemaVersion": 1, "projects": { "cal-2": { "emoji": "💰", "sortOrder": 0 } } }
        """
        try good.write(to: backup, atomically: true, encoding: .utf8)
        try "{ this is not json".write(to: primary, atomically: true, encoding: .utf8)

        let store = MetadataStore(directory: dir)

        XCTAssertEqual(store.data.projects["cal-2"]?.emoji, "💰", "backup should be restored")
        XCTAssertNotNil(store.storageWarning, "recovery must be reported, never silent")
        XCTAssertEqual(try quarantineFiles().count, 1, "the unreadable file must be preserved")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: primary.path),
            "the corrupt file is moved aside, not left in place to be overwritten"
        )
    }

    func testCorruptFileWithNoBackupResetsButPreservesEvidenceAndWarns() throws {
        try "totally unreadable".write(to: primary, atomically: true, encoding: .utf8)

        let store = MetadataStore(directory: dir)

        XCTAssertTrue(store.data.projects.isEmpty)
        XCTAssertNotNil(store.storageWarning, "a reset the user did not ask for must be reported")
        XCTAssertEqual(try quarantineFiles().count, 1, "the only copy of their data is kept")
    }

    // MARK: - Writing

    func testFirstRunWithNoFileIsNotTreatedAsAnError() throws {
        let store = MetadataStore(directory: dir)

        XCTAssertNil(store.storageWarning, "an absent file is a normal first run, not a failure")
        XCTAssertTrue(store.data.projects.isEmpty)
        XCTAssertTrue(try quarantineFiles().isEmpty)
    }

    /// The safety net for a failed or truncated write: the previous good file is rolled into the
    /// backup slot first, so there is never a moment with zero readable copies on disk.
    func testWriteRollsPreviousFileIntoBackup() throws {
        let store = MetadataStore(directory: dir)
        store.setEmoji("🌟", forProject: "cal-3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))

        store.setEmoji("🔥", forProject: "cal-3")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backup.path),
            "the second write should have preserved the first as a backup"
        )
        let reloaded = MetadataStore(directory: dir)
        XCTAssertEqual(reloaded.data.projects["cal-3"]?.emoji, "🔥")
        XCTAssertNil(reloaded.storageWarning)
    }

    /// A round trip through the encoder must survive re-decoding, which is what actually protects
    /// the user across an app update.
    func testRoundTripPreservesEveryField() throws {
        let store = MetadataStore(directory: dir)
        store.setEmoji("📚", forProject: "cal-4")
        _ = store.addSection(name: "Reading", toProject: "cal-4")
        store.toggleFavorite("cal-4")

        let reloaded = MetadataStore(directory: dir)

        XCTAssertEqual(reloaded.data.projects["cal-4"]?.emoji, "📚")
        XCTAssertEqual(reloaded.data.sections.first?.name, "Reading")
        XCTAssertEqual(reloaded.data.favoriteProjectIDs, ["cal-4"])
        XCTAssertEqual(reloaded.data.schemaVersion, RemitMetadata.currentSchemaVersion)
    }
}
