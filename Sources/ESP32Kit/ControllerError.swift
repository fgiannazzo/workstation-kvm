import Foundation

/// What can go wrong talking to the ESP32 controller. The cases map one to one onto what a
/// caller can do about it: `unreachable` and `timeout` mean "check the address and the network",
/// `httpStatus` means the controller answered and refused, `invalidResponse` means it answered
/// with something that is not the contract.
public enum ControllerError: Error, Sendable, Equatable {
    /// The connection could not be made or was lost (refused, no route, DNS failure, reset).
    case unreachable(URL, underlying: String)
    /// The controller answered with a non-2xx status. `body` is the response text, normally
    /// `{"error":"..."}`.
    case httpStatus(Int, body: String)
    /// The reply was not what the contract promises (not HTTP, not the state JSON).
    case invalidResponse(String)
    /// The controller accepted the connection but did not answer in time.
    case timeout
}

extension ControllerError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .unreachable(let url, let underlying):
            let target = [url.host(), url.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
            let place = target.isEmpty ? url.absoluteString : target
            return "controller unreachable at \(place): \(underlying)"
        case .httpStatus(let status, let body):
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = HTTPURLResponse.localizedString(forStatusCode: status)
            return text.isEmpty ? "controller replied HTTP \(status) (\(reason))" : "controller replied HTTP \(status) (\(reason)): \(text)"
        case .invalidResponse(let detail):
            return "controller sent an invalid response: \(detail)"
        case .timeout:
            return "controller did not answer in time"
        }
    }

    public var errorDescription: String? { description }
}
