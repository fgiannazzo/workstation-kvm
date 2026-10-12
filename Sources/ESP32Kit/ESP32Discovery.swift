import Foundation
import Network

/// A controller found on the LAN through mDNS.
public struct DiscoveredController: Sendable, Equatable, Hashable {
    /// The service instance name the controller advertises.
    public let name: String
    /// Numeric address (or host name) the service resolved to.
    public let host: String
    public let port: UInt16
    /// `http://host:port`, ready for `ESP32Client(baseURL:)`.
    public let url: URL

    public init(name: String, host: String, port: UInt16, url: URL) {
        self.name = name
        self.host = host
        self.port = port
        self.url = url
    }
}

/// Finds ESP32 controllers advertising `_switchboard._tcp`.
public enum ESP32Discovery {
    public static let serviceType = "_switchboard._tcp"

    /// Browses for `timeout`, resolves every service found and returns them sorted by name.
    /// Never hangs and never throws: no results (or a browser that cannot start, for example
    /// without the Local Network permission) is an empty array.
    public static func browse(timeout: Duration) async -> [DiscoveredController] {
        await browse(timeout: timeout, stopAfter: nil)
    }

    /// Like `browse(timeout:)` but returns as soon as one controller has resolved.
    public static func first(timeout: Duration) async -> DiscoveredController? {
        await browse(timeout: timeout, stopAfter: 1).first
    }

    static func browse(timeout: Duration, stopAfter limit: Int?) async -> [DiscoveredController] {
        // One stream carries both kinds of news, so a single loop sees everything in order.
        enum Update: Sendable {
            case results(Set<NWBrowser.Result>)
            case resolved(DiscoveredController)
        }

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        let (updates, continuation) = AsyncStream<Update>.makeStream(bufferingPolicy: .unbounded)
        browser.browseResultsChangedHandler = { results, _ in continuation.yield(.results(results)) }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: continuation.finish()
            default: break
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        browser.start(queue: DispatchQueue(label: "ESP32Discovery.browse"))

        var seen: Set<String> = []
        var resolvers: [Task<Void, Never>] = []
        var found: [DiscoveredController] = []

        await withTaskCancellationHandler {
            for await update in updates {
                switch update {
                case .results(let results):
                    for result in results {
                        guard case .service(let name, _, _, _) = result.endpoint, seen.insert(name).inserted else { continue }
                        let endpoint = result.endpoint
                        resolvers.append(Task {
                            guard let address = await resolve(endpoint, timeout: timeout) else { return }
                            let url = Self.url(host: address.host, port: address.port)
                            guard let url else { return }
                            continuation.yield(.resolved(DiscoveredController(name: name, host: address.host, port: address.port, url: url)))
                        })
                    }
                case .resolved(let controller):
                    found.append(controller)
                    if let limit, found.count >= limit { continuation.finish() }
                }
            }
        } onCancel: {
            continuation.finish()
        }

        timer.cancel()
        browser.cancel()
        for resolver in resolvers { resolver.cancel() }
        return found.sorted { $0.name < $1.name }
    }

    /// Turns an endpoint into an address. A `.hostPort` endpoint is returned as is; a `.service`
    /// endpoint is resolved by connecting to it and reading the path's remote endpoint (IPv4
    /// preferred, because the ESP32 speaks IPv4). Returns nil if it cannot be resolved within
    /// `timeout`.
    public static func resolve(_ endpoint: NWEndpoint, timeout: Duration = .seconds(3)) async -> (host: String, port: UInt16)? {
        if case .hostPort(let host, let port) = endpoint {
            return (hostString(host), port.rawValue)
        }

        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "ESP32Discovery.resolve")

        // `.ready` gives the resolved remote endpoint; a timer and cancellation both end the wait.
        let (outcome, continuation) = AsyncStream<(String, UInt16)?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection?.currentPath?.remoteEndpoint {
                    continuation.yield((hostString(host), port.rawValue))
                } else {
                    continuation.yield(nil)
                }
            case .failed, .cancelled:
                continuation.yield(nil)
            default:
                break
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(nil)
        }
        connection.start(queue: queue)

        let result: (String, UInt16)? = await withTaskCancellationHandler {
            for await value in outcome { return value }
            return nil
        } onCancel: {
            continuation.finish()
        }
        timer.cancel()
        connection.cancel()
        continuation.finish()
        guard let result else { return nil }
        return (host: result.0, port: result.1)
    }

    /// `http://host:port` for a resolved address. IPv4 interface scopes (`192.168.1.5%en0`) are
    /// dropped; IPv6 addresses are bracketed with the zone percent-encoded.
    public static func url(host: String, port: UInt16) -> URL? {
        var host = host
        if host.contains(":") {
            host = "[" + host.replacingOccurrences(of: "%", with: "%25") + "]"
        } else if let scope = host.firstIndex(of: "%") {
            host = String(host[..<scope])
        }
        return URL(string: "http://\(host):\(port)")
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            let text = address.debugDescription
            return text.split(separator: "%").first.map(String.init) ?? text
        case .ipv6(let address):
            return address.debugDescription
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}
