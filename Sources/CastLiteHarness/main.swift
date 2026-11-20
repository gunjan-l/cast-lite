import Foundation
import CastCore

// Usage: CastLiteHarness <stream.h264> <fps> <port> <lingerSeconds>
// Feeds an Annex-B H.264 file to MirrorSession (browser-only) at real-time pace, then keeps serving.
let args = CommandLine.arguments
guard args.count == 5, let fps = Double(args[2]), let port = UInt16(args[3]), let linger = Double(args[4]),
      let data = FileManager.default.contents(atPath: args[1]) else {
    FileHandle.standardError.write(Data("usage: CastLiteHarness <stream.h264> <fps> <port> <lingerSeconds>\n".utf8))
    exit(2)
}

let units = AnnexBSplitter.accessUnits(from: data, framesPerSecond: fps)
guard !units.isEmpty else {
    FileHandle.standardError.write(Data("no access units found in \(args[1])\n".utf8))
    exit(2)
}

let session = MirrorSession(port: port, hostResolver: { "127.0.0.1" })

Task {
    do {
        let url = try await session.start(handoff: nil)
        print("harness: serving \(url), feeding \(units.count) access units at \(fps) fps")
        let origin = Date()
        for unit in units {
            let due = origin.addingTimeInterval(unit.pts.seconds)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            session.append(unit)
        }
        print("harness: feed complete, lingering \(linger)s")
        try await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
        await session.stop()
        print("harness: done")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("harness: failed: \(error)\n".utf8))
        exit(1)
    }
}

RunLoop.main.run()
