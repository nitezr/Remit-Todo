import XCTest
@testable import Remit

/// Real Reminders lists and tags carry leading emoji -- "🤝 Acme", "🔁Monthly", "⏳waiting".
/// Matching them by raw prefix silently failed: `#acme` offered nothing, and picking a suggestion
/// wrote a token the parser could not resolve, so the task landed in the default list instead of
/// the one that was named.
final class QuickAddMatchingTests: XCTestCase {

    private func project(_ title: String) -> RemitProject {
        RemitProject(id: title, title: title, colorHex: "#888888",
                     emoji: nil, isFavorite: false, sortOrder: 0, groupID: nil)
    }

    // MARK: - Normalisation

    func testNormalisationReducesEmojiAndSpacingToTheSameKey() {
        let expected = "acme"
        XCTAssertEqual(QuickAddParser.normalizeName("🤝 Acme"), expected)
        XCTAssertEqual(QuickAddParser.normalizeName("#🤝Acme"), expected)
        XCTAssertEqual(QuickAddParser.normalizeName("acme"), expected)
        XCTAssertEqual(QuickAddParser.normalizeName("  ACME  "), expected)
    }

    func testNormalisationKeepsInternalPunctuation() {
        // Only *leading* decoration is dropped; "Acme <> Orbit" must stay distinguishable.
        XCTAssertEqual(QuickAddParser.normalizeName("🔄 Acme <> Orbit"), "acme<>orbit")
    }

    // MARK: - Parsing

    func testTypingAPlainNameResolvesAnEmojiPrefixedProject() {
        let projects = [project("🤝 Acme"), project("🎬 Movies")]

        let result = QuickAddParser.parse("Call Priya #acme", projects: projects, labels: [])

        XCTAssertEqual(result.projectID, "🤝 Acme")
        XCTAssertEqual(result.title, "Call Priya")
    }

    /// What the suggestion list actually inserts: the name with spaces stripped, emoji included.
    func testAcceptingASuggestionResolves() {
        let projects = [project("🤝 Acme"), project("🎬 Movies")]

        let result = QuickAddParser.parse("Call Priya #🤝Acme", projects: projects, labels: [])

        XCTAssertEqual(result.projectID, "🤝 Acme")
    }

    func testExactMatchWinsOverAPrefixMatch() {
        let projects = [project("Homework"), project("Home")]

        let result = QuickAddParser.parse("Buy milk #Home", projects: projects, labels: [])

        XCTAssertEqual(result.projectID, "Home", "#Home must not silently pick Homework")
    }

    func testAnUnknownProjectLeavesTheTaskUnassigned() {
        let projects = [project("🤝 Acme")]

        let result = QuickAddParser.parse("Something #nope", projects: projects, labels: [])

        XCTAssertNil(result.projectID)
    }

    func testEmojiPrefixedLabelsResolveFromPlainText() {
        let labels = ["⏳waiting", "🔁Monthly"]

        let result = QuickAddParser.parse("Chase invoice @waiting", projects: [], labels: labels)

        XCTAssertEqual(result.labelNames, ["⏳waiting"])
        XCTAssertEqual(result.title, "Chase invoice")
    }

    // MARK: - Suggestion ranking

    func testSuggestionRankingFindsEmojiPrefixedNames() {
        XCTAssertNotNil(QuickAddView.rank("🤝 Acme", query: "acme"))
        XCTAssertNotNil(QuickAddView.rank("🔁Monthly", query: "month"))
        XCTAssertNil(QuickAddView.rank("🎬 Movies", query: "zzz"))
    }

    func testSuggestionRankingPrefersAPrefixMatch() throws {
        let prefix = try XCTUnwrap(QuickAddView.rank("🤝 Acme", query: "ac"))
        let substring = try XCTUnwrap(QuickAddView.rank("🔄 Acme <> Orbit", query: "orbit"))

        XCTAssertLessThan(prefix, substring, "a name starting with the query should sort first")
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertNotNil(QuickAddView.rank("🎬 Movies", query: ""))
    }
}
