import XCTest

/// End-to-end tests in demo mode (an in-memory library; the real Photos library is never touched).
/// Every screen is checked with Xcode's accessibility audit: contrast, element descriptions,
/// hit areas, Dynamic Type and clipped text.
final class MediaSlimUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-resetState"] + extra
        app.launch()
        return app
    }

    /// Runs the audit and reports every issue with enough detail to fix it from the CI log.
    @MainActor
    private func audit(_ app: XCUIApplication, _ screen: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try app.performAccessibilityAudit { issue in
            let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' id='\($0.identifier)'" } ?? "none"
            XCTContext.runActivity(named: "[\(screen)] \(issue.auditType): \(issue.compactDescription) — \(element)") { _ in }
            print("ACCESSIBILITY [\(screen)] \(issue.auditType): \(issue.compactDescription) — \(issue.detailedDescription) — \(element)")
            return false
        }
    }

    @MainActor
    func testOnboardingIsAccessible() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Allow Photo Access"].waitForExistence(timeout: 10))
        try audit(app, "onboarding")
    }

    @MainActor
    func testReplaceFlowFromScanToResults() throws {
        let app = launch(["-skipOnboarding"])

        let library = app.buttons["source.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        try audit(app, "home")
        library.tap()

        let start = app.buttons["review.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertFalse(start.isEnabled, "Start must wait for an explicit choice about originals")
        try audit(app, "review")

        app.buttons["handling.replace"].tap()
        XCTAssertTrue(start.isEnabled)
        start.tap()

        let done = app.buttons["results.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 60))
        try audit(app, "results")

        let deleted = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Recently Deleted")).firstMatch
        XCTAssertTrue(deleted.exists, "Originals should be reported as moved to Recently Deleted")

        done.tap()
        XCTAssertTrue(library.waitForExistence(timeout: 10))
    }

    @MainActor
    func testKeepBothDeletesNothing() throws {
        let app = launch(["-skipOnboarding"])
        app.buttons["source.library"].tap()
        let start = app.buttons["review.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        app.buttons["handling.keepBoth"].tap()
        start.tap()
        XCTAssertTrue(app.buttons["results.done"].waitForExistence(timeout: 60))
        let kept = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "originals are untouched")).firstMatch
        XCTAssertTrue(kept.exists)
    }

    @MainActor
    func testLargestAccessibilityTextSize() throws {
        let app = launch(["-skipOnboarding", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let library = app.buttons["source.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        try audit(app, "home-xxxl")
        library.tap()
        XCTAssertTrue(app.buttons["review.start"].waitForExistence(timeout: 15))
        try audit(app, "review-xxxl")
    }

    @MainActor
    func testHebrewRightToLeft() throws {
        let app = launch(["-skipOnboarding", "-AppleLanguages", "(he)", "-AppleLocale", "he_IL"])
        XCTAssertTrue(app.staticTexts["מה לכווץ?"].waitForExistence(timeout: 10), "Home should be in Hebrew")
        try audit(app, "home-he")
        app.buttons["source.library"].tap()
        XCTAssertTrue(app.buttons["review.start"].waitForExistence(timeout: 15))
        try audit(app, "review-he")
    }
}
