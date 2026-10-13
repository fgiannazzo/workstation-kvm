import Actions
import AppCore
import DDCKit
import Devices
import Foundation
import LocalAPI
import StateStore
import SwitchboardCore
import Testing

/// The app hosts the local API: `AppModel.start()` brings it up on `settings.localAPIPort` with
/// the token from the token store, and `shutdown()` takes it down.
@MainActor
@Suite("Local API inside the app")
struct LocalAPIIntegrationTests {
    private func makeModel(in directory: URL, tokenStore: FileTokenStore) -> AppModel {
        AppModel(
            environment: [:],
            supportDirectory: directory,
            runtimeFactory: { settings, store, notify in
                Runtime(
                    settings: settings, controllerURL: nil,
                    dualUp: LGDualUp(videoCable: FakeDDC(), usbBridge: FakeDDC(supportsRead: false), sleep: instant),
                    controller: nil, appSupport: directory, notify: notify, store: store
                )
            },
            notifier: FakeNotifier(),
            loginItem: FakeLoginItem(),
            tokenStore: tokenStore
        )
    }

    private func waitForAPI(_ model: AppModel) async throws -> URL {
        for _ in 0..<250 {
            if case .running(let url) = model.apiStatus { return url }
            if case .failed(let message) = model.apiStatus { Issue.record("local API failed: \(message)") ; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure("the local API did not start in time: \(model.apiStatus)")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @Test("start() serves /health and /state with the stored token on the configured port; shutdown() stops it")
    func startsAndStops() async throws {
        try await withTempDirectory { directory in
            // Port 0 asks the system for a free port, so the test never collides with a running app.
            try await SettingsStore(directory: directory).save(Settings(localAPIPort: 0))
            let tokenStore = FileTokenStore(url: directory.appendingPathComponent("token"))
            let model = makeModel(in: directory, tokenStore: tokenStore)

            await model.start()
            let url = try await waitForAPI(model)
            #expect(url.host() == "127.0.0.1")
            #expect((url.port ?? 0) != 0)

            let token = try #require(model.apiToken)
            #expect(try tokenStore.load() == token, "the token the server expects is the stored one")
            #expect(token.count == 43)

            let client = LocalAPIClient(baseURL: url, token: token)
            #expect(try await client.health().ok)
            let state = try await client.state()
            #expect(state.pbp == .unknown)

            await #expect(throws: LocalAPIError.self) {
                _ = try await LocalAPIClient(baseURL: url, token: "wrong").state()
            }

            await model.shutdown()
            #expect(model.apiStatus == .stopped)
            await #expect(throws: (any Error).self) {
                _ = try await client.health()
            }
        }
    }

    @Test("saving a new port restarts the server on that port")
    func restartsOnPortChange() async throws {
        try await withTempDirectory { directory in
            try await SettingsStore(directory: directory).save(Settings(localAPIPort: 0))
            let tokenStore = FileTokenStore(url: directory.appendingPathComponent("token"))
            let model = makeModel(in: directory, tokenStore: tokenStore)
            await model.start()
            let first = try await waitForAPI(model)

            // Pick a port the system just handed out and then released, so it is almost surely free.
            let probe = LocalAPIServer(runtime: model.runtime, port: 0, token: "probe")
            try await probe.start()
            let freePort = await probe.port
            await probe.stop()

            var settings = model.settings
            settings.localAPIPort = Int(freePort)
            try await model.saveSettings(settings)
            var second: URL?
            for _ in 0..<250 where second == nil {
                if case .running(let url) = model.apiStatus, url != first { second = url } else { try await Task.sleep(for: .milliseconds(20)) }
            }
            #expect(second?.port == Int(freePort))
            await model.shutdown()
        }
    }
}
