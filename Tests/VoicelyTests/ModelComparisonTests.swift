import AVFoundation
import XCTest
@testable import Voicely
@testable import VoicelyCore

@MainActor
final class ModelComparisonTests: XCTestCase {

    /// Answers with the model's name and records the language it was asked for.
    private final class NamedEngine: TranscriberEngine, @unchecked Sendable {
        let name: String
        private let lock = NSLock()
        private var _languages: [String?] = []
        var languages: [String?] {
            lock.lock()
            defer { lock.unlock() }
            return _languages
        }

        init(name: String) {
            self.name = name
        }

        func transcribe(audio: AVAudioPCMBuffer, translate: Bool, language: String?) async throws -> String {
            lock.withLock { _languages.append(language) }
            return "text from \(name)"
        }
    }

    private final class EngineShelf: @unchecked Sendable {
        private let lock = NSLock()
        private var engines: [String: NamedEngine] = [:]
        private(set) var builds: [String] = []

        func engine(for model: WhisperModel) -> NamedEngine {
            lock.lock()
            defer { lock.unlock() }
            builds.append(model.variant)
            if let engine = engines[model.variant] { return engine }
            let engine = NamedEngine(name: model.displayName)
            engines[model.variant] = engine
            return engine
        }

        func existing(_ variant: String) -> NamedEngine? {
            lock.lock()
            defer { lock.unlock() }
            return engines[variant]
        }
    }

    private func model(_ variant: String) throws -> WhisperModel {
        try XCTUnwrap(WhisperModel.all.first { $0.variant == variant })
    }

    private func speech(seconds: Double, rate: Double = 16_000) -> DictationAudioSnapshot {
        let count = Int(seconds * rate)
        let samples = (0..<count).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
        return DictationAudioSnapshot(samples: samples, sampleRate: rate)
    }

    // MARK: - Capture

    func testCaptureKeepsChunksAndTailInOrder() throws {
        var capture = DictationAudioCapture()
        capture.append([1, 2, 3], sampleRate: 48_000)
        capture.append([4, 5], sampleRate: 48_000)
        let tail = try XCTUnwrap(DictationAudioSnapshot(samples: [6, 7], sampleRate: 48_000).makeBuffer())
        capture.append(tail)

        XCTAssertEqual(capture.snapshot, DictationAudioSnapshot(samples: [1, 2, 3, 4, 5, 6, 7], sampleRate: 48_000))
    }

    func testCaptureDropsARecordingWhoseRateChanged() {
        var capture = DictationAudioCapture()
        capture.append([1, 2, 3], sampleRate: 48_000)
        capture.append([4, 5], sampleRate: 44_100)
        capture.append([6], sampleRate: 48_000)

        XCTAssertNil(capture.snapshot)
    }

    func testEmptyCaptureHasNothingToCompare() {
        XCTAssertNil(DictationAudioCapture().snapshot)
    }

    // MARK: - Report

    func testReportTableShowsLoadSpeedAndFailures() throws {
        let parakeet = try model("parakeet-tdt-0.6b-v3")
        let giga = try model("gigaam-v3-e2e-rnnt")
        let medium = try model("medium")
        let turbo = try model("large-v3-v20240930_turbo_632MB")
        let results = [
            ModelComparisonResult(
                model: parakeet, isCurrent: true, language: "en", languageFellBack: false,
                loadSeconds: nil, transcribeSeconds: 0.5,
                outcome: .transcribed(text: "hello world", incomplete: false)
            ),
            ModelComparisonResult(
                model: giga, isCurrent: false, language: nil, languageFellBack: true,
                loadSeconds: 3.24, transcribeSeconds: 2,
                outcome: .transcribed(text: "", incomplete: false)
            ),
            ModelComparisonResult(
                model: medium, isCurrent: false, language: "en", languageFellBack: false,
                loadSeconds: nil, transcribeSeconds: nil,
                outcome: .failed("Out of memory")
            ),
        ]

        let report = ModelComparisonReport.markdown(
            date: Date(timeIntervalSince1970: 0),
            audioSeconds: 10,
            requestedLanguage: "en",
            results: results,
            waiting: [turbo]
        )

        XCTAssertTrue(report.contains("| Parakeet V3 (current) | already loaded | 0.5 s | 20× |"), report)
        XCTAssertTrue(report.contains("| GigaAM V3 RU | 3.2 s | 2.0 s | 5.0× |"), report)
        XCTAssertTrue(report.contains("| Medium | — | — | failed |"), report)
        XCTAssertTrue(report.contains("| Large V3 Turbo Q | waiting | | |"), report)
        XCTAssertTrue(report.contains("## Parakeet V3 (current)\n\nhello world"), report)
        XCTAssertTrue(report.contains("_Auto-detected: the model has no en._"), report)
        XCTAssertTrue(report.contains("_No speech recognized._"), report)
        XCTAssertTrue(report.contains("_Failed: Out of memory_"), report)
    }

