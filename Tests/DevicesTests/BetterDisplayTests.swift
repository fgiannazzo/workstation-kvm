import Devices
import Foundation
import os
import SwitchboardCore
import Testing

/// `get -identifiers` as BetterDisplay 5.1.1 printed it on the development Mac (2026-10-12): one
/// object per device separated by commas, no enclosing brackets, every value a string.
let betterDisplayIdentifiers = """
{
  "UUID" : "F64CFAAA-C233-499A-B9FA-06597C25490B",
  "alphanumericSerial" : "302NTCZ1U003",
  "deviceType" : "Display",
  "displayID" : "2",
  "model" : "30543",
  "name" : "LG HDR 4K",
  "originalName" : "LG HDR 4K",
  "productName" : "LG HDR 4K",
  "registryLocation" : "IOService:\\/AppleARMPE\\/arm-io@10F00000\\/AppleSoCIO\\/dispext0@B0000000\\/IOMobileFramebufferShim",
  "serial" : "62003",
  "tagID" : "8",
  "vendor" : "7789",
  "weekOfManufacture" : "2",
  "yearOfManufacture" : "2023"
},{
  "UUID" : "974D402F-6AB5-4BB4-8F57-E9B330173254",
  "alphanumericSerial" : "H1AK500000",
  "deviceType" : "Display",
  "displayID" : "1",
  "model" : "57393",
  "name" : "Odyssey G80SD",
  "originalName" : "Odyssey G80SD",
  "productName" : "Odyssey G80SD",
  "registryLocation" : "IOService:\\/AppleARMPE\\/arm-io@10F00000\\/AppleSoCIO\\/dispext1@90000000\\/IOMobileFramebufferShim",
  "serial" : "16780800",
  "tagID" : "9",
  "vendor" : "19501"
},{
  "UUID" : "FF5845D6-158D-426D-89C2-75705FB2774E",
  "alphanumericSerial" : "301NTQDF4860",
  "deviceType" : "Display",
  "displayID" : "3",
  "name" : "LG SDQHD",
  "originalName" : "LG SDQHD",
  "productName" : "LG SDQHD",
  "registryLocation" : "IOService:\\/AppleARMPE\\/arm-io@10F00000\\/AppleSoCIO\\/dispext2@0\\/IOMobileFramebufferShim",
  "serial" : "514860",
  "tagID" : "14",
  "vendor" : "7789"
},{
  "deviceType" : "DisplayGroup",
  "name" : "Default Group",
  "tagID" : "-1001"
}
"""

/// Records every command and answers from a script, so no test starts BetterDisplay.
final class ScriptedRunner: Sendable {
    private let state: OSAllocatedUnfairLock<(calls: [[String]], answers: [String: CommandOutput])>

    init(_ answers: [String: CommandOutput] = [:]) {
        state = OSAllocatedUnfairLock(initialState: (calls: [], answers: answers))
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    var run: CommandRunner {
        { [self] executable, arguments, _ in
            #expect(executable == URL(filePath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"))
            return state.withLock { state in
                state.calls.append(arguments)
                return state.answers[arguments.joined(separator: " ")] ?? CommandOutput(status: 0, stdout: "")
            }
        }
    }
}

@Suite("BetterDisplay")
struct BetterDisplayTests {
    private let dualUp = ManagedDisplay(name: "LG SDQHD", uuid: "FF5845D6-158D-426D-89C2-75705FB2774E", serial: "301NTQDF4860")

