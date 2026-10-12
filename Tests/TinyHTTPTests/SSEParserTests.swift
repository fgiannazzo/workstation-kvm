import Foundation
import Testing
@testable import TinyHTTP

@Suite("SSEParser")
struct SSEParserTests {
    private func parse(_ chunks: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        return chunks.flatMap { parser.feed(Data($0.utf8)) }
    }

    @Test func singleEvent() {
        #expect(parse(["event: state\ndata: {\"pbp\":\"on\"}\n\n"]) == [SSEEvent(event: "state", data: #"{"pbp":"on"}"#)])
    }

    @Test func unnamedEventHasNilType() {
        #expect(parse(["data: hello\n\n"]) == [SSEEvent(event: nil, data: "hello")])
    }

    @Test func splitInTheMiddleOfFieldNameAndValue() {
        #expect(parse(["da", "ta: hel", "lo\n", "\n"]) == [SSEEvent(data: "hello")])
        #expect(parse(["event: ru", "n\nda", "ta: x\n\nev", "ent: run\ndata: y\n\n"]) == [
            SSEEvent(event: "run", data: "x"),
            SSEEvent(event: "run", data: "y"),
        ])
    }

    @Test func splitBetweenCRAndLF() {
        #expect(parse(["data: a\r", "\n\r", "\n"]) == [SSEEvent(data: "a")])
        #expect(parse(["data: a\r", "\r\ndata: b\r\n\r\n"]) == [SSEEvent(data: "a"), SSEEvent(data: "b")])
    }

    @Test func allLineEndingStyles() {
        #expect(parse(["data: a\r\n\r\n"]) == [SSEEvent(data: "a")])
        #expect(parse(["data: a\r\r"]) == [SSEEvent(data: "a")])
        #expect(parse(["data: a\n\n"]) == [SSEEvent(data: "a")])
        #expect(parse(["data: a\r\ndata: b\n\n"]) == [SSEEvent(data: "a\nb")])
    }

    @Test func multiLineData() {
        #expect(parse(["event: run\ndata: {\ndata:   \"a\": 1\ndata: }\n\n"]) == [SSEEvent(event: "run", data: "{\n  \"a\": 1\n}")])
        // `data:` with an empty value contributes an empty line.
        #expect(parse(["data:\ndata: x\ndata\n\n"]) == [SSEEvent(data: "\nx\n")])
    }

    @Test func commentsAreIgnored() {
        #expect(parse([": keepalive\n\n"]) == [])
        #expect(parse([":\n", ": keepalive\n", "data: x\n", ": mid-event comment\n", "event: e\n\n", ": trailing\n\n"]) == [SSEEvent(event: "e", data: "x")])
    }

    @Test func utf8BOMIsStripped() {
        var parser = SSEParser()
        var events = parser.feed(Data([0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)))
        #expect(events == [SSEEvent(data: "x")])

        // BOM split across chunks.
        parser = SSEParser()
        events = parser.feed(Data([0xEF]))
        #expect(events.isEmpty)
        events += parser.feed(Data([0xBB, 0xBF] + Array("data: y\n\n".utf8)))
        #expect(events == [SSEEvent(data: "y")])

        // Only the very first bytes count as a BOM. A later one becomes part of
        // the field name ("\u{FEFF}data"), which is unknown and therefore ignored.
        parser = SSEParser()
        events = parser.feed(Data(Array("data: a\n\n".utf8) + [0xEF, 0xBB, 0xBF] + Array("data: b\n\n".utf8)))
        #expect(events == [SSEEvent(data: "a")])
    }

    @Test func eventWithoutDataIsDropped() {
        #expect(parse(["event: nothing\n\n", "id: 1\n\n", "data: x\n\n"]) == [SSEEvent(data: "x", id: "1")])
    }

    @Test func idIsStickyAndNullIsRejected() {
        #expect(parse(["id: 1\ndata: a\n\n", "data: b\n\n", "id: bad\u{0}\ndata: c\n\n", "id\ndata: d\n\n"]) == [
            SSEEvent(data: "a", id: "1"),
            SSEEvent(data: "b", id: "1"),
            SSEEvent(data: "c", id: "1"),
            SSEEvent(data: "d", id: ""),
        ])
    }

    @Test func retryAndUnknownFields() {
        var parser = SSEParser()
        let events = parser.feed(Data("retry: 2500\nretry: soon\nfoo: bar\ndata: x\n\n".utf8))
        #expect(events == [SSEEvent(data: "x")])
        #expect(parser.retry == 2500)
    }

    @Test func valueWithoutLeadingSpaceAndEmbeddedColons() {
        #expect(parse(["data:x\n\n"]) == [SSEEvent(data: "x")])
        #expect(parse(["data:  two spaces\n\n"]) == [SSEEvent(data: " two spaces")])
        #expect(parse(["data: a:b:c\n\n"]) == [SSEEvent(data: "a:b:c")])
    }

    @Test func incompleteTrailingEventIsNotEmitted() {
        #expect(parse(["data: a\n\ndata: b\n"]) == [SSEEvent(data: "a")])
    }

    @Test func asyncSequenceAdapter() async throws {
        let (bytes, continuation) = AsyncStream<UInt8>.makeStream()
        let wire = "event: state\ndata: 1\n\n: keepalive\n\nevent: run\ndata: {\ndata: }\n\n"
        for byte in wire.utf8 { continuation.yield(byte) }
        continuation.finish()

        var events: [SSEEvent] = []
        for try await event in SSEParser.events(from: bytes) {
            events.append(event)
        }
        #expect(events == [SSEEvent(event: "state", data: "1"), SSEEvent(event: "run", data: "{\n}")])
    }
}
