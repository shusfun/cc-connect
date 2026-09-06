// FILE: TurnFileChangeSummaryParserTests.swift
// Purpose: Verifies file-change parsing deduplicates repeated file entries and exposes stable dedupe keys.
// Layer: Unit Test
// Exports: TurnFileChangeSummaryParserTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class TurnFileChangeSummaryParserTests: XCTestCase {
    func testTotalsPatternsCompileAndAcceptUnicodeSigns() throws {
        let totals = try XCTUnwrap(TurnMessageRegexCache.inlineTotals)
        let trailing = try XCTUnwrap(TurnMessageRegexCache.trailingInlineTotals)
        let editing = try XCTUnwrap(TurnMessageRegexCache.inlineEditingRow)
        for plus in ["+", "＋"] {
            for minus in ["-", "−", "–", "—", "﹣", "－"] {
                let source = "Edited Sources/App.swift \(plus)3 \(minus)2"
                let range = NSRange(source.startIndex..., in: source)
                for regex in [totals, trailing, editing] {
                    XCTAssertNotNil(regex.firstMatch(in: source, range: range), source)
                }
                let summary = try XCTUnwrap(TurnFileChangeSummaryParser.parse(from: source))
                XCTAssertEqual(summary.entries.first?.path, "Sources/App.swift")
                XCTAssertEqual(summary.entries.first?.additions, 3)
                XCTAssertEqual(summary.entries.first?.deletions, 2)
            }
        }
    }

    func testParseConsolidatesRepeatedEntriesForSamePath() {
        let source = """
        Edited orchestrator-config-v1.example.json +2 -0
        Edited orchestrator-config-v1.example.json +2 -0
        """

        let summary = TurnFileChangeSummaryParser.parse(from: source)

        XCTAssertEqual(summary?.entries.count, 1)
        XCTAssertEqual(summary?.entries.first?.path, "orchestrator-config-v1.example.json")
        XCTAssertEqual(summary?.entries.first?.additions, 4)
        XCTAssertEqual(summary?.entries.first?.deletions, 0)
    }

    func testDedupeKeyIgnoresStatusOnlyDifferences() {
        let streaming = """
        Status: inProgress

        Path: Sources/App.swift
        Kind: update
        Totals: +2 -1
        """

        let completed = """
        Status: completed

        Path: Sources/App.swift
        Kind: update
        Totals: +2 -1
        """

        XCTAssertEqual(
            TurnFileChangeSummaryParser.dedupeKey(from: streaming),
            TurnFileChangeSummaryParser.dedupeKey(from: completed)
        )
    }
}