    // MARK: - Runner

    func testRunnerComparesEveryModelOnTheSameAudio() async throws {
        let parakeet = try model("parakeet-tdt-0.6b-v3")
        let giga = try model("gigaam-v3-e2e-rnnt")
        let shelf = EngineShelf()
        let transcriber = Transcriber(
            coordinator: TranscriptionCoordinator(),
            selectedModel: parakeet,
            engineFactory: { model, _ in shelf.engine(for: model) }
        )
        var progress: [String?] = []

        let results = await ModelComparisonRunner.run(
            audio: speech(seconds: 1),
            models: [parakeet, giga],
            transcriber: transcriber,
            language: "en"
        ) { running, _ in
            progress.append(running?.variant)
        }

        XCTAssertEqual(progress, ["parakeet-tdt-0.6b-v3", "gigaam-v3-e2e-rnnt", nil])
        XCTAssertEqual(results.map(\.model), [parakeet, giga])

        XCTAssertTrue(results[0].isCurrent)
        XCTAssertNil(results[0].loadSeconds, "the selected model was already loaded")
        XCTAssertEqual(results[0].language, "en")
        XCTAssertFalse(results[0].languageFellBack)
        XCTAssertEqual(results[0].outcome, .transcribed(text: "text from Parakeet V3", incomplete: false))

        XCTAssertFalse(results[1].isCurrent)
        XCTAssertNotNil(results[1].loadSeconds)
        XCTAssertNil(results[1].language, "GigaAM V3 RU has no English")
        XCTAssertTrue(results[1].languageFellBack)
        XCTAssertEqual(results[1].outcome, .transcribed(text: "text from GigaAM V3 RU", incomplete: false))

        XCTAssertEqual(shelf.existing("parakeet-tdt-0.6b-v3")?.languages, ["en"])
        XCTAssertEqual(shelf.existing("gigaam-v3-e2e-rnnt")?.languages, [nil])
    }

    func testRunnerReusesTheSelectedEngine() async throws {
        let parakeet = try model("parakeet-tdt-0.6b-v3")
        let giga = try model("gigaam-v3-e2e-rnnt")
        let shelf = EngineShelf()
        let transcriber = Transcriber(
            coordinator: TranscriptionCoordinator(),
            selectedModel: parakeet,
            engineFactory: { model, _ in shelf.engine(for: model) }
        )
        _ = try await transcriber.transcribe(audio: speech(seconds: 1).makeBuffer())

        _ = await ModelComparisonRunner.run(
            audio: speech(seconds: 1),
            models: [parakeet, giga],
            transcriber: transcriber,
            language: nil
        ) { _, _ in }

        XCTAssertEqual(shelf.builds, ["parakeet-tdt-0.6b-v3", "gigaam-v3-e2e-rnnt"])
    }

    func testCancelledComparisonRunsNothing() async throws {
        let parakeet = try model("parakeet-tdt-0.6b-v3")
        let shelf = EngineShelf()
        let transcriber = Transcriber(
            coordinator: TranscriptionCoordinator(),
            selectedModel: parakeet,
            engineFactory: { model, _ in shelf.engine(for: model) }
        )
        let audio = speech(seconds: 1)

        let task = Task { @MainActor in
            await ModelComparisonRunner.run(
                audio: audio,
                models: [parakeet],
                transcriber: transcriber,
                language: nil
            ) { _, _ in }
        }
        task.cancel()
        let results = await task.value

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(shelf.builds.isEmpty, "no engine is built for a cancelled comparison")
    }

    // MARK: - Differences

