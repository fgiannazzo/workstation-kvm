import { describe, expect, it } from "vitest";

import { SseParser, type SseMessage } from "../src/sse.js";

function collect(chunks: (string | Uint8Array)[], end = false): { messages: SseMessage[]; comments: string[] } {
	const messages: SseMessage[] = [];
	const comments: string[] = [];
	const parser = new SseParser({ onMessage: (m) => messages.push(m), onComment: (c) => comments.push(c) });
	for (const chunk of chunks) parser.feed(chunk);
	if (end) parser.end();
	return { messages, comments };
}

const encode = (text: string): Uint8Array => new TextEncoder().encode(text);

describe("SseParser", () => {
	it("parses a named event with JSON data", () => {
		const { messages } = collect(['event: state\ndata: {"pbp":"on"}\n\n']);
		expect(messages).toEqual([{ event: "state", data: '{"pbp":"on"}', lastEventId: "" }]);
	});

	it("defaults the event type to message", () => {
		expect(collect(["data: hello\n\n"]).messages[0]?.event).toBe("message");
	});

	it("joins multi-line data with newlines", () => {
		const { messages } = collect(["event: run\ndata: line one\ndata: line two\ndata:\n\n"]);
		expect(messages[0]?.data).toBe("line one\nline two\n");
	});

	it("handles CRLF line endings", () => {
		const { messages, comments } = collect(["event: state\r\ndata: 1\r\n\r\n: keepalive\r\n\r\nevent: run\r\ndata: 2\r\n\r\n"]);
		expect(messages.map((m) => [m.event, m.data])).toEqual([
			["state", "1"],
			["run", "2"],
		]);
		expect(comments).toEqual([" keepalive"]);
	});

	it("handles CR-only line endings", () => {
		const { messages } = collect(["event: a\rdata: 1\r\r"]);
		expect(messages).toEqual([{ event: "a", data: "1", lastEventId: "" }]);
	});

	it("treats a CRLF split across chunks as one line break", () => {
		const { messages } = collect(["data: x\r", "\n\r", "\n"]);
		expect(messages).toEqual([{ event: "message", data: "x", lastEventId: "" }]);
	});

	it("does not merge a CR at a chunk end with a following non-LF character", () => {
		const { messages } = collect(["data: x\r", "data: y\n\n"]);
		expect(messages[0]?.data).toBe("x\ny");
	});

	it("reassembles an event split across chunks, including inside a multi-byte character", () => {
		const bytes = encode('event: state\ndata: {"snow":"☃ yes"}\n\n');
		const snowman = bytes.indexOf(0xe2); // first byte of U+2603
		const chunks = [bytes.slice(0, 3), bytes.slice(3, snowman + 1), bytes.slice(snowman + 1, snowman + 2), bytes.slice(snowman + 2)];
		const { messages } = collect(chunks);
		expect(messages).toEqual([{ event: "state", data: '{"snow":"☃ yes"}', lastEventId: "" }]);
	});

	it("dispatches each event as soon as its blank line arrives", () => {
		const messages: SseMessage[] = [];
		const parser = new SseParser({ onMessage: (m) => messages.push(m) });
		parser.feed("data: 1\n");
		expect(messages).toHaveLength(0);
		parser.feed("\ndata: 2");
		expect(messages).toHaveLength(1);
		parser.feed("\n\n");
		expect(messages.map((m) => m.data)).toEqual(["1", "2"]);
	});

	it("reports comments without dispatching them", () => {
		const { messages, comments } = collect([": keepalive\n", ":\n", "data: a\n\n"]);
		expect(comments).toEqual([" keepalive", ""]);
		expect(messages).toHaveLength(1);
	});

	it("strips exactly one leading space from a value and accepts a field without a colon", () => {
		const { messages } = collect(["data:no-space\n\n", "data:  two\n\n", "data\n\n"]);
		expect(messages.map((m) => m.data)).toEqual(["no-space", " two", ""]);
	});

	it("ignores unknown fields", () => {
		const { messages } = collect(["foo: bar\ndata: a\n\n"]);
		expect(messages).toEqual([{ event: "message", data: "a", lastEventId: "" }]);
	});

	it("drops an event with no data and resets its type", () => {
		const { messages } = collect(["event: state\n\n", "data: a\n\n"]);
		expect(messages).toEqual([{ event: "message", data: "a", lastEventId: "" }]);
	});

	it("tracks id and retry across events", () => {
		const { messages } = collect(["id: 7\nretry: 2500\ndata: a\n\n", "data: b\n\n", "retry: soon\nid: bad\0id\ndata: c\n\n"]);
		expect(messages).toEqual([
			{ event: "message", data: "a", lastEventId: "7", retry: 2500 },
			{ event: "message", data: "b", lastEventId: "7", retry: 2500 },
			{ event: "message", data: "c", lastEventId: "7", retry: 2500 },
		]);
	});

	it("ignores a leading byte-order mark in bytes and in text", () => {
		expect(collect([encode("﻿data: a\n\n")]).messages[0]?.data).toBe("a");
		expect(collect(["﻿data: a\n\n"]).messages[0]?.data).toBe("a");
	});

	it("discards an unterminated event at the end of the stream", () => {
		const messages: SseMessage[] = [];
		const parser = new SseParser({ onMessage: (m) => messages.push(m) });
		parser.feed("data: partial");
		parser.end();
		parser.feed("\n\n");
		expect(messages).toHaveLength(0);
	});

	it("parses the stream documented in API.md", () => {
		// API.md wraps the run JSON over two lines for readability; on the wire each data line is one
		// complete JSON document (a bare continuation line would be an ignored field name).
		const stream = [
			"event: state\n",
			'data: { "pbp": "on", "usbPort": 2 }\n',
			"\n",
			"event: run\n",
			'data: { "runId": "7f3c", "id": "guest", "kind": "macro", "status": "started", "step": 0, "stepCount": 2, "message": "" }\n',
			"\n",
			": keepalive\n",
			"\n",
		];
		const { messages, comments } = collect(stream);
		expect(messages.map((m) => m.event)).toEqual(["state", "run"]);
		expect(JSON.parse(messages[1]?.data ?? "")).toMatchObject({ runId: "7f3c", status: "started", stepCount: 2 });
		expect(comments).toEqual([" keepalive"]);
	});
});
