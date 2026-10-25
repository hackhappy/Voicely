import XCTest
@testable import VoicelyCore
import FluidAudio

final class ParakeetSegmentingTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double) -> WordTiming {
        WordTiming(word: text, startTime: start, endTime: end)
    }

    func testSentenceTerminatorClosesSegment() {
        let words = [
            word("Привет,", 0.0, 0.4),
            word("мир.", 0.5, 0.9),
            word("Как", 1.0, 1.2),
            word("дела?", 1.3, 1.7),
        ]
        let segments = ParakeetEngine.makeSegments(words: words, fallbackText: "", duration: 2.0)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Привет, мир.")
        XCTAssertEqual(segments[0].start, 0.0)
        XCTAssertEqual(segments[0].end, 0.9)
        XCTAssertEqual(segments[1].text, "Как дела?")
        XCTAssertEqual(segments[1].start, 1.0)
        XCTAssertEqual(segments[1].end, 1.7)
    }

    func testLongPauseClosesSegmentMidSentence() {
        let words = [
            word("раз", 0.0, 0.3),
            word("два", 0.4, 0.7),
            // 1.5s of silence — longer than the 1.0s segment gap
            word("три", 2.2, 2.5),
        ]
        let segments = ParakeetEngine.makeSegments(words: words, fallbackText: "", duration: 3.0)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "раз два")
        XCTAssertEqual(segments[1].text, "три")
        XCTAssertEqual(segments[1].start, 2.2)
    }

    func testNoTimingsFallsBackToOneFullSpanSegment() {
        let segments = ParakeetEngine.makeSegments(words: [], fallbackText: "весь текст", duration: 12.5)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 12.5)
        XCTAssertEqual(segments[0].text, "весь текст")
    }

    func testEmptyEverythingYieldsNoSegments() {
        XCTAssertTrue(ParakeetEngine.makeSegments(words: [], fallbackText: "", duration: 5).isEmpty)
    }
}

final class ParakeetVocabularyTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double) -> WordTiming {
        WordTiming(word: text, startTime: start, endTime: end)
    }

    /// Replacements land in the word timings the segments are built from,
    /// in order, keeping the original's trailing punctuation.
    func testReplacementsLandInWordTimingsInOrder() {
        let words = [
            word("база", 0.0, 0.3), word("рак,", 0.4, 0.7), word("и", 0.8, 0.9),
            word("ещё", 1.0, 1.2), word("рак.", 1.3, 1.6),
        ]
        let out = ParakeetEngine.applying(
            [(original: "рак", replacement: "RAG"), (original: "рак", replacement: "RAG")], to: words)
        XCTAssertEqual(out.map(\.word), ["база", "RAG,", "и", "ещё", "RAG."])
        XCTAssertEqual(out[1].startTime, 0.4)
        XCTAssertEqual(out[4].endTime, 1.6)
    }

    /// A multi-word mishearing collapses into one term spanning its timings.
    func testMultiWordOriginalCollapsesIntoOneWord() {
        let words = [word("в", 0.0, 0.1), word("кубер", 0.2, 0.5), word("нетис", 0.5, 0.9), word("деплоим", 1.0, 1.5)]
        let out = ParakeetEngine.applying([(original: "кубер нетис", replacement: "Kubernetes")], to: words)
        XCTAssertEqual(out.map(\.word), ["в", "Kubernetes", "деплоим"])
        XCTAssertEqual(out[1].startTime, 0.2)
        XCTAssertEqual(out[1].endTime, 0.9)
    }

    /// A replacement whose original is not among the words changes nothing.
    func testUnmatchedReplacementIsIgnored() {
        let words = [word("всё", 0.0, 0.3), word("ок", 0.4, 0.6)]
        let out = ParakeetEngine.applying([(original: "рак", replacement: "RAG")], to: words)
        XCTAssertEqual(out.map(\.word), ["всё", "ок"])
    }

    func testNoVocabularyWithoutEnvironmentVariable() async throws {
        let session = try await ParakeetEngine.loadVocabularyBoosting(environment: [:])
        XCTAssertNil(session)
    }
}
