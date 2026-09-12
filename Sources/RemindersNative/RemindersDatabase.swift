import Foundation
import SQLite3

/// Tags, sections and list groups exactly as Apple Reminders stores them.
///
/// EventKit exposes none of these, so they are read straight from Reminders' own Core Data store,
/// read-only, the way RemCTL does. Nothing here ever writes: every change goes through ReminderKit
/// (see ReminderKitBridge) so Reminders itself stays in charge of sync and schema. Reading the store
/// needs Full Disk Access -- it lives in a TCC-protected group container -- and without it every
/// load reports `.fullDiskAccessRequired` rather than pretending the user has no tags.
///
/// Identifiers are ReminderKit object UUIDs, which are the same strings EventKit hands out as
/// `calendarItemIdentifier` (reminders) and `calendarIdentifier` (lists). They are upper-cased here
/// so joins against EventKit never depend on the case either side happens to use.
public struct RemindersSnapshot: Equatable, Sendable {
    public struct Section: Equatable, Identifiable, Sendable {
        public let id: String
        public let listID: String
        public var name: String
        public var order: Int
    }

    public struct Group: Equatable, Identifiable, Sendable {
        public let id: String
        public var name: String
        public var listIDs: [String]
    }

    /// Reminder id -> tag names, in the order Reminders recorded them.
    public var tagsByReminder: [String: [String]] = [:]
    /// Every tag at least one reminder carries, sorted for display.
    public var tagNames: [String] = []
    /// List id -> its sections, in display order.
    public var sectionsByList: [String: [Section]] = [:]
    /// Reminder id -> the section it currently belongs to. May name a section in a list the
    /// reminder has since left; callers check the section's `listID` against the reminder's list.
    public var sectionByReminder: [String: String] = [:]
    public var groups: [Group] = []
    /// List id -> the group containing it.
    public var groupByList: [String: String] = [:]

    public init() {}
}

public enum RemindersDatabaseError: Error, Equatable, Sendable {
    /// macOS refused to let this process read Reminders' group container.
    case fullDiskAccessRequired
    /// No Reminders store exists -- iCloud Reminders has never been set up on this Mac.
    case storeNotFound
    case unreadable(String)
}