    @Test("get -identifiers yields the hardware-backed displays, without groups, virtual screens or a remote session's display")
    func parsesIdentifiers() throws {
        let displays = try #require(BetterDisplay.parseIdentifiers(betterDisplayIdentifiers))
        #expect(displays == [
            ManagedDisplay(name: "LG HDR 4K", uuid: "F64CFAAA-C233-499A-B9FA-06597C25490B", serial: "302NTCZ1U003"),
            ManagedDisplay(name: "Odyssey G80SD", uuid: "974D402F-6AB5-4BB4-8F57-E9B330173254", serial: "H1AK500000"),
            dualUp,
        ])
        let shim = #"IOService:\/AppleARMPE\/arm-io@10F00000\/AppleSoCIO\/dispext0@0\/IOMobileFramebufferShim"#
        let virtual = """
        [{"UUID":"AAAA","deviceType":"VirtualScreen","name":"BetterDisplay virtual"},
         {"UUID":"CCCC","deviceType":"Display","name":"Jump Desktop"},
         {"UUID":"DDDD","deviceType":"Display","name":"Odd","registryLocation":"IOService:\\/somewhere"},
         {"UUID":"BBBB","deviceType":"Display","name":"Plain","registryLocation":"\(shim)"}]
        """
        #expect(BetterDisplay.parseIdentifiers(virtual) == [ManagedDisplay(name: "Plain", uuid: "BBBB")])
        #expect(BetterDisplay.parseIdentifiers("  \n") == [])
        #expect(BetterDisplay.parseIdentifiers("Failed.") == nil)
    }

    @Test("every command goes to the app binary as an argument list addressed by UUID")
    func commandLines() async throws {
        let uuid = dualUp.uuid
        let runner = ScriptedRunner([
            "get -identifiers": CommandOutput(status: 0, stdout: betterDisplayIdentifiers),
            "get -UUID=\(uuid) -connected": CommandOutput(status: 0, stdout: "on\n"),
        ])
        let betterDisplay = BetterDisplay(run: runner.run)
        #expect(try await betterDisplay.displays().count == 3)
        #expect(try await betterDisplay.isConnected(dualUp) == true)
        try await betterDisplay.setConnected(dualUp, false)
        try await betterDisplay.setConnected(dualUp, true)
        try await betterDisplay.connectAll()
        #expect(runner.calls == [
            ["get", "-identifiers"],
            ["get", "-UUID=\(uuid)", "-connected"],
            ["set", "-UUID=\(uuid)", "-connected=off"],
            ["set", "-UUID=\(uuid)", "-connected=on"],
            ["perform", "-connectAllDisplays"],
        ])
    }

    @Test("connected reads on and off; Failed. means the display is not known")
    func readsConnected() async throws {
        let uuid = dualUp.uuid
        let off = BetterDisplay(run: ScriptedRunner(["get -UUID=\(uuid) -connected": CommandOutput(status: 0, stdout: "off")]).run)
        #expect(try await off.isConnected(dualUp) == false)
        let unknown = BetterDisplay(run: ScriptedRunner(["get -UUID=\(uuid) -connected": CommandOutput(status: 1, stdout: "Failed.\n")]).run)
        #expect(try await unknown.isConnected(dualUp) == nil)
        let odd = BetterDisplay(run: ScriptedRunner(["get -UUID=\(uuid) -connected": CommandOutput(status: 0, stdout: "maybe")]).run)
        await #expect(throws: DisplayConnectorError.invalidOutput(command: "get -UUID=\(uuid) -connected", output: "maybe")) {
            try await odd.isConnected(dualUp)
        }
    }

    @Test("a refused or slow command is an error that says so")
    func failures() async throws {
        let uuid = dualUp.uuid
        let refused = BetterDisplay(run: ScriptedRunner(["set -UUID=\(uuid) -connected=off": CommandOutput(status: 1, stdout: "Failed.\n")]).run)
        await #expect(throws: DisplayConnectorError.failed(command: "set -UUID=\(uuid) -connected=off", status: 1, output: "Failed.\n")) {
            try await refused.setConnected(dualUp, false)
        }
        #expect(DisplayConnectorError.failed(command: "set -x", status: 1, output: "Failed.\n").description == "BetterDisplay set -x failed (exit 1: Failed.)")

        let slow = BetterDisplay(run: ScriptedRunner(["get -identifiers": CommandOutput(status: 15, stdout: "", timedOut: true)]).run)
        await #expect(throws: DisplayConnectorError.timedOut(command: "get -identifiers")) { try await slow.displays() }

        let garbled = BetterDisplay(run: ScriptedRunner(["get -identifiers": CommandOutput(status: 0, stdout: "{nope")]).run)
        await #expect(throws: DisplayConnectorError.invalidOutput(command: "get -identifiers", output: "{nope")) { try await garbled.displays() }
    }

    @Test("installed(at:) is nil when the binary is not there")
    func notInstalled() {
        #expect(BetterDisplay.installed(at: URL(filePath: "/nonexistent/BetterDisplay.app/Contents/MacOS/BetterDisplay")) == nil)
    }

    @Test("a display matches its name, serial or UUID, ignoring case and spaces")
    func matching() {
        #expect(dualUp.matches("LG SDQHD"))
        #expect(dualUp.matches(" lg sdqhd "))
        #expect(dualUp.matches("301ntqdf4860"))
        #expect(dualUp.matches("ff5845d6-158d-426d-89c2-75705fb2774e"))
        #expect(!dualUp.matches("SDQHD"))
        #expect(!dualUp.matches(""))
    }
}

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("runs a tool directly and returns its output and exit status")
    func output() async throws {
        let echo = try await ProcessRunner.run(URL(filePath: "/bin/echo"), ["a b", "$HOME"], .seconds(10))
        #expect(echo == CommandOutput(status: 0, stdout: "a b $HOME\n"))
        let failing = try await ProcessRunner.run(URL(filePath: "/bin/sh"), ["-c", "echo oops >&2; exit 3"], .seconds(10))
        #expect(failing.status == 3)
        #expect(failing.stderr == "oops\n")
        #expect(!failing.timedOut)
    }

    @Test("kills a tool that runs past its timeout")
    func timeout() async throws {
        let started = ContinuousClock.now
        let result = try await ProcessRunner.run(URL(filePath: "/bin/sleep"), ["10"], .milliseconds(200))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("a missing executable throws")
    func missing() async {
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run(URL(filePath: "/nonexistent/tool"), [], .seconds(1))
        }
    }
}
