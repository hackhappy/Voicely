import Foundation
import XCTest
@testable import VoicelyCLI
@testable import VoicelyCore

final class StatusSnapshotTests: XCTestCase {
    /// A persisted variant the catalog does not carry (here Whisper "small",
    /// which no release shipped) must read as "no selection" so the app falls
    /// back to the recommendation instead of resurrecting an unknown model.
    func testStaleSavedVariantReadsAsNoSelection() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }
        defaults.set("small", forKey: "whisperModel")

        let recommended = WhisperModel.all[0]
        let snapshot = StatusSnapshot.gather(
            version: "test",
            defaults: defaults,
            recommendedModel: recommended,
            systemRAMGB: 16,
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 0,
                patchVersion: 0
            ),
            fileExists: { path in
                path.contains("openai_whisper-small")
            }
        )

        XCTAssertNil(snapshot.selectedModel)
        XCTAssertEqual(snapshot.recommendedModel.variant, "parakeet-tdt-0.6b-v3")
        XCTAssertTrue(snapshot.jsonObject["selectedModel"] is NSNull)
    }

    func testStatusSnapshotExplainsWhenNoModelIsSavedYet() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let recommended = WhisperModel.all[0]
        let snapshot = StatusSnapshot.gather(
            version: "test",
            defaults: defaults,
            recommendedModel: recommended,
            systemRAMGB: 8,
            fileExists: { _ in false }
        )

        XCTAssertNil(snapshot.selectedModel)
        XCTAssertTrue(snapshot.textLines.contains { $0.contains("none saved yet") })
        XCTAssertTrue(snapshot.jsonObject["selectedModel"] is NSNull)
        XCTAssertTrue(snapshot.jsonObject["selectedModelDownloaded"] is NSNull)
        XCTAssertEqual(snapshot.jsonObject["modelDownloaded"] as? Bool, false)
    }
}