public enum RemindersDatabase {
    public static var storeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Group Containers/group.com.apple.reminders/Container_v1/Stores",
            isDirectory: true
        )
    }

    public static func load(from directory: URL = storeDirectory) -> Result<RemindersSnapshot, RemindersDatabaseError> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            return .failure(classify(error))
        }

        let candidates = names
            .filter { $0.hasPrefix("Data-") && $0.hasSuffix(".sqlite") }
            .map { directory.appendingPathComponent($0) }
        guard !candidates.isEmpty else { return .failure(.storeNotFound) }

        // Several stores can exist side by side (one per account, plus leftovers). The one holding
        // the most live reminders is the real one -- the same heuristic RemCTL scores stores with.
        var best: (reader: SQLiteReader, count: Int64)?
        var lastError = "no readable Reminders store"
        for url in candidates {
            guard let reader = SQLiteReader(url: url) else {
                lastError = "could not open \(url.lastPathComponent)"
                continue
            }
            guard reader.tableExists("ZREMCDREMINDER") else { continue }
            let count = reader.scalar(
                "SELECT COUNT(*) FROM ZREMCDREMINDER WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0"
            ) ?? 0
            if best == nil || count > best!.count { best = (reader, count) }
        }
        guard let reader = best?.reader else { return .failure(.unreadable(lastError)) }
        return snapshot(from: reader)
    }

    /// Opens one specific store file. Exposed for tests, which build a minimal store on disk.
    public static func load(file url: URL) -> Result<RemindersSnapshot, RemindersDatabaseError> {
        guard let reader = SQLiteReader(url: url) else { return .failure(.unreadable("could not open store")) }
        return snapshot(from: reader)
    }

    private static func classify(_ error: Error) -> RemindersDatabaseError {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
            return .storeNotFound
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return .fullDiskAccessRequired
        }
        if let underlying, underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EPERM) || underlying.code == Int(EACCES) {
            return .fullDiskAccessRequired
        }
        return .unreadable(nsError.localizedDescription)
    }

    // MARK: - Reading

    /// A query that fails to prepare is reported, never treated as "no rows". Reminders' schema is
    /// private and can change under an OS update; silently reading nothing would look like every
    /// section had vanished, and would hand the write paths an empty starting point.
    static func snapshot(from db: SQLiteReader) -> Result<RemindersSnapshot, RemindersDatabaseError> {
        var result = RemindersSnapshot()

        // Lists and groups share ZREMCDBASELIST. Smart lists live there too; they never carry
        // sections of an ordinary list or appear in EventKit, so they fall out of every join.
        let listColumns = db.columns(of: "ZREMCDBASELIST")
        let parentColumns = ["ZPARENTLIST", "ZPARENTLIST1"].filter(listColumns.contains)
        let hasGroups = listColumns.contains("ZISGROUP")
        let membershipColumn = "ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA"
        let hasMemberships = listColumns.contains(membershipColumn)

        var select = ["Z_PK", "ZCKIDENTIFIER", "ZNAME"]
        select.append(hasGroups ? "COALESCE(ZISGROUP, 0)" : "0")
        // SQLite's COALESCE needs at least two arguments, so a store with only one parent column
        // selects it bare -- `COALESCE(ZPARENTLIST)` fails to prepare.
        switch parentColumns.count {
        case 0: select.append("NULL")
        case 1: select.append(parentColumns[0])
        default: select.append("COALESCE(\(parentColumns.joined(separator: ", ")))")
        }
        select.append(hasMemberships ? membershipColumn : "NULL")

        var listIDByPK: [Int64: String] = [:]
        var groupPKs: [(pk: Int64, id: String, name: String)] = []
        var parentPKByListID: [String: Int64] = [:]
        var membershipBlobs: [(listID: String, data: Data)] = []

        let listsRead = db.each(
            "SELECT \(select.joined(separator: ", ")) FROM ZREMCDBASELIST "
                + "WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0 AND ZCKIDENTIFIER IS NOT NULL"
        ) { row in
            guard let rawID = row.string(1) else { return }
            let id = rawID.uppercased()
            let pk = row.int(0)
            listIDByPK[pk] = id
            if row.int(3) == 1 {
                groupPKs.append((pk, id, row.string(2) ?? ""))
            } else {
                if !row.isNull(4) { parentPKByListID[id] = row.int(4) }
                if let blob = row.data(5), !blob.isEmpty { membershipBlobs.append((id, blob)) }
            }
        }
        guard listsRead else { return .failure(.unreadable("lists query failed: \(db.lastError)")) }

        var groupsByPK: [Int64: RemindersSnapshot.Group] = [:]
        for group in groupPKs {
            groupsByPK[group.pk] = RemindersSnapshot.Group(id: group.id, name: group.name, listIDs: [])
        }
        for (listID, parentPK) in parentPKByListID.sorted(by: { $0.key < $1.key }) {
            guard var group = groupsByPK[parentPK] else { continue }
            group.listIDs.append(listID)
            groupsByPK[parentPK] = group
            result.groupByList[listID] = group.id
        }
        result.groups = groupsByPK.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        // Sections. Z_PK order is creation order, which is what RemCTL treats as display order too.
        if db.tableExists("ZREMCDBASESECTION") {
            let sectionsRead = db.each(
                "SELECT ZCKIDENTIFIER, ZDISPLAYNAME, ZLIST FROM ZREMCDBASESECTION "
                    + "WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0 AND ZLIST IS NOT NULL "
                    + "AND ZCKIDENTIFIER IS NOT NULL ORDER BY Z_PK"
            ) { row in
                guard let id = row.string(0)?.uppercased(),
                      let listID = listIDByPK[row.int(2)] else { return }
                let order = result.sectionsByList[listID]?.count ?? 0
                result.sectionsByList[listID, default: []].append(
                    RemindersSnapshot.Section(id: id, listID: listID, name: row.string(1) ?? "", order: order)
                )
            }
            guard sectionsRead else { return .failure(.unreadable("sections query failed: \(db.lastError)")) }
        }

        for (listID, blob) in membershipBlobs {
            let live = Set((result.sectionsByList[listID] ?? []).map(\.id))
            for (member, section) in currentMemberships(in: blob) where live.contains(section) {
                result.sectionByReminder[member] = section
            }
        }

        // Tags. ZREMCDOBJECT rows with a hashtag label are the per-reminder tag assignments. Only
        // tags some reminder still carries are listed: Reminders keeps a label row after its last
        // use is removed, and showing those would list tags Reminders.app itself no longer shows.
        let objectColumns = db.columns(of: "ZREMCDOBJECT")
        if db.tableExists("ZREMCDHASHTAGLABEL"),
           objectColumns.contains("ZHASHTAGLABEL"), objectColumns.contains("ZREMINDER3") {
            var names = Set<String>()
            let tagsRead = db.each(
                "SELECT r.ZCKIDENTIFIER, h.ZNAME FROM ZREMCDOBJECT o "
                    + "JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL = h.Z_PK "
                    + "JOIN ZREMCDREMINDER r ON o.ZREMINDER3 = r.Z_PK "
                    + "WHERE COALESCE(o.ZMARKEDFORDELETION, 0) = 0 "
                    + "AND COALESCE(r.ZMARKEDFORDELETION, 0) = 0 "
                    + "AND h.ZNAME IS NOT NULL AND h.ZNAME != '' "
                    + "ORDER BY o.Z_PK"
            ) { row in
                guard let id = row.string(0)?.uppercased(), let name = row.string(1) else { return }
                names.insert(name)
                if !(result.tagsByReminder[id]?.contains(name) ?? false) {
                    result.tagsByReminder[id, default: []].append(name)
                }
            }
            guard tagsRead else { return .failure(.unreadable("tags query failed: \(db.lastError)")) }
            result.tagNames = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        return .success(result)
    }

    /// Decodes a list's section-membership record: `{"memberships": [{memberID, groupID,
    /// isObsolete, modifiedOn}]}`. It is a merge log rather than a table -- a reminder can appear
    /// more than once as it moves between sections -- so the newest entry per reminder wins, and a
    /// newest entry marked obsolete means the reminder is no longer in any section.
    static func currentMemberships(in blob: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let entries = root["memberships"] as? [[String: Any]] else { return [:] }

        var newest: [String: (stamp: Double, index: Int, group: String?, obsolete: Bool)] = [:]
        for (index, entry) in entries.enumerated() {
            guard let member = (entry["memberID"] as? String)?.uppercased() else { continue }
            let stamp = timestamp(entry["modifiedOn"]) ?? -.infinity
            let candidate = (
                stamp: stamp,
                index: index,
                group: (entry["groupID"] as? String)?.uppercased(),
                obsolete: (entry["isObsolete"] as? Bool) ?? false
            )
            if let existing = newest[member],
               (existing.stamp, existing.index) > (candidate.stamp, candidate.index) {
                continue
            }
            newest[member] = candidate
        }

        var result: [String: String] = [:]
        for (member, entry) in newest where !entry.obsolete {
            if let group = entry.group { result[member] = group }
        }
        return result
    }

    private static func timestamp(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String:
            if let number = Double(string) { return number }
            return ISO8601DateFormatter().date(from: string)?.timeIntervalSinceReferenceDate
        default: return nil
        }
    }
}

// MARK: - SQLite

/// A read-only connection. `mode=ro` plus SQLITE_OPEN_READONLY, so a bug here can never write to
/// the user's Reminders store.
final class SQLiteReader {
    private var handle: OpaquePointer?

    init?(url: URL) {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
        handle = db
    }

    deinit { sqlite3_close(handle) }

    var lastError: String {
        guard let handle else { return "no connection" }
        return String(cString: sqlite3_errmsg(handle))
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

        func string(_ column: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: text)
        }

        func data(_ column: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    @discardableResult
    func each(_ sql: String, _ body: (Row) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            body(Row(statement: statement))
        }
        return true
    }

    func scalar(_ sql: String) -> Int64? {
        var value: Int64?
        each(sql) { value = $0.int(0) }
        return value
    }

    func tableExists(_ name: String) -> Bool {
        var found = false
        each("SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(name)'") { _ in found = true }
        return found
    }

    func columns(of table: String) -> Set<String> {
        var names = Set<String>()
        each("PRAGMA table_info(\(table))") { row in
            if let name = row.string(1) { names.insert(name) }
        }
        return names
    }
}