    private func spans(_ texts: [String]) -> [[String]] {
        zip(texts, ModelComparisonDiff.differingSpans(in: texts)).map { text, ranges in
            ranges.map { String(text[$0]) }
        }
    }

    /// The first real comparison: only the brand name came out differently.
    func testDiffFindsTheOneWordTheModelsDisagreeOn() {
        let giga = "Смотри, можно ли из этого видео достать всю полезную информацию и могу ли я на практике "
            + "применить это у себя на своем ноутбуке в данном случае на макбуке и на своем ноутбуке."
        let parakeet = "Смотри, можно ли из этого видео достать всю полезную информацию, и могу ли я на практике "
            + "применить это у себя на своем ноутбуке? В данном случае на MacBookie и на своем ноутбуке"

        XCTAssertEqual(spans([giga, parakeet]), [["макбуке"], ["MacBookie"]])
    }

    func testDiffIgnoresCasePunctuationAndYo() {
        XCTAssertEqual(spans(["Ещё раз, Привет!", "еще раз привет"]), [[], []])
    }

    func testDiffMergesNeighbouringWordsIntoOneSpan() {
        XCTAssertEqual(
            spans(["я открыл ноутбук вчера", "я закрыл свой ноутбук вчера"]),
            [["открыл"], ["закрыл свой"]]
        )
    }

    /// A word one model got differently is marked in every text, so each
    /// text shows where the models disagree.
    func testDiffMarksAWordThatDiffersFromAnyOtherModel() {
        XCTAssertEqual(
            spans(["one two three", "one two three", "one too three"]),
            [["two"], ["two"], ["too"]]
        )
    }

    func testDisplayReportHighlightsTheDifferingWords() throws {
        let parakeet = try model("parakeet-tdt-0.6b-v3")
        let giga = try model("gigaam-v3-e2e-rnnt")
        let results = [
            ModelComparisonResult(
                model: parakeet, isCurrent: true, language: nil, languageFellBack: false,
                loadSeconds: nil, transcribeSeconds: 1,
                outcome: .transcribed(text: "на MacBookie и ноутбуке", incomplete: false)
            ),
            ModelComparisonResult(
                model: giga, isCurrent: false, language: nil, languageFellBack: false,
                loadSeconds: 1, transcribeSeconds: 1,
                outcome: .transcribed(text: "на макбуке и ноутбуке", incomplete: false)
            ),
        ]

        let display = ModelComparisonReport.render(
            date: Date(timeIntervalSince1970: 0),
            audioSeconds: 10,
            requestedLanguage: nil,
            results: results,
            style: .display
        )
        let text = display.text as NSString
        XCTAssertEqual(display.highlights.map { text.substring(with: $0) }, ["MacBookie", "макбуке"])
        XCTAssertTrue(display.text.contains("Highlighted words differ between models."), display.text)
        XCTAssertFalse(display.text.contains("**"), display.text)

        let markdown = ModelComparisonReport.markdown(
            date: Date(timeIntervalSince1970: 0),
            audioSeconds: 10,
            requestedLanguage: nil,
            results: results
        )
        XCTAssertTrue(markdown.contains("на **MacBookie** и ноутбуке"), markdown)
        XCTAssertTrue(markdown.contains("на **макбуке** и ноутбуке"), markdown)
        XCTAssertTrue(markdown.contains("Words in **bold** differ between models."), markdown)
    }

    func testReportSaysWhenEveryModelHeardTheSameWords() throws {
        let results = try ["parakeet-tdt-0.6b-v3", "gigaam-v3-e2e-rnnt"].map { variant in
            ModelComparisonResult(
                model: try model(variant), isCurrent: false, language: nil, languageFellBack: false,
                loadSeconds: 1, transcribeSeconds: 1,
                outcome: .transcribed(text: variant == "gigaam-v3-e2e-rnnt" ? "Привет, мир." : "привет мир", incomplete: false)
            )
        }

        let display = ModelComparisonReport.render(
            date: Date(timeIntervalSince1970: 0),
            audioSeconds: 10,
            requestedLanguage: nil,
            results: results,
            style: .display
        )
        XCTAssertTrue(display.highlights.isEmpty)
        XCTAssertTrue(display.text.contains("All models recognized the same words"), display.text)
    }
}
