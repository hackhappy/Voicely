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

// MARK: - Report

enum ModelComparisonReport {
    /// Markdown for the window and the saved file. `running` and `waiting`
    /// keep the table complete while the comparison is still in progress.
    static func markdown(
        date: Date,
        audioSeconds: Double,
        requestedLanguage: String?,
        results: [ModelComparisonResult],
        running: WhisperModel? = nil,
        waiting: [WhisperModel] = []
    ) -> String {
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

        for result in results {
            lines += ["", "## \(title(result.model, isCurrent: result.isCurrent))", ""]
            if result.languageFellBack {
                lines += ["_Auto-detected: the model has no \(requestedLanguage ?? "")._", ""]
            }
            switch result.outcome {
            case .transcribed(let text, let incomplete):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(trimmed.isEmpty ? "_No speech recognized._" : trimmed)
                if incomplete {
                    lines += ["", "_Part of the recording could not be transcribed._"]
                }
            case .failed(let message):
                lines.append("_Failed: \(message)_")
            }
        }
        return lines.joined(separator: "\n") + "\n"
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

    func update(report: String, status: String) {
        textView.string = report
        statusField.stringValue = status
    }

    func finish(report: String, savedURL: URL?) {
        textView.string = report
        self.savedURL = savedURL
        revealButton.isEnabled = savedURL != nil
        statusField.stringValue = savedURL.map { "Saved to \($0.path)" } ?? "Could not save the report"
    }

    func close() {
        window.close()
    }

    @objc private func reveal() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
