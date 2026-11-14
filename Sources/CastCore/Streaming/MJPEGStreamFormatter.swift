import Foundation

public enum MJPEGStreamFormatter {
    public static let defaultBoundary = "--castliteframe"

    public static func formatFrame(jpegData: Data, boundary: String = defaultBoundary) -> Data {
        var header = "\(boundary)\r\n"
        header += "Content-Type: image/jpeg\r\n"
        header += "Content-Length: \(jpegData.count)\r\n\r\n"

        var frameData = Data(header.utf8)
        frameData.append(jpegData)
        frameData.append(Data("\r\n".utf8))
        return frameData
    }

    public static func multipartHeader(boundary: String = "castliteframe") -> [String: String] {
        return [
            "Content-Type": "multipart/x-mixed-replace; boundary=\(boundary)",
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Pragma": "no-cache",
            "Connection": "close"
        ]
    }
}
