import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking

extension URLSession {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }

    public func data(from url: URL) async throws -> (Data, URLResponse) {
        return try await data(for: URLRequest(url: url))
    }
}
#endif
