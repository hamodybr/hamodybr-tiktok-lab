import XCTest

final class LabImportUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }
    private func choose(_ name: String, app: XCUIApplication) {
        app.buttons["import-files"].tap()
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        if !file.waitForExistence(timeout: 4) {
            // Files may ignore directoryURL and open the provider root instead.
            let folder = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "HAMODYBR Lab")).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 10), "The app Documents folder is not exposed to Files.\n" + app.debugDescription)
            folder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 15), "File picker did not show seeded file.\n" + app.debugDescription)
        XCTAssertTrue(file.isEnabled, "The picker disabled a valid file type.\n" + file.debugDescription)
        print("Picking file: \(file.debugDescription)")
        // Tap the video thumbnail to avoid an ambiguous grid-cell hit point.
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
    }
    func testFilesPickerSelectionProducesAnalysis() {
        let app = launch()
        choose("Sample-60fps", app: app)
        let report = app.staticTexts["report-file-name"]
        XCTAssertTrue(report.waitForExistence(timeout: 25), "Selected file did not produce a report.\n" + app.debugDescription)
        XCTAssertEqual(report.label, "Sample-60fps.mp4")
    }
    func testFilesPickerCancelLeavesImporterUsable() {
        let app = launch()
        app.buttons["import-files"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Cancel", "إلغاء")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription)
        cancel.tap()
        let status = app.staticTexts["lab-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "أُلغي اختيار الملف")
        XCTAssertTrue(app.buttons["import-files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["import-files"].isEnabled)
    }
    func testImportedReportSurvivesRelaunch() {
        let app = launch()
        choose("Sample-60fps", app: app)
        let done = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "اكتمل الفحص")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 25), app.debugDescription)
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let restored = app.staticTexts["report-file-name"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(restored.label, "Sample-60fps.mp4")
    }
    func testEmptyFileShowsFailureInsteadOfSilence() {
        let app = launch()
        choose("Empty-test", app: app)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 15), "No error appeared for empty selected file.\n" + app.debugDescription)
        app.alerts.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["import-files"].isEnabled)
    }
}
