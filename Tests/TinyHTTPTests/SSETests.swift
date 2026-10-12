import Foundation
import Testing
@testable import TinyHTTP

@Suite("Server-sent events")
struct SSETests {
    @Test func streamsEventsToURLSessionClient() async throws {
        let runStarted = "{\"runId\":\"7f3c\",\"status\":\"started\",\n \"step\":0}" // multi-line data
        let runFinished = #"{"runId":"7f3c","status":"finished"}"#
        var router = Router()
        router.get("/events") { _ in
            .eventStream { emitter in
                try? await emitter.send(event: "state", data: #"{"pbp":"on"}"#)
                try? await emitter.send(event: "run", data: runStarted)
                try? await emitter.send(event: "run", data: runFinished)
                try? await emitter.comment("keepalive")
            }
        }

        try await withServer(router) { server, base in
            let session = makeSession()
            let events = try await withTimeout(.seconds(5)) {
                let (bytes, response) = try await session.bytes(from: base.appending(path: "events"))
                let http = try #require(response as? HTTPURLResponse)
                #expect(http.statusCode == 200)
                #expect(http.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
                #expect(http.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
                #expect(http.value(forHTTPHeaderField: "Content-Length") == nil)
                var events: [SSEEvent] = []
                // Ends when the producer returns and the server closes the connection.
                for try await event in SSEParser.events(from: bytes) {
                    events.append(event)
                }
                return events
            }
            #expect(events == [
                SSEEvent(event: "state", data: #"{"pbp":"on"}"#),
                SSEEvent(event: "run", data: runStarted),
                SSEEvent(event: "run", data: runFinished),
            ])
            // The connection task must have wound down on its own.
            try await withTimeout(.seconds(2)) {
                while await server.activeConnectionCount != 0 {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }

    struct Observation: Sendable, Equatable {
        var closed: Bool
        var cancelled: Bool
    }

    @Test func clientDisconnectClosesEmitterAndCancelsProducer() async throws {
        let (observations, observer) = AsyncStream<Observation>.makeStream()
        var router = Router()
        router.get("/events") { _ in
            .eventStream { emitter in
                try? await emitter.send(event: "state", data: "{}")
                var cancelled = false
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    cancelled = Task.isCancelled
                }
                observer.yield(Observation(closed: await emitter.isClosed, cancelled: cancelled))
                observer.finish()
            }
        }

        try await withServer(router) { _, base in
            let session = makeSession()
            let (received, receiver) = AsyncStream<SSEEvent>.makeStream()
            let client = Task {
                let (bytes, _) = try await session.bytes(from: base.appending(path: "events"))
                for try await event in SSEParser.events(from: bytes) {
                    receiver.yield(event)
                }
                receiver.finish()
            }
            let first = try await withTimeout(.seconds(5)) { () async throws -> SSEEvent? in
                for await event in received { return event }
                return nil
            }
            #expect(first == SSEEvent(event: "state", data: "{}"))

            let started = ContinuousClock.now
            client.cancel()
            let observation = try await withTimeout(.seconds(1)) { () async throws -> Observation? in
                for await observation in observations { return observation }
                return nil
            }
            #expect(observation == Observation(closed: true, cancelled: true))
            #expect(ContinuousClock.now - started < .seconds(1))
        }
    }

    @Test func sendAfterCloseThrows() async throws {
        let sink = Sink()
        let emitter = SSEEmitter { data in await sink.append(data) }
        try await emitter.send(event: "state", data: "a\nb", id: "1")
        try await emitter.comment("keepalive")
        await emitter.close()
        #expect(await emitter.isClosed)
        await #expect(throws: SSEEmitterError.self) { try await emitter.send(data: "x") }
        await #expect(throws: SSEEmitterError.self) { try await emitter.comment("x") }
        #expect(await sink.text == "event: state\nid: 1\ndata: a\ndata: b\n\n: keepalive\n\n")
    }

    @Test func writerFailureClosesEmitter() async throws {
        struct Broken: Error {}
        let emitter = SSEEmitter { _ in throw Broken() }
        await #expect(throws: Broken.self) { try await emitter.send(data: "x") }
        #expect(await emitter.isClosed)
    }

    @Test func wireFormat() {
        #expect(SSEEmitter.format(event: "run", data: #"{"a":1}"#) == "event: run\ndata: {\"a\":1}\n\n")
        #expect(SSEEmitter.format(event: nil, data: "x") == "data: x\n\n")
        #expect(SSEEmitter.format(event: "", data: "x") == "data: x\n\n")
        #expect(SSEEmitter.format(event: "e", data: "") == "event: e\ndata: \n\n")
        #expect(SSEEmitter.format(event: "e", data: "l1\r\nl2\rl3\nl4") == "event: e\ndata: l1\ndata: l2\ndata: l3\ndata: l4\n\n")
        #expect(SSEEmitter.format(event: "bad\nname", data: "x", id: "1\r2") == "event: badname\nid: 12\ndata: x\n\n")
        #expect(SSEEmitter.formatComment("keepalive") == ": keepalive\n\n")
        #expect(SSEEmitter.formatComment("a\nb") == ": a\n: b\n\n")
    }
}

private actor Sink {
    private var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
    var text: String { String(decoding: data, as: UTF8.self) }
}
