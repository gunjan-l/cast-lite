import XCTest
import CastCore
@testable import CastLite

final class StatusPresentationTests: XCTestCase {

    private func input(
        _ state: CastConnectionState = .disconnected,
        scanning: Bool = false,
        reconnecting: Bool = false,
        tv: String? = "Living Room TV",
        error: String? = nil,
        permissionDeclined: Bool = false
    ) -> StatusInput {
        StatusInput(
            connectionState: state,
            isScanning: scanning,
            isReconnecting: reconnecting,
            selectedDeviceName: tv,
            errorMessage: error,
            localNetworkDeclined: permissionDeclined
        )
    }

    private func status(_ i: StatusInput) -> StatusModel { StatusPresentation.status(for: i) }

    func testNoSelectedTVAsksToChooseOneInEveryConnectionState() {
        let states: [CastConnectionState] = [.disconnected, .connecting, .ready, .streaming, .error("boom")]
        for state in states {
            let model = status(input(state, tv: nil))
            XCTAssertEqual(model.title, "Choose a TV", "state \(state)")
        }
    }

    func testEveryConnectionStateWithATVHasItsOwnSymbolTitleAndSubtitle() {
        let states: [CastConnectionState] = [.disconnected, .connecting, .ready, .streaming, .error("boom")]
        let models = states.map { status(input($0)) }
        XCTAssertEqual(Set(models.map(\.title)).count, states.count)
        for model in models {
            XCTAssertFalse(model.symbol.isEmpty)
            XCTAssertFalse(model.title.isEmpty)
            XCTAssertFalse(model.subtitle.isEmpty)
        }
    }

    func testScanningConnectingReconnectingAndStreamingAreDistinct() {
        let scanning = status(input(tv: nil).with(scanning: true))
        let connecting = status(input(.connecting))
        let reconnecting = status(input(.connecting, reconnecting: true))
        let streaming = status(input(.streaming))
        let titles = [scanning, connecting, reconnecting, streaming].map(\.title)
        XCTAssertEqual(Set(titles).count, 4)
        let symbols = [scanning, connecting, reconnecting, streaming].map(\.symbol)
        XCTAssertEqual(Set(symbols).count, 4)
    }

    func testStreamingNamesTheTV() {
        let model = status(input(.streaming, tv: "Bedroom TV"))
        XCTAssertTrue(model.subtitle.contains("Bedroom TV"))
    }

    func testErrorMessageSurvivesEveryState() {
        let states: [CastConnectionState] = [.disconnected, .connecting, .ready, .streaming]
        for state in states {
            XCTAssertEqual(status(input(state, error: "TV disconnected.")).errorText, "TV disconnected.", "state \(state)")
            XCTAssertEqual(status(input(state, tv: nil, error: "TV disconnected.")).errorText, "TV disconnected.", "no TV, state \(state)")
        }
        XCTAssertEqual(status(input(error: "TV disconnected.", permissionDeclined: true)).errorText, "TV disconnected.")
    }

    func testNoErrorMeansNoErrorText() {
        XCTAssertNil(status(input(.streaming)).errorText)
    }

    func testErrorStateShowsItsMessageEvenWithoutSeparateErrorMessage() {
        XCTAssertEqual(status(input(.error("Timed out"))).errorText, "Timed out")
    }

    func testDeclinedLocalNetworkPermissionExplainsHowToEnableAccess() {
        for state in [CastConnectionState.disconnected, .connecting, .ready] {
            let model = status(input(state, tv: nil, permissionDeclined: true))
            XCTAssertTrue(model.subtitle.contains("Settings"), "state \(state)")
            XCTAssertTrue(model.subtitle.localizedCaseInsensitiveContains("Local Network"), "state \(state)")
            XCTAssertTrue(model.title.localizedCaseInsensitiveContains("TV"), "state \(state)")
        }
    }
}

private extension StatusInput {
    func with(scanning: Bool) -> StatusInput {
        var copy = self
        copy.isScanning = scanning
        return copy
    }
}

final class StatusAnnouncementTests: XCTestCase {

    private func model(_ state: CastConnectionState, tv: String? = "Living Room TV",
                       reconnecting: Bool = false, error: String? = nil) -> StatusInput {
        StatusInput(
            connectionState: state, isScanning: false, isReconnecting: reconnecting,
            selectedDeviceName: tv, errorMessage: error, localNetworkDeclined: false)
    }

    func testNoAnnouncementOnFirstRenderOrWhenNothingChanged() {
        XCTAssertNil(StatusAnnouncement.text(from: nil, to: model(.streaming)))
        XCTAssertNil(StatusAnnouncement.text(from: model(.ready), to: model(.ready)))
    }

    func testStartingToMirrorIsAnnouncedWithTheTVName() {
        let text = StatusAnnouncement.text(from: model(.ready), to: model(.streaming, tv: "Bedroom TV"))
        XCTAssertEqual(text, "Mirroring started on Bedroom TV.")
    }

    func testFailureIsAnnouncedWithTheErrorText() {
        let text = StatusAnnouncement.text(from: model(.streaming), to: model(.error("Timed out")))
        XCTAssertEqual(text, "Connection problem. Timed out")
    }

    func testRecoveryAfterReconnectingOrErrorIsAnnounced() {
        XCTAssertEqual(
            StatusAnnouncement.text(from: model(.connecting, reconnecting: true), to: model(.streaming)),
            "Mirroring resumed.")
        XCTAssertEqual(
            StatusAnnouncement.text(from: model(.error("Timed out")), to: model(.ready)),
            "Connection recovered.")
    }

    func testOtherTransitionsStaySilent() {
        XCTAssertNil(StatusAnnouncement.text(from: model(.disconnected), to: model(.connecting)))
        XCTAssertNil(StatusAnnouncement.text(from: model(.streaming), to: model(.ready)))
    }

    func testSameErrorIsNotAnnouncedTwice() {
        XCTAssertNil(StatusAnnouncement.text(from: model(.error("x")), to: model(.error("x"))))
    }
}

final class MirrorHapticTests: XCTestCase {
    func testStartFires() {
        XCTAssertTrue(MirrorHaptic.shouldFire(wasStreaming: false, isStreaming: true, errorMessage: nil))
    }

    func testUserStopFires() {
        XCTAssertTrue(MirrorHaptic.shouldFire(wasStreaming: true, isStreaming: false, errorMessage: nil))
    }

    func testStopCausedByErrorIsSilent() {
        XCTAssertFalse(MirrorHaptic.shouldFire(wasStreaming: true, isStreaming: false, errorMessage: "TV disconnected."))
    }

    func testNoFlipIsSilent() {
        XCTAssertFalse(MirrorHaptic.shouldFire(wasStreaming: true, isStreaming: true, errorMessage: nil))
        XCTAssertFalse(MirrorHaptic.shouldFire(wasStreaming: false, isStreaming: false, errorMessage: nil))
    }
}
