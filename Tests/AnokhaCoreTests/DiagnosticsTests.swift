import AnokhaCore
import Foundation
import XCTest

final class DiagnosticsTests: XCTestCase {
    func testValidationIssuesMapToStableCategories() {
        let issue = ValidationIssue(
            code: .executableMissing,
            severity: .error,
            message: "Gone"
        )
        XCTAssertEqual(DiagnosticsService().diagnostic(for: issue).category, .fileMissing)
    }

    func testPermissionErrorsGetActionableMessageAndRawDetails() {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EACCES),
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )
        let diagnostic = DiagnosticsService().diagnostic(for: error)
        XCTAssertEqual(diagnostic.category, .permissionDenied)
        XCTAssertNotNil(diagnostic.rawDetails)
        XCTAssertTrue(diagnostic.message.contains("System Settings"))
    }

    func testRepeatedRunnerFailuresAreCategorized() {
        let status = RunnerStatus(
            jobID: UUID(),
            state: .waitingToRestart,
            runnerPID: 10,
            lastExitCode: 42,
            consecutiveFailures: 3,
            runCount: 3
        )
        XCTAssertEqual(DiagnosticsService().diagnostic(for: status)?.category, .repeatedlyFailing)
    }
}
