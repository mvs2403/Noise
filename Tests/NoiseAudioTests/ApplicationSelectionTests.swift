import XCTest
import NoiseAudio
import CNoiseRuntime

final class ApplicationSelectionTests: XCTestCase {
    private let teams = AudioApplication(id: "com.example.teams", name: "Teams", processIDs: [10, 11])
    private let chrome = AudioApplication(id: "com.example.chrome", name: "Chrome", processIDs: [20, 21, 21])

    func testLegacySingleAppMigratesWithoutChangingTheChoice() {
        let selection = ApplicationSelection(restoring: nil, legacyBundleID: chrome.id, available: [teams, chrome])
        XCTAssertEqual(selection.applications, [chrome.reference])
        XCTAssertEqual(selection.resolve(in: [chrome]).first?.processIDs, [20, 21, 21])
    }

    func testMultipleSelectionsPersistWithoutSavingStaleProcessIDs() throws {
        let selection = ApplicationSelection([teams.reference, chrome.reference, teams.reference])
        let restored = ApplicationSelection(restoring: try XCTUnwrap(selection.encoded()), legacyBundleID: nil, available: [])
        XCTAssertEqual(restored.ids, [teams.id, chrome.id])
        XCTAssertTrue(restored.resolve(in: []).allSatisfy { $0.processIDs.isEmpty })
        // Restarted apps must use their new audio processes; a closed app stays selected.
        let restarted = AudioApplication(id: teams.id, name: teams.name, processIDs: [99])
        let resolved = restored.resolve(in: [restarted])
        XCTAssertEqual(resolved.first { $0.id == teams.id }?.processIDs, [99])
        XCTAssertEqual(resolved.first { $0.id == chrome.id }?.processIDs, [])
        XCTAssertEqual(restored.summary, "Chrome + 1 app")
    }

    func testDeliberatelyEmptySelectionDoesNotRestoreLegacyApp() {
        let selection = ApplicationSelection(restoring: ApplicationSelection().encoded(), legacyBundleID: teams.id, available: [teams])
        XCTAssertTrue(selection.applications.isEmpty)
        XCTAssertEqual(selection.summary, "Select applications…")
    }

    func testSharedTapIncludesEveryAppAndDeduplicatesHelpers() {
        let group = AudioApplicationGroup(applications: [teams, chrome, chrome])
        XCTAssertEqual(group.bundleIDs, [chrome.id, teams.id])
        XCTAssertEqual(group.processIDs, [10, 11, 20, 21])
    }

    func testEmptySelectionIsRejectedBeforeLoadingOrCapturingAudio() async {
        let router = AudioRouter(paths: RuntimePaths(root: URL(fileURLWithPath: "/nonexistent")))
        do {
            try await router.startIncoming(engine: .dpdfnet, apps: [], output: 0, bypass: false, voiceLeveling: true)
            XCTFail("An empty selection must never become a system-wide tap")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Choose at least one application"))
        }
    }

    func testNativeCaptureAlsoRejectsAnEmptyGroup() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = RuntimePaths(root: root)
        guard paths.isAvailable(.rnnoise) else { throw XCTSkip("RNNoise runtime not installed") }
        var error = [CChar](repeating: 0, count: 1024)
        let pipeline = try XCTUnwrap(nr_pipeline_create(Int32(NR_RNNOISE), paths.libraries.path, paths.models.path, &error, Int32(error.count)))
        defer { nr_pipeline_destroy(pipeline) }
        XCTAssertFalse(nr_pipeline_start_apps(pipeline, nil, 0, &error, Int32(error.count)))
        XCTAssertFalse(String(cString: error).isEmpty)
        XCTAssertFalse(nr_pipeline_start_apps(pipeline, nil, 1, &error, Int32(error.count)))
        XCTAssertTrue(String(cString: error).contains("invalid"))
        XCTAssertEqual(nr_pipeline_stats(pipeline).input_frames, 0)
    }
}
