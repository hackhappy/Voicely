import AppKit
import AVFoundation
import VoicelyCore

// MARK: - Last dictation audio

/// The audio of the last finished dictation, kept in memory only so the
/// installed models can be compared on it. The next dictation replaces it;
/// it is never written to disk.
struct DictationAudioSnapshot: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    func makeBuffer() -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.initialize(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

/// Collects one dictation's audio in the order the chunk loop and the stop
/// hand it over. A sample-rate change mid-dictation (device switch) leaves
/// nothing to compare rather than a recording played at the wrong speed.
struct DictationAudioCapture {
    private var samples: [Float] = []
    private var sampleRate: Double?
    private var rateChanged = false

    mutating func append(_ newSamples: [Float], sampleRate rate: Double) {
        guard !rateChanged, !newSamples.isEmpty else { return }
        if let sampleRate, abs(sampleRate - rate) >= 1 {
            rateChanged = true
            samples = []
            return
        }
        sampleRate = rate
        samples.append(contentsOf: newSamples)
    }

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        append(
            Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
            sampleRate: buffer.format.sampleRate
        )
    }

    var snapshot: DictationAudioSnapshot? {
        guard !rateChanged, let sampleRate, sampleRate > 0, !samples.isEmpty else { return nil }
        return DictationAudioSnapshot(samples: samples, sampleRate: sampleRate)
    }
}

// MARK: - Results

/// One model's pass over the comparison recording.
struct ModelComparisonResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        /// `incomplete`: a window failed and left a gap marker in `text`.
        case transcribed(text: String, incomplete: Bool)
        case failed(String)
    }

    let model: WhisperModel
    let isCurrent: Bool
    /// The language the run asked for; nil is auto-detection.
    let language: String?
    /// The requested language is one the model does not have, so the run
    /// used auto-detection instead.
    let languageFellBack: Bool
    /// Nil when the model was already loaded before the comparison.
    let loadSeconds: Double?
    let transcribeSeconds: Double?
    let outcome: Outcome

    /// How many times faster than real time the model transcribed.
    func speed(audioSeconds: Double) -> Double? {
        guard let transcribeSeconds, transcribeSeconds > 0, case .transcribed = outcome else {
            return nil
        }
        return audioSeconds / transcribeSeconds
    }
}

// MARK: - Differences

/// Which words of each transcript differ from at least one other transcript.
///
/// Words are compared by their letters and digits, ignoring case, punctuation
/// and ё/е: a moved comma or a capital letter is not a difference, another
/// word is. Each pair of texts is aligned on its longest common word
/// sequence; a word left outside that sequence for any other text differs.
enum ModelComparisonDiff {
    /// For each text, its differing words as ranges into that text. Words
    /// separated only by whitespace merge into one span ("на MacBookie").
    static func differingSpans(in texts: [String]) -> [[Range<String.Index>]] {
        let words = texts.map(Self.words)
        let keys = words.map { $0.map(\.key) }
        return texts.indices.map { i in
            var differing = Set<Int>()
            for j in texts.indices where j != i {
                let common = commonIndices(keys[i], keys[j])
                for k in keys[i].indices where !common.contains(k) {
                    differing.insert(k)
                }
            }
            return merged(differing.sorted().map { words[i][$0].range }, in: texts[i])
        }
    }

    private struct Word {
        let key: String
        let range: Range<String.Index>
    }

    private static func words(_ text: String) -> [Word] {
        var words: [Word] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            words.append(Word(
                key: word.lowercased().replacingOccurrences(of: "ё", with: "е"),
                range: range
            ))
        }
        return words
    }

    /// Indices of `a` on one longest common subsequence with `b`.
    private static func commonIndices(_ a: [String], _ b: [String]) -> Set<Int> {
        let n = a.count
        let m = b.count
        guard n > 0, m > 0 else { return [] }
        // suffix[i * (m + 1) + j]: LCS length of a[i...] and b[j...].
        var suffix = [Int](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                suffix[i * (m + 1) + j] = a[i] == b[j]
                    ? suffix[(i + 1) * (m + 1) + j + 1] + 1
                    : max(suffix[(i + 1) * (m + 1) + j], suffix[i * (m + 1) + j + 1])
            }
        }
        var common = Set<Int>()
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                common.insert(i)
                i += 1
                j += 1
            } else if suffix[(i + 1) * (m + 1) + j] >= suffix[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return common
    }

    private static func merged(
        _ ranges: [Range<String.Index>],
        in text: String
    ) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        for range in ranges {
            if let last = spans.last,
               text[last.upperBound..<range.lowerBound].allSatisfy(\.isWhitespace) {
                spans[spans.count - 1] = last.lowerBound..<range.upperBound
            } else {
                spans.append(range)
            }
        }
        return spans
    }
}

// MARK: - Report

