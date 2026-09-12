import SQLite3
import XCTest
@testable import RemindersNative

/// The reader runs against the user's real Reminders store, so every behaviour is pinned here
/// against a small store built on disk with the same tables and columns Reminders uses. None of
/// these touch the real store.
final class RemindersDatabaseTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("Data-TEST.sqlite") }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RemitStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(_ statements: [String]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = [
            "CREATE TABLE ZREMCDREMINDER (Z_PK INTEGER PRIMARY KEY, ZCKIDENTIFIER TEXT, ZMARKEDFORDELETION INTEGER)",
            "CREATE TABLE ZREMCDBASELIST (Z_PK INTEGER PRIMARY KEY, ZCKIDENTIFIER TEXT, ZNAME TEXT, ZISGROUP INTEGER, ZPARENTLIST INTEGER, ZMARKEDFORDELETION INTEGER, ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA BLOB)",
            "CREATE TABLE ZREMCDBASESECTION (Z_PK INTEGER PRIMARY KEY, ZCKIDENTIFIER TEXT, ZDISPLAYNAME TEXT, ZLIST INTEGER, ZMARKEDFORDELETION INTEGER)",
            "CREATE TABLE ZREMCDHASHTAGLABEL (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT)",
            "CREATE TABLE ZREMCDOBJECT (Z_PK INTEGER PRIMARY KEY, ZREMINDER3 INTEGER, ZHASHTAGLABEL INTEGER, ZMARKEDFORDELETION INTEGER)",
        ]
        for sql in schema + statements {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
    }

    private func load() throws -> RemindersSnapshot {
        try RemindersDatabase.load(file: file).get()
    }

    private func membershipBlob(_ entries: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["memberships": entries])
        return "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
    }

    // MARK: - Tags

    func testTagsJoinToTheirReminderByIdentifier() throws {
        try makeStore([
            "INSERT INTO ZREMCDREMINDER VALUES (1, 'aaaa-1', 0)",
            "INSERT INTO ZREMCDREMINDER VALUES (2, 'BBBB-2', 0)",
            "INSERT INTO ZREMCDHASHTAGLABEL VALUES (10, 'Sam👤')",
            "INSERT INTO ZREMCDHASHTAGLABEL VALUES (11, '⏳waiting')",
            "INSERT INTO ZREMCDOBJECT VALUES (100, 1, 10, 0)",
            "INSERT INTO ZREMCDOBJECT VALUES (101, 1, 11, 0)",
            "INSERT INTO ZREMCDOBJECT VALUES (102, 2, 11, 0)",
        ])

        let snapshot = try load()

        // Upper-cased, so a join against EventKit's identifiers can't miss on case.
        XCTAssertEqual(snapshot.tagsByReminder["AAAA-1"], ["Sam👤", "⏳waiting"])
        XCTAssertEqual(snapshot.tagsByReminder["BBBB-2"], ["⏳waiting"])
        XCTAssertEqual(Set(snapshot.tagNames), ["Sam👤", "⏳waiting"])
    }

    func testRemovedTagAssignmentsAndDeletedRemindersAreIgnored() throws {
        try makeStore([
            "INSERT INTO ZREMCDREMINDER VALUES (1, 'LIVE', 0)",
            "INSERT INTO ZREMCDREMINDER VALUES (2, 'GONE', 1)",
            "INSERT INTO ZREMCDHASHTAGLABEL VALUES (10, 'discuss')",
            "INSERT INTO ZREMCDOBJECT VALUES (100, 1, 10, 1)",
            "INSERT INTO ZREMCDOBJECT VALUES (101, 2, 10, 0)",
        ])

        let snapshot = try load()

        XCTAssertNil(snapshot.tagsByReminder["LIVE"], "an assignment marked for deletion is not a tag")
        XCTAssertNil(snapshot.tagsByReminder["GONE"], "a deleted reminder carries no tags")
    }

    // MARK: - Sections

    func testSectionsBelongToTheirListInCreationOrder() throws {
        try makeStore([
            "INSERT INTO ZREMCDBASELIST VALUES (5, 'list-a', 'Movies', 0, NULL, 0, NULL)",
            "INSERT INTO ZREMCDBASESECTION VALUES (21, 'sec-tv', 'TV-Shows', 5, 0)",
            "INSERT INTO ZREMCDBASESECTION VALUES (20, 'sec-movies', 'Movies', 5, 0)",
            "INSERT INTO ZREMCDBASESECTION VALUES (22, 'sec-old', 'Old', 5, 1)",
        ])

        let sections = try load().sectionsByList["LIST-A"] ?? []

        XCTAssertEqual(sections.map(\.name), ["Movies", "TV-Shows"])
        XCTAssertEqual(sections.map(\.order), [0, 1])
    }

    func testNewestMembershipWinsAndObsoleteMeansUnsectioned() throws {
        let blob = membershipBlob([
            ["memberID": "r-moved", "groupID": "sec-a", "isObsolete": false, "modifiedOn": 100],
            ["memberID": "r-moved", "groupID": "sec-b", "isObsolete": false, "modifiedOn": 200],
            ["memberID": "r-left", "groupID": "sec-a", "isObsolete": false, "modifiedOn": 100],
            ["memberID": "r-left", "groupID": "sec-a", "isObsolete": true, "modifiedOn": 300],
            ["memberID": "r-stays", "groupID": "sec-a", "isObsolete": false, "modifiedOn": 50],
        ])
        try makeStore([
            "INSERT INTO ZREMCDBASELIST VALUES (5, 'list-a', 'Work', 0, NULL, 0, \(blob))",
            "INSERT INTO ZREMCDBASESECTION VALUES (20, 'sec-a', 'A', 5, 0)",
            "INSERT INTO ZREMCDBASESECTION VALUES (21, 'sec-b', 'B', 5, 0)",
        ])

        let snapshot = try load()

        XCTAssertEqual(snapshot.sectionByReminder["R-MOVED"], "SEC-B")
        XCTAssertNil(snapshot.sectionByReminder["R-LEFT"], "an obsolete newest entry leaves no section")
        XCTAssertEqual(snapshot.sectionByReminder["R-STAYS"], "SEC-A")
    }

    /// Deleting a section in Reminders leaves its memberships behind. Those must not hide the
    /// reminder under a section that no longer renders.
    func testMembershipInADeletedSectionIsIgnored() throws {
        let blob = membershipBlob([["memberID": "r-1", "groupID": "sec-dead", "isObsolete": false]])
        try makeStore([
            "INSERT INTO ZREMCDBASELIST VALUES (5, 'list-a', 'Work', 0, NULL, 0, \(blob))",
            "INSERT INTO ZREMCDBASESECTION VALUES (20, 'sec-dead', 'Gone', 5, 1)",
        ])

        XCTAssertNil(try load().sectionByReminder["R-1"])
    }

    // MARK: - Groups

    func testListsNestUnderTheirGroup() throws {
        try makeStore([
            "INSERT INTO ZREMCDBASELIST VALUES (1, 'grp-home', 'Home', 1, NULL, 0, NULL)",
            "INSERT INTO ZREMCDBASELIST VALUES (2, 'list-trip', 'Trip Planning', 0, 1, 0, NULL)",
            "INSERT INTO ZREMCDBASELIST VALUES (3, 'list-garden', 'Garden', 0, 1, 0, NULL)",
            "INSERT INTO ZREMCDBASELIST VALUES (4, 'list-inbox', 'Inbox', 0, NULL, 0, NULL)",
        ])

        let snapshot = try load()

        XCTAssertEqual(snapshot.groups.map(\.name), ["Home"])
        XCTAssertEqual(Set(snapshot.groups.first?.listIDs ?? []), ["LIST-TRIP", "LIST-GARDEN"])
        XCTAssertEqual(snapshot.groupByList["LIST-GARDEN"], "GRP-HOME")
        XCTAssertNil(snapshot.groupByList["LIST-INBOX"])
    }

    // MARK: - Access

    func testMissingStoreDirectoryIsReportedAsNoStore() {
        let missing = dir.appendingPathComponent("does-not-exist", isDirectory: true)

        guard case .failure(let error) = RemindersDatabase.load(from: missing) else {
            return XCTFail("a missing store must not load as an empty snapshot")
        }
        XCTAssertEqual(error, .storeNotFound)
    }

    func testDirectoryLoadPicksTheStoreWithReminders() throws {
        try makeStore([
            "INSERT INTO ZREMCDREMINDER VALUES (1, 'REAL', 0)",
            "INSERT INTO ZREMCDHASHTAGLABEL VALUES (10, 'real-tag')",
            "INSERT INTO ZREMCDOBJECT VALUES (100, 1, 10, 0)",
        ])
        // An empty sibling store, as a second account leaves behind.
        var empty: OpaquePointer?
        sqlite3_open(dir.appendingPathComponent("Data-EMPTY.sqlite").path, &empty)
        sqlite3_exec(empty, "CREATE TABLE ZREMCDREMINDER (Z_PK INTEGER PRIMARY KEY, ZCKIDENTIFIER TEXT, ZMARKEDFORDELETION INTEGER)", nil, nil, nil)
        sqlite3_close(empty)

        let snapshot = try RemindersDatabase.load(from: dir).get()

        XCTAssertEqual(snapshot.tagsByReminder["REAL"], ["real-tag"])
    }
}
