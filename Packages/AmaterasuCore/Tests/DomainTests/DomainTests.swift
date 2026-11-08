import Foundation
import XCTest
@testable import Domain

final class MusicalKeyTests: XCTestCase {
    func testRejectsNumbersOutsideTheWheel() {
        XCTAssertNil(MusicalKey(number: 0, isMinor: true))
        XCTAssertNil(MusicalKey(number: 13, isMinor: false))
        XCTAssertNotNil(MusicalKey(number: 12, isMinor: false))
    }

    func testSeratoKeyValueCoversAll24Keys() {
        let camelot = (0...23).compactMap { MusicalKey(seratoKeyValue: $0)?.camelot }
        XCTAssertEqual(camelot, (1...12).map { "\($0)A" } + (1...12).map { "\($0)B" })
        XCTAssertNil(MusicalKey(seratoKeyValue: -1))
        XCTAssertNil(MusicalKey(seratoKeyValue: 24))
    }

    func testTraditionalNamesMatchTheCamelotTable() {
        XCTAssertEqual(MusicalKey(number: 1, isMinor: true)?.traditional, "Abm")
        XCTAssertEqual(MusicalKey(number: 8, isMinor: true)?.traditional, "Am")
        XCTAssertEqual(MusicalKey(number: 8, isMinor: false)?.traditional, "C")
        XCTAssertEqual(MusicalKey(number: 11, isMinor: true)?.traditional, "F#m")
        XCTAssertEqual(MusicalKey(number: 12, isMinor: true)?.traditional, "Dbm")
        XCTAssertEqual(MusicalKey(number: 12, isMinor: false)?.traditional, "E")
    }

    func testOpenKeyIsShiftedBySeven() {
        XCTAssertEqual(MusicalKey(number: 8, isMinor: false)?.openKey, "1d")
        XCTAssertEqual(MusicalKey(number: 8, isMinor: true)?.openKey, "1m")
        XCTAssertEqual(MusicalKey(number: 1, isMinor: true)?.openKey, "6m")
        XCTAssertEqual(MusicalKey(number: 7, isMinor: false)?.openKey, "12d")
    }
}

final class DeckRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func deck(_ id: Int, loaded: TimeInterval, started: TimeInterval? = nil, title: String = "T") -> DeckState {
        DeckState(
            id: id,
            title: title,
            hasStartedPlaying: started != nil,
            loadedAt: t0.addingTimeInterval(loaded),
            playStartedAt: started.map { t0.addingTimeInterval($0) }
        )
    }

    func testMostRecentlyStartedDeckIsMain() {
        let decks = [deck(1, loaded: 0, started: 10), deck(2, loaded: 20, started: 30), deck(3, loaded: 40)]
        XCTAssertEqual(MainDeck.select(from: decks), 2)
    }

    func testManualChoiceWinsOnlyWhileThatDeckIsLoaded() {
        let decks = [deck(1, loaded: 0, started: 10), deck(2, loaded: 20, started: 30)]
        XCTAssertEqual(MainDeck.select(from: decks, manual: 1), 1)
        XCTAssertEqual(MainDeck.select(from: decks, manual: 4), 2)
    }

    func testWithoutPlaybackTheMostRecentlyLoadedDeckIsMain() {
        XCTAssertEqual(MainDeck.select(from: [deck(1, loaded: 0), deck(2, loaded: 5)]), 2)
        XCTAssertNil(MainDeck.select(from: []))
    }

    func testTiesGoToTheLowerDeck() {
        XCTAssertEqual(MainDeck.select(from: [deck(2, loaded: 0, started: 5), deck(1, loaded: 0, started: 5)]), 1)
    }

    func testStartingPlaybackIsNotATrackChange() {
        let before = [deck(1, loaded: 0)]
        let after = [deck(1, loaded: 0, started: 3)]
        XCTAssertEqual(TrackChanges.changedDecks(from: before, to: after), [])
    }

    func testNewDecksAndNewTracksAreChanges() {
        let before = [deck(1, loaded: 0, title: "A")]
        let after = [deck(1, loaded: 0, title: "B"), deck(2, loaded: 1)]
        XCTAssertEqual(TrackChanges.changedDecks(from: before, to: after), [1, 2])
        XCTAssertEqual(TrackChanges.changedDecks(from: after, to: [deck(2, loaded: 1)]), [], "an ejected deck is not a change")
    }
}