enum ModelComparisonReport {
    enum Style {
        /// Plain text for the window; differing words come back as `highlights`.
        case display
        /// Markdown for the saved file; differing words in **bold**.
        case markdown
    }

    struct Rendered: Equatable {
        let text: String
        /// Differing words in `text` (UTF-16 ranges, for AppKit). Empty for `.markdown`.
        let highlights: [NSRange]
    }

    /// The saved file's Markdown.
    static func markdown(
        date: Date,
        audioSeconds: Double,
        requestedLanguage: String?,
        results: [ModelComparisonResult],
        running: WhisperModel? = nil,
        waiting: [WhisperModel] = []
    ) -> String {
        render(
            date: date,
            audioSeconds: audioSeconds,
            requestedLanguage: requestedLanguage,
            results: results,
            running: running,
            waiting: waiting,
            style: .markdown
        ).text
    }

    /// The report for the window or the saved file. `running` and `waiting`
    /// keep the table complete while the comparison is still in progress.
    static func render(
        date: Date,
        audioSeconds: Double,
        requestedLanguage: String?,
        results: [ModelComparisonResult],
        running: WhisperModel? = nil,
        waiting: [WhisperModel] = [],
        style: Style
    ) -> Rendered {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = [
            "# Model comparison",
            "",
            "- Date: \(dateFormatter.string(from: date))",
            "- Recording: last dictation, \(seconds(audioSeconds))",
            "- Language: \(requestedLanguage ?? "auto")",
            "",
            "| Model | Load | Transcribe | Speed |",
            "| --- | --- | --- | --- |",
        ]
        for result in results {
            let load: String
            let speed: String
            if case .failed = result.outcome {
                load = result.loadSeconds.map(seconds) ?? "—"
                speed = "failed"
            } else {
                load = result.loadSeconds.map(seconds) ?? "already loaded"
                speed = result.speed(audioSeconds: audioSeconds).map(times) ?? "—"
            }
            let transcribe = result.transcribeSeconds.map(seconds) ?? "—"
            lines.append("| \(title(result.model, isCurrent: result.isCurrent)) | \(load) | \(transcribe) | \(speed) |")
        }
        if let running {
            lines.append("| \(running.displayName) | running… | | |")
        }
        for model in waiting {
            lines.append("| \(model.displayName) | waiting | | |")
        }
        lines += [
            "",
            "Speed: how many times faster than real time (higher is faster). "
                + "Load includes the one-time CoreML preparation the first time a model runs on this Mac.",
        ]

        // Only texts with words in them are compared: against an empty or
        // failed run every word would differ, which says nothing.
        let texts: [Int: String] = Dictionary(uniqueKeysWithValues: results.indices.compactMap { index -> (Int, String)? in
            guard case .transcribed(let text, _) = results[index].outcome else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (index, trimmed)
        })
        let compared = texts.keys.sorted()
        var spans: [Int: [Range<String.Index>]] = [:]
        if compared.count >= 2 {
            let differing = ModelComparisonDiff.differingSpans(in: compared.map { texts[$0]! })
            for (position, index) in compared.enumerated() {
                spans[index] = differing[position]
            }
            if differing.allSatisfy(\.isEmpty) {
                lines.append("All models recognized the same words (case and punctuation aside).")
            } else {
                lines.append(style == .markdown
                    ? "Words in **bold** differ between models."
                    : "Highlighted words differ between models.")
            }
        }

        var output = lines.joined(separator: "\n")
        var highlights: [NSRange] = []
        func append(_ line: String) {
            output += "\n" + line
        }

        for (index, result) in results.enumerated() {
            append("")
            append("## \(title(result.model, isCurrent: result.isCurrent))")
            append("")
            if result.languageFellBack {
                append("_Auto-detected: the model has no \(requestedLanguage ?? "")._")
                append("")
            }
            switch result.outcome {
            case .transcribed(_, let incomplete):
                if let text = texts[index] {
                    let textSpans = spans[index] ?? []
                    switch style {
                    case .markdown:
                        append(bolded(text, spans: textSpans))
                    case .display:
                        output += "\n"
                        let base = (output as NSString).length
                        for span in textSpans {
                            let local = NSRange(span, in: text)
                            highlights.append(NSRange(location: base + local.location, length: local.length))
                        }
                        output += text
                    }
                } else {
                    append("_No speech recognized._")
                }
                if incomplete {
                    append("")
                    append("_Part of the recording could not be transcribed._")
                }
            case .failed(let message):
                append("_Failed: \(message)_")
            }
        }
        return Rendered(text: output + "\n", highlights: highlights)
    }

    private static func bolded(_ text: String, spans: [Range<String.Index>]) -> String {
        var result = ""
        var cursor = text.startIndex
        for span in spans {
            result += text[cursor..<span.lowerBound]
            result += "**" + text[span] + "**"
            cursor = span.upperBound
        }
        result += text[cursor...]
        return result
    }

