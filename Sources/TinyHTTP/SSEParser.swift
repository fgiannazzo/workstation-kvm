import Foundation

/// One server-sent event as seen by a client.
///
/// `event` is nil for unnamed events (the spec's default type `message`).
/// `id` is the last event ID seen on the stream, which per the spec persists
/// across events until the server sends a new `id:` line.
public struct SSEEvent: Sendable, Hashable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental, allocation-light parser for `text/event-stream`.
///
/// Feed it byte chunks as they arrive; it returns the events completed by
/// each chunk. Handles events split anywhere between chunks, `\n`, `\r\n` and
/// `\r` line endings (including a `\r` and its `\n` arriving separately),
/// multi-line `data:`, comments, `id:`/`retry:` and the UTF-8 BOM. Follows the
/// WHATWG EventSource processing model.
public struct SSEParser: Sendable {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    private var buffer: [UInt8] = []
    private var checkedBOM = false
    private var skipNextLF = false
    private var dataLines: [String] = []
    private var hasData = false
    private var eventType = ""
    private var lastEventID: String?

    /// The most recent `retry:` value, in milliseconds, if the server sent one.
    public private(set) var retry: Int?

    public init() {}

    public mutating func feed(_ data: Data) -> [SSEEvent] {
        feed(bytes: data)
    }

    public mutating func feed<Bytes: Sequence>(bytes: Bytes) -> [SSEEvent] where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)

        if !checkedBOM {
            if buffer.count < SSEParser.bom.count {
                // Could still be the start of a BOM: wait for more bytes.
                if buffer.elementsEqual(SSEParser.bom.prefix(buffer.count)) { return [] }
                checkedBOM = true
            } else {
                if buffer.starts(with: SSEParser.bom) { buffer.removeFirst(SSEParser.bom.count) }
                checkedBOM = true
            }
        }

        var events: [SSEEvent] = []
        var lineStart = 0
        var index = 0
        while index < buffer.count {
            let byte = buffer[index]
            if skipNextLF {
                skipNextLF = false
                if byte == 0x0A {
                    index += 1
                    lineStart = index
                    continue
                }
            }
            if byte == 0x0A || byte == 0x0D {
                processLine(buffer[lineStart..<index], into: &events)
                if byte == 0x0D { skipNextLF = true }
                index += 1
                lineStart = index
            } else {
                index += 1
            }
        }
        buffer.removeFirst(lineStart)
        return events
    }

    private mutating func processLine(_ line: ArraySlice<UInt8>, into events: inout [SSEEvent]) {
        if line.isEmpty {
            dispatch(into: &events)
            return
        }
        if line.first == 0x3A { return } // comment

        let name: String
        let value: String
        if let colon = line.firstIndex(of: 0x3A) {
            name = String(decoding: line[line.startIndex..<colon], as: UTF8.self)
            var valueStart = colon + 1
            if valueStart < line.endIndex, line[valueStart] == 0x20 { valueStart += 1 }
            value = String(decoding: line[valueStart..<line.endIndex], as: UTF8.self)
        } else {
            name = String(decoding: line, as: UTF8.self)
            value = ""
        }

        switch name {
        case "event":
            eventType = value
        case "data":
            dataLines.append(value)
            hasData = true
        case "id":
            if !value.contains("\0") { lastEventID = value }
        case "retry":
            if !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let ms = Int(value) { retry = ms }
        default:
            break
        }
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            hasData = false
            eventType = ""
        }
        guard hasData else { return }
        events.append(SSEEvent(
            event: eventType.isEmpty ? nil : eventType,
            data: dataLines.joined(separator: "\n"),
            id: lastEventID
        ))
    }
}

// MARK: - Async sequence adapter

extension SSEParser {
    /// Parses events out of a byte sequence such as `URLSession.AsyncBytes`.
    ///
    /// ```swift
    /// let (bytes, _) = try await URLSession.shared.bytes(from: url)
    /// for try await event in SSEParser.events(from: bytes) { ... }
    /// ```
    /// The sequence ends when the byte sequence ends; cancellation propagates
    /// to the underlying sequence.
    public static func events<Bytes: AsyncSequence>(from bytes: Bytes) -> SSEEventSequence<Bytes> where Bytes.Element == UInt8 {
        SSEEventSequence(base: bytes)
    }
}

/// `AsyncSequence` of ``SSEEvent`` over an `AsyncSequence` of bytes. See ``SSEParser/events(from:)``.
public struct SSEEventSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = SSEEvent

    private let base: Base

    init(base: Base) {
        self.base = base
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var base: Base.AsyncIterator
        private var parser = SSEParser()
        private var pending: [SSEEvent] = []
        private var nextIndex = 0
        private var finished = false

        init(base: Base.AsyncIterator) {
            self.base = base
        }

        public mutating func next() async throws -> SSEEvent? {
            while true {
                if nextIndex < pending.count {
                    let event = pending[nextIndex]
                    nextIndex += 1
                    return event
                }
                pending.removeAll(keepingCapacity: true)
                nextIndex = 0
                if finished { return nil }

                // Pull bytes up to the next line end (or a bounded chunk) and feed them in one go.
                var chunk: [UInt8] = []
                while true {
                    guard let byte = try await base.next() else {
                        finished = true
                        break
                    }
                    chunk.append(byte)
                    if byte == 0x0A || chunk.count >= 4096 { break }
                }
                if !chunk.isEmpty {
                    pending = parser.feed(bytes: chunk)
                }
            }
        }
    }
}

extension SSEEventSequence: Sendable where Base: Sendable {}
