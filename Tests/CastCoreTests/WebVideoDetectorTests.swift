import XCTest
import Foundation
@testable import CastCore

final class WebVideoDetectorTests: XCTestCase {

    func testStreamURLValidation() {
        XCTAssertTrue(WebVideoDetector.isValidStreamURL("https://example.com/stream/movie.mp4"))
        XCTAssertTrue(WebVideoDetector.isValidStreamURL("https://example.com/live/playlist.m3u8?token=xyz"))
        XCTAssertTrue(WebVideoDetector.isValidStreamURL("http://cdn.videos.org/video.mp4#t=10"))
        XCTAssertTrue(WebVideoDetector.isValidStreamURL("https://media.org/stream.webm"))

        XCTAssertFalse(WebVideoDetector.isValidStreamURL("https://example.com/image.png"))
        XCTAssertFalse(WebVideoDetector.isValidStreamURL("https://example.com/style.css"))
        XCTAssertFalse(WebVideoDetector.isValidStreamURL("javascript:void(0)"))
        XCTAssertFalse(WebVideoDetector.isValidStreamURL(""))
    }

    func testJavaScriptSnifferScriptContainsHooks() {
        let script = WebVideoDetector.snifferUserScript()

        XCTAssertTrue(script.contains("MutationObserver"))
        XCTAssertTrue(script.contains("videoDetector"))
        XCTAssertTrue(script.contains("HTMLMediaElement"))
        XCTAssertTrue(script.contains("postMessage"))
    }

    func testProcessJSMessageValidVideo() {
        let detector = WebVideoDetector()
        let messageBody: [String: Any] = [
            "url": "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
            "title": "Big Buck Bunny"
        ]

        let detectedVideo = detector.processMessage(body: messageBody)
        XCTAssertNotNil(detectedVideo)
        XCTAssertEqual(detectedVideo?.title, "Big Buck Bunny")
        XCTAssertEqual(detectedVideo?.url.absoluteString, "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")
        XCTAssertEqual(detectedVideo?.format, .mp4)
    }

    func testProcessJSMessageInvalidPayload() {
        let detector = WebVideoDetector()
        let emptyBody: [String: Any] = [:]
        XCTAssertNil(detector.processMessage(body: emptyBody))

        let nonVideoBody: [String: Any] = [
            "url": "https://example.com/photo.jpg",
            "title": "Photo"
        ]
        XCTAssertNil(detector.processMessage(body: nonVideoBody))
    }
}