    private static func title(_ model: WhisperModel, isCurrent: Bool) -> String {
        isCurrent ? "\(model.displayName) (current)" : model.displayName
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }

    private static func times(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f×", value) : String(format: "%.1f×", value)
    }
}

// MARK: - Runner

@MainActor
enum ModelComparisonRunner {
    /// Run `audio` through every model in `models`, one at a time, with the
    /// dictation pipeline (30 s windows, empty-result rescue, one retry).
    /// `onProgress` is called before each model and once at the end with the
    /// running model set to nil. A cancelled run drops the model in flight.
    static func run(
        audio: DictationAudioSnapshot,
        models: [WhisperModel],
        transcriber: Transcriber,
        language: String?,
        onProgress: @MainActor (_ running: WhisperModel?, _ results: [ModelComparisonResult]) -> Void
    ) async -> [ModelComparisonResult] {
        guard let buffer = audio.makeBuffer() else { return [] }
        var results: [ModelComparisonResult] = []
        for model in models {
            guard !Task.isCancelled else { break }
            onProgress(model, results)
            let result = await runOne(
                model: model,
                buffer: buffer,
                transcriber: transcriber,
                language: language
            )
            guard !Task.isCancelled else { break }
            results.append(result)
        }
        onProgress(nil, results)
        return results
    }

    private static func runOne(
        model: WhisperModel,
        buffer: AVAudioPCMBuffer,
        transcriber: Transcriber,
        language: String?
    ) async -> ModelComparisonResult {
        let isCurrent = model == transcriber.selectedModel
        let session = transcriber.makeComparisonSession(for: model, language: language)
        let fellBack = language != nil && session.preferredLanguage == nil

        return await withTaskCancellationHandler {
            let loadStart = Date()
            do {
                try await transcriber.preloadModel(for: session)
            } catch {
                return ModelComparisonResult(
                    model: model,
                    isCurrent: isCurrent,
                    language: session.preferredLanguage,
                    languageFellBack: fellBack,
                    loadSeconds: nil,
                    transcribeSeconds: nil,
                    outcome: .failed(error.localizedDescription)
                )
            }
            let loadSeconds = isCurrent ? nil : Date().timeIntervalSince(loadStart)

            let start = Date()
            let outcome = await AppDelegate.transcribeWindowed(
                buffer: buffer,
                logPrefix: "compare \(model.variant)"
            ) { slice in
                try await transcriber.transcribe(audio: slice, session: session)
            }
            return ModelComparisonResult(
                model: model,
                isCurrent: isCurrent,
                language: session.preferredLanguage,
                languageFellBack: fellBack,
                loadSeconds: loadSeconds,
                transcribeSeconds: Date().timeIntervalSince(start),
                outcome: .transcribed(
                    text: outcome.fragments.joined(separator: " "),
                    incomplete: outcome.requiresRecovery
                )
            )
        } onCancel: {
            Task { @MainActor in transcriber.cancel(session) }
        }
    }
}

// MARK: - Saved reports

enum ModelComparisonStore {
    /// `~/Documents/Voicely/comparisons`, private like the other transcript folders.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Voicely/comparisons")
    }

    static func save(_ markdown: String, date: Date) -> URL? {
        let fm = FileManager.default
        let dir = directory
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let url = dir.appendingPathComponent("\(formatter.string(from: date)).md")
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            NSLog("[Voicely] Failed to save model comparison: %@", error.localizedDescription)
            return nil
        }
    }
}

// MARK: - Window

/// A plain window with the report text, a status line and Show in Finder.
/// Closing it while the comparison runs cancels the comparison.
@MainActor
final class ModelComparisonWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let window: NSWindow
    private let scrollView = NSTextView.scrollableTextView()
    private var textView: NSTextView { scrollView.documentView as! NSTextView }
    private let statusField = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private var savedURL: URL?

    init(title: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.delegate = self

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingMiddle
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        revealButton.bezelStyle = .rounded
        revealButton.target = self
        revealButton.action = #selector(reveal)
        revealButton.isEnabled = false

        let bar = NSStackView(views: [statusField, NSView(), revealButton])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 10, right: 16)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scrollView)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            bar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(report: ModelComparisonReport.Rendered, status: String) {
        show(report)
        statusField.stringValue = status
    }

    func finish(report: ModelComparisonReport.Rendered, savedURL: URL?) {
        show(report)
        self.savedURL = savedURL
        revealButton.isEnabled = savedURL != nil
        statusField.stringValue = savedURL.map { "Saved to \($0.path)" } ?? "Could not save the report"
    }

    func close() {
        window.close()
    }

    private func show(_ report: ModelComparisonReport.Rendered) {
        let text = NSMutableAttributedString(
            string: report.text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ]
        )
        for range in report.highlights {
            text.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.35),
                range: range
            )
        }
        textView.textStorage?.setAttributedString(text)
    }

    @objc private func reveal() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
