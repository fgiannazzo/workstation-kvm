import Actions
import Foundation
import SwitchboardCore

/// `GET /health`: `{ "ok": true, "name": "Switchboard", "version": "0.1.0" }`.
public struct HealthResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var name: String
    public var version: String

    public init(ok: Bool = true, name: String = "Switchboard", version: String = SwitchboardVersion.current) {
        self.ok = ok
        self.name = name
        self.version = version
    }
}

/// The body of every error response: `{ "error": "busy", "runId": "…" }`. `error` is the code
/// clients switch on; the other keys appear where the contract names them.
public struct APIErrorBody: Codable, Sendable, Equatable {
    public var error: String
    /// `unknown id`: the id that was asked for.
    public var id: String?
    /// `missing parameter`, `invalid parameter`: the parameter's name.
    public var parameter: String?
    /// `invalid parameter`: what is wrong with it.
    public var reason: String?
    /// `busy`: the run that is in progress.
    public var runId: String?

    public init(error: String, id: String? = nil, parameter: String? = nil, reason: String? = nil, runId: String? = nil) {
        self.error = error
        self.id = id
        self.parameter = parameter
        self.reason = reason
        self.runId = runId
    }
}

/// One event of `GET /events` as a client sees it: the `state` event's `SwitchboardState`, or the
/// `run` event's `RunEvent`.
public enum APIEvent: Sendable, Equatable {
    case state(SwitchboardState)
    case run(RunEvent)
}

/// Why a call to the local API did not give an answer.
public enum LocalAPIError: Error, Sendable, Equatable {
    /// Nothing answered at the address: the app is not running, wrong port, or the connection
    /// dropped or timed out.
    case unreachable(URL, underlying: String)
    /// `401`: the token is missing or wrong.
    case unauthorized
    /// Any other non-2xx status. `body` is the response text, normally `{"error":"…"}`; see
    /// `errorBody`.
    case status(Int, body: String)
    /// The server answered with something that is not the contract.
    case invalidResponse(String)

    /// The decoded `{"error": …}` of a `.status` error.
    public var errorBody: APIErrorBody? {
        guard case .status(_, let body) = self else { return nil }
        return try? JSONDecoder().decode(APIErrorBody.self, from: Data(body.utf8))
    }

    /// The server is not there, as opposed to there and unhappy.
    public var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }
}

extension LocalAPIError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .unreachable(let url, let underlying):
            let place = [url.host(), url.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
            return "cannot reach the Switchboard API at \(place.isEmpty ? url.absoluteString : place): \(underlying)"
        case .unauthorized:
            return "the Switchboard API rejected the token (401 unauthorized)"
        case .status(let code, let body):
            if let detail = errorBody {
                var text = "HTTP \(code): \(detail.error)"
                if let parameter = detail.parameter { text += " \"\(parameter)\"" }
                if let id = detail.id { text += " \"\(id)\"" }
                if let reason = detail.reason { text += ": \(reason)" }
                if let runId = detail.runId { text += " (run \(runId))" }
                return text
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(trimmed)"
        case .invalidResponse(let detail):
            return "the Switchboard API sent an invalid response: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}
