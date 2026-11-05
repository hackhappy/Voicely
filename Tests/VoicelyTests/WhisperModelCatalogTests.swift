import XCTest
@testable import VoicelyCore

final class WhisperModelCatalogTests: XCTestCase {
    /// Voicely Lab carries the 1.2.0 line-up so the models can be compared.
    /// Adding or dropping a model must be a deliberate data change reflected here.
    func testCatalogMatchesRequestedProductLine() {
        XCTAssertEqual(
            WhisperModel.all.map(\.variant),
            [
                "parakeet-tdt-0.6b-v3",
                "parakeet-ultra",
                "gigaam-v3-e2e-rnnt",
                "gigaam-multilingual-ctc",
                "large-v3-v20240930_turbo_632MB",
                "large-v3_turbo",
                "medium",
            ]
        )
    }

    func testAvailabilityFollowsRAMThresholds() {
        let light = [
            "parakeet-tdt-0.6b-v3",
            "parakeet-ultra",
            "gigaam-v3-e2e-rnnt",
            "gigaam-multilingual-ctc",
            "large-v3-v20240930_turbo_632MB",
        ]
        XCTAssertEqual(WhisperModel.available(forSystemRAMGB: 8).map(\.variant), light)
        XCTAssertEqual(
            WhisperModel.available(forSystemRAMGB: 16).map(\.variant),
            light + ["medium"]
        )
        XCTAssertEqual(
            WhisperModel.available(forSystemRAMGB: 24).map(\.variant),
            WhisperModel.all.map(\.variant)
        )
    }

    func testInstalledVariantsAreRecordedPerVariant() throws {
        let suite = "WhisperModelCatalogTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        WhisperModel.setInstalled(true, variant: "medium", in: defaults)
        WhisperModel.setInstalled(true, variant: "gigaam-v3-e2e-rnnt", in: defaults)
        WhisperModel.setInstalled(true, variant: "medium", in: defaults)
        XCTAssertEqual(
            WhisperModel.installedVariants(in: defaults),
            ["medium", "gigaam-v3-e2e-rnnt"]
        )

        WhisperModel.setInstalled(false, variant: "medium", in: defaults)
        XCTAssertEqual(WhisperModel.installedVariants(in: defaults), ["gigaam-v3-e2e-rnnt"])
    }

    /// A folder left by an interrupted download is not an installed model.
    func testModelIsNotInstalledUntilRecorded() throws {
        let suite = "WhisperModelCatalogTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        for model in WhisperModel.all {
            XCTAssertFalse(model.isInstalled(in: defaults), model.variant)
        }
    }

    func testRecommendationIsParakeetOnEveryTier() {
        for ram: UInt64 in [8, 16, 24] {
            XCTAssertEqual(
                WhisperModel.recommended(forSystemRAMGB: ram, availableDiskBytes: nil).variant,
                "parakeet-tdt-0.6b-v3"
            )
        }
    }

    func testModelCapabilitiesMatchActualBackends() throws {
        let parakeet = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .parakeetTDTV3 }
        )
        XCTAssertEqual(parakeet.capabilities.supportedLanguages?.count, 25)
        XCTAssertTrue(parakeet.capabilities.supportedLanguages?.contains("ru") ?? false)
        XCTAssertTrue(parakeet.capabilities.supportedLanguages?.contains("en") ?? false)
        XCTAssertTrue(parakeet.capabilities.supportsLanguageDetection)
        XCTAssertFalse(parakeet.capabilities.supportsTranslationToEnglish)
        XCTAssertEqual(parakeet.capabilities.minimumMacOSMajorVersion, 14)
        XCTAssertNotNil(parakeet.requestValidationError(translateToEnglish: true, language: nil))
        XCTAssertNotNil(parakeet.requestValidationError(translateToEnglish: false, language: "ja"))
        XCTAssertNil(parakeet.requestValidationError(translateToEnglish: false, language: "de"))
        XCTAssertNil(parakeet.requestValidationError(translateToEnglish: false, language: "ru"))
    }

    /// Ultra is v3 with other weights: same languages and requests, its own
    /// folder next to v3 (where FluidAudio's `.ultra` download lands).
    func testParakeetUltraMatchesV3ButHasItsOwnFolder() throws {
        let v3 = try XCTUnwrap(WhisperModel.all.first { $0.backend == .parakeetTDTV3 })
        let ultra = try XCTUnwrap(WhisperModel.all.first { $0.backend == .parakeetUltra })
        XCTAssertEqual(ultra.capabilities, v3.capabilities)
        XCTAssertEqual(ultra.modelDirectory.lastPathComponent, "parakeet-ultra")
        XCTAssertEqual(
            ultra.modelDirectory.deletingLastPathComponent(),
            v3.modelDirectory.deletingLastPathComponent()
        )
        XCTAssertTrue(ultra.userFacingLabel(isRecommended: false).contains("Most accurate"))
    }

    func testParakeetLabelStatesSpeedAndCoverage() throws {
        let model = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .parakeetTDTV3 }
        )
        let label = model.userFacingLabel(isRecommended: false)
        XCTAssertTrue(label.contains("Fastest"), label)
        XCTAssertTrue(label.contains("25 European languages"), label)
    }

    /// `available()` already filters by RAM, so stating RAM in a label is
    /// noise the reader has to look past.
    func testLabelsCarryNoFactTrueOfEveryModel() {
        for model in WhisperModel.all {
            let label = model.userFacingLabel(isRecommended: false)
            XCTAssertFalse(label.contains("punctuated"), label)
            XCTAssertFalse(label.contains("RAM"), label)
        }
    }
}
