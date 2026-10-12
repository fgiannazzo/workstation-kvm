import ESP32Kit
import Foundation
import Network
import Testing

@Suite("ESP32Discovery")
struct ESP32DiscoveryTests {
    @Test("the service type is the contract's")
    func serviceType() {
        #expect(ESP32Discovery.serviceType == "_switchboard._tcp")
    }

    @Test("URLs: IPv4 loses its interface scope, IPv6 is bracketed with the zone encoded, names pass through")
    func urlFormatting() {
        #expect(ESP32Discovery.url(host: "192.168.1.50", port: 80)?.absoluteString == "http://192.168.1.50:80")
        #expect(ESP32Discovery.url(host: "169.254.7.7%en0", port: 8080)?.absoluteString == "http://169.254.7.7:8080")
        #expect(ESP32Discovery.url(host: "esp32.local", port: 80)?.absoluteString == "http://esp32.local:80")
        #expect(ESP32Discovery.url(host: "fe80::1%en0", port: 80)?.absoluteString == "http://[fe80::1%25en0]:80")
        #expect(ESP32Discovery.url(host: "2001:db8::5", port: 48700)?.absoluteString == "http://[2001:db8::5]:48700")
    }

    @Test("a host:port endpoint resolves without touching the network")
    func resolveHostPort() async {
        let endpoint = NWEndpoint.hostPort(host: "192.168.1.50", port: 8080)
        let started = ContinuousClock.now
        let resolved = await ESP32Discovery.resolve(endpoint, timeout: .seconds(3))
        #expect(resolved?.host == "192.168.1.50")
        #expect(resolved?.port == 8080)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("resolving a service that does not exist gives up at the timeout")
    func resolveMissingService() async {
        let endpoint = NWEndpoint.service(name: "no such controller", type: ESP32Discovery.serviceType, domain: "local", interface: nil)
        let started = ContinuousClock.now
        let resolved = await ESP32Discovery.resolve(endpoint, timeout: .milliseconds(300))
        #expect(resolved == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test("browse honours its timeout whether or not anything is advertised")
    func browseDoesNotHang() async {
        // No assertion on the result: what is on the LAN is not the test's business.
        let started = ContinuousClock.now
        let found = await ESP32Discovery.browse(timeout: .milliseconds(400))
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(4), "browse took \(elapsed)")
        for controller in found {
            #expect(controller.url.port == Int(controller.port))
        }
    }

    @Test("first() also returns within its timeout")
    func firstDoesNotHang() async {
        let started = ContinuousClock.now
        _ = await ESP32Discovery.first(timeout: .milliseconds(400))
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    @Test("browse is cancellable")
    func browseCancellation() async throws {
        let task = Task { await ESP32Discovery.browse(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try await withTimeout(.seconds(3)) { await task.value }
    }
}
