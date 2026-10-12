/**
 * A loopback HTTP server that answers exactly like `docs/API.md` describes, so the plugin's client
 * can be tested offline. Shapes are copied from the document's examples verbatim.
 */
import { once } from "node:events";
import { createServer, type IncomingHttpHeaders, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";

import type { ActionDescriptor, Health, Macro, SwitchboardState } from "../src/types.js";

/** A plausible 32-byte base64url token, as the app would generate. */
export const TOKEN = "Qm9vdHN0cmFwcGluZy1zd2l0Y2hib2FyZC10b2tlbjEyMw";

export const HEALTH: Health = { ok: true, name: "Switchboard", version: "0.1.0" };

export const STATE: SwitchboardState = {
	pbp: "on",
	mainInput: "hdmi1",
	usbPort: 2,
	hdmiInput: { dualup: 1, lg4k: 2, samsung: 1 },
	controllerReachable: true,
	dualUpReachable: true,
	lastError: null,
	updatedAt: "2026-10-11T20:15:03.120Z",
};

export const ACTIONS: ActionDescriptor[] = [
	{ id: "monitor.pbp.on", title: "PBP on", parameters: [] },
	{ id: "monitor.pbp.off", title: "PBP off", parameters: [] },
	{ id: "monitor.read", title: "Read monitor", parameters: [] },
	{
		id: "hdmi.select",
		title: "HDMI input",
		parameters: [
			{ name: "display", type: "enum", values: ["dualup", "lg4k", "samsung"] },
			{ name: "input", type: "int", min: 1, max: 2 },
		],
	},
	{
		id: "hdmi.resync",
		title: "HDMI resync (set assumed input)",
		parameters: [
			{ name: "display", type: "enum", values: ["dualup", "lg4k", "samsung"] },
			{ name: "input", type: "int", min: 1, max: 2 },
		],
	},
	{ id: "usb.select", title: "USB to port", parameters: [{ name: "port", type: "int", min: 1, max: 4 }] },
	{ id: "delay", title: "Wait", parameters: [{ name: "ms", type: "int", min: 0, max: 60000 }] },
	{ id: "notify", title: "Notification", parameters: [{ name: "text", type: "string" }] },
];

export const MACROS: Macro[] = [
	{
		id: "guest",
		name: "Guest",
		steps: [{ action: "monitor.pbp.on" }, { action: "usb.select", port: 2 }],
		verify: { pbp: "on", usbPort: 2 },
	},
	{
		id: "solo",
		name: "Solo",
		steps: [{ action: "usb.select", port: 1 }, { action: "monitor.pbp.off" }],
		verify: { pbp: "off", usbPort: 1 },
	},
];

export interface RecordedRequest {
	method: string;
	url: string;
	headers: IncomingHttpHeaders;
	body: string;
}

export interface MockEventsOptions {
	/** End the stream this many ms after the scripted events. Default: keep it open. */
	closeAfterMs?: number;
	/** Send nothing at all, to exercise the client's idle timeout. */
	silent?: boolean;
	/** Terminate lines with CRLF instead of LF. */
	crlf?: boolean;
}

export interface MockServerOptions {
	/** Token the server accepts. Default {@link TOKEN}. */
	token?: string;
	/** Answer every `POST /run/{id}` with `409 busy`. */
	busy?: boolean;
	events?: MockEventsOptions;
}

export interface MockServer {
	readonly host: string;
	readonly port: number;
	readonly baseUrl: string;
	/** Every request received, in order. */
	readonly requests: RecordedRequest[];
	/** `/events` connections accepted so far. */
	readonly eventConnections: number;
	/** `/events` responses still open. */
	readonly openEventStreams: number;
	/** Writes an event to every open `/events` stream. */
	pushEvent(event: string, data: unknown): void;
	close(): Promise<void>;
}

export async function startMockServer(options: MockServerOptions = {}): Promise<MockServer> {
	const token = options.token ?? TOKEN;
	const requests: RecordedRequest[] = [];
	const streams = new Set<ServerResponse>();
	const nl = options.events?.crlf ? "\r\n" : "\n";
	let eventConnections = 0;
	let runCounter = 0;

	const formatEvent = (event: string, data: unknown): string => `event: ${event}${nl}data: ${JSON.stringify(data)}${nl}${nl}`;

	const server = createServer(async (req, res) => {
		const body = await readBody(req);
		requests.push({ method: req.method ?? "", url: req.url ?? "", headers: req.headers, body });
		const path = new URL(req.url ?? "/", "http://localhost").pathname;

		if (req.method === "GET" && path === "/health") return json(res, 200, HEALTH);
		if (req.headers.authorization !== `Bearer ${token}`) return json(res, 401, { error: "unauthorized" });

		if (req.method === "GET" && path === "/state") return json(res, 200, STATE);
		if (req.method === "GET" && path === "/actions") return json(res, 200, { actions: ACTIONS });
		if (req.method === "GET" && path === "/macros") return json(res, 200, { macros: MACROS });

		if (req.method === "POST" && path.startsWith("/run/")) {
			const id = decodeURIComponent(path.slice("/run/".length));
			if (options.busy) return json(res, 409, { error: "busy", runId: "busy-0001" });
			if (MACROS.some((macro) => macro.id === id)) {
				return json(res, 202, { runId: `run-${++runCounter}`, id, kind: "macro" });
			}
			const action = ACTIONS.find((candidate) => candidate.id === id);
			if (!action) return json(res, 404, { error: "unknown id", id });
			let parameters: Record<string, unknown> = {};
			if (body !== "") {
				try {
					parameters = JSON.parse(body) as Record<string, unknown>;
				} catch {
					return json(res, 400, { error: "invalid body" });
				}
			}
			for (const parameter of action.parameters) {
				if (!(parameter.name in parameters)) return json(res, 400, { error: "missing parameter", parameter: parameter.name });
			}
			return json(res, 202, { runId: `run-${++runCounter}`, id, kind: "action" });
		}

		if (req.method === "GET" && path === "/events") {
			eventConnections += 1;
			res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
			res.flushHeaders();
			streams.add(res);
			res.on("close", () => streams.delete(res));
			if (!options.events?.silent) {
				const runId = `run-events-${eventConnections}`;
				const run = { runId, id: "guest", kind: "macro" };
				res.write(formatEvent("state", STATE));
				res.write(formatEvent("run", { ...run, status: "started", step: 0, stepCount: 2, message: "" }));
				res.write(formatEvent("run", { ...run, status: "step", step: 1, stepCount: 2, message: "monitor.pbp.on: verified 0xD7 = 0" }));
				res.write(formatEvent("run", { ...run, status: "finished", step: 2, stepCount: 2, message: "ok" }));
				res.write(`: keepalive${nl}${nl}`);
			}
			if (options.events?.closeAfterMs !== undefined) {
				setTimeout(() => res.end(), options.events.closeAfterMs);
			}
			return;
		}

		return json(res, 404, { error: "not found" });
	});

	server.listen(0, "127.0.0.1");
	await once(server, "listening");
	const { port } = server.address() as AddressInfo;

	return {
		host: "127.0.0.1",
		port,
		baseUrl: `http://127.0.0.1:${port}`,
		requests,
		get eventConnections() {
			return eventConnections;
		},
		get openEventStreams() {
			return streams.size;
		},
		pushEvent(event, data) {
			for (const res of streams) res.write(formatEvent(event, data));
		},
		async close() {
			for (const res of streams) res.destroy();
			server.closeAllConnections();
			await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
		},
	};
}

function json(res: ServerResponse, status: number, body: unknown): void {
	res.writeHead(status, { "Content-Type": "application/json" });
	res.end(JSON.stringify(body));
}

async function readBody(req: IncomingMessage): Promise<string> {
	const chunks: Buffer[] = [];
	for await (const chunk of req) chunks.push(chunk as Buffer);
	return Buffer.concat(chunks).toString("utf8");
}
