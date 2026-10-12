/**
 * Incremental parser for `text/event-stream`, following the WHATWG HTML "Server-sent events"
 * stream interpretation rules. Feed it bytes or text as they arrive; it dispatches one message per
 * blank line and keeps partial lines (and a trailing CR) between calls, so events may be split
 * anywhere, including in the middle of a multi-byte UTF-8 sequence.
 */

export interface SseMessage {
	/** Event type; `"message"` when the stream did not name one. */
	event: string;
	/** Data lines joined with `"\n"`. */
	data: string;
	/** Last `id` field seen on the stream, `""` until one arrives. */
	lastEventId: string;
	/** Last valid `retry` field seen on the stream, in milliseconds. */
	retry?: number;
}

export interface SseParserHandlers {
	onMessage(message: SseMessage): void;
	/** Comment lines (`: keepalive`) without the leading colon. */
	onComment?(comment: string): void;
}

export class SseParser {
	readonly #handlers: SseParserHandlers;
	readonly #decoder = new TextDecoder("utf-8");
	/** Text received but not yet terminated by a line break. */
	#partial = "";
	/** The previous chunk ended with CR; a LF at the start of the next chunk belongs to it. */
	#pendingCr = false;
	#first = true;
	#eventType = "";
	#data: string[] = [];
	#lastEventId = "";
	#retry: number | undefined;

	constructor(handlers: SseParserHandlers) {
		this.#handlers = handlers;
	}

	/** Feeds the next chunk of the stream. */
	feed(chunk: Uint8Array | string): void {
		let text = typeof chunk === "string" ? chunk : this.#decoder.decode(chunk, { stream: true });
		if (this.#first) {
			this.#first = false;
			// TextDecoder strips a byte-order mark on its own; a string input needs the same treatment.
			if (text.startsWith("﻿")) text = text.slice(1);
		}
		if (this.#pendingCr) {
			this.#pendingCr = false;
			if (text.startsWith("\n")) text = text.slice(1);
		}

		let buffer = this.#partial + text;
		let start = 0;
		for (let i = 0; i < buffer.length; i++) {
			const code = buffer.charCodeAt(i);
			if (code !== 10 && code !== 13) continue;
			this.#line(buffer.slice(start, i));
			if (code === 13) {
				if (i + 1 < buffer.length) {
					if (buffer.charCodeAt(i + 1) === 10) i++;
				} else {
					this.#pendingCr = true;
				}
			}
			start = i + 1;
		}
		this.#partial = start === 0 ? buffer : buffer.slice(start);
		buffer = "";
	}

	/**
	 * Signals the end of the stream. Per the specification an event that was not terminated by a
	 * blank line is discarded.
	 */
	end(): void {
		this.#decoder.decode();
		this.#partial = "";
		this.#pendingCr = false;
		this.#eventType = "";
		this.#data = [];
	}

	#line(line: string): void {
		if (line === "") {
			this.#dispatch();
			return;
		}
		if (line.startsWith(":")) {
			this.#handlers.onComment?.(line.slice(1));
			return;
		}
		const colon = line.indexOf(":");
		let field: string;
		let value: string;
		if (colon === -1) {
			field = line;
			value = "";
		} else {
			field = line.slice(0, colon);
			value = line.slice(colon + 1);
			if (value.startsWith(" ")) value = value.slice(1);
		}
		switch (field) {
			case "event":
				this.#eventType = value;
				break;
			case "data":
				this.#data.push(value);
				break;
			case "id":
				if (!value.includes("\0")) this.#lastEventId = value;
				break;
			case "retry":
				if (/^\d+$/.test(value)) this.#retry = Number(value);
				break;
			default:
				// Unknown fields are ignored.
				break;
		}
	}

	#dispatch(): void {
		if (this.#data.length === 0) {
			this.#eventType = "";
			return;
		}
		const message: SseMessage = {
			event: this.#eventType === "" ? "message" : this.#eventType,
			data: this.#data.join("\n"),
			lastEventId: this.#lastEventId,
		};
		if (this.#retry !== undefined) message.retry = this.#retry;
		this.#data = [];
		this.#eventType = "";
		this.#handlers.onMessage(message);
	}
}
