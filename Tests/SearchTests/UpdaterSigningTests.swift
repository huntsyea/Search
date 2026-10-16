import XCTest
@testable import Search

/// Only a build Office Commun signed updates itself from Office Commun's
/// feed (Updater.updatesItself): a build signed by anyone else would be
/// replaced by the next official release, and what it adds lost with it.
final class UpdaterSigningTests: XCTestCase {
    func testOnlyOfficeCommunsTeamUpdatesItself() {
        XCTAssertTrue(Updater.isOfficeCommun("7BYKA895MC"))
        XCTAssertFalse(Updater.isOfficeCommun("5J4FVDUC9M"), "another Developer ID")
        XCTAssertFalse(Updater.isOfficeCommun(nil), "ad-hoc or unsigned")
        XCTAssertFalse(Updater.isOfficeCommun(""))
    }

    /// The test runner isn't Office Commun's, so it reads as a build that
    /// doesn't update itself.
    func testThisProcessIsNotOfficeCommuns() {
        XCTAssertFalse(Updater.signedByOfficeCommun)
    }
}
