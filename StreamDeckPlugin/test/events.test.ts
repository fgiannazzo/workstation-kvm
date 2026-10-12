import { describe, expect, it } from "vitest";

import { ApiClient, ApiError, ConnectionError, DEFAULT_BACKOFF, nextBackoff, type BackoffPolicy } from "../src/api.js";
import type { RunEvent, SwitchboardState } from "../src/types.js";
import { delay, waitFor } from "./helpers.js";
import { STATE, TOKEN, startMockServer, type MockServerOptions } from "./mock-server.js";

const FAST: BackoffPolicy = { initialMs: 5, maxMs: 20, factor: 2 };

async function withServer<T>(options: MockServerOptions, body: (server: Awaited<ReturnType<typeof startMockServer>>) => Promise<T>): Promise<T> {
	const server = await startMockServer(options);
	try {
		return await body(server);
	} finally {
		await server.close();
	}
}

describe("ApiClient.events()", () => {
	it("dispatches state and run events from the stream", () =>
		withServer({}, async (server) => {
			const states: SwitchboardState[] = [];
			const runs: RunEvent[] = [];
			let opens = 0;
			const client = new ApiClient({ host: server.host, port: server.port, token: TOKEN });
			const subscription = client.events(
				{ onState: (s) => states.push(s), onRun: (r) => runs.push(r), onOpen: () => opens++ },
				{ backoff: FAST },
			);
			try {
				await waitFor(() => runs.length >= 3, "three run events");
				expect(opens).toBe(1);
				expect(states).toEqual([STATE]);
				expect(runs.map((r) => r.status)).toEqual(["started", "step", "finished"]);
				expect(runs[1]).toMatchObject({ runId: "run-events-1", id: "guest", kind: "macro", step: 1, stepCount: 2 });
				expect(server.openEventStreams).toBe(1);
			} finally {
				subscription.close();
				await subscription.done;
			}
			await waitFor(() => server.openEventStreams === 0, "the stream to be released");
		}));

	it("sends the bearer token and asks for an event stream", () =>
		withServer({}, async (server) => {
			const client = new ApiClient({ host: server.host, port: server.port, token: TOKEN });
			const subscription = client.events({ onState: () => undefined }, { backoff: FAST });
			await waitFor(() => server.requests.some((r) => r.url === "/events"), "the /events request");
			subscription.close();
			await subscription.done;
			const request = server.requests.find((r) => r.url === "/events");
			expect(request?.headers.authorization).toBe(`Bearer ${TOKEN}`);
			expect(request?.headers.accept).toBe("text/event-stream");
		}));

	it("reconnects after the server closes the stream", () =>
		withServer({ events: { closeAfterMs: 10 } }, async (server) => {
			const states: SwitchboardState[] = [];
			const closes: Error[] = [];
			let opens = 0;
			const client = new ApiClient({ host: server.host, port: server.port, token: TOKEN });
			const subscription = client.events(
				{ onState: (s) => states.push(s), onOpen: () => opens++, onClose: (reason) => closes.push(reason) },
				{ backoff: FAST },
			);
			try {
				await waitFor(() => server.eventConnections >= 3 && states.length >= 3, "three connections");
				expect(opens).toBeGreaterThanOrEqual(3);
				expect(closes.length).toBeGreaterThanOrEqual(2);
				expect(closes[0]).toBeInstanceOf(ConnectionError);
				expect(closes[0]?.message).toBe("event stream ended");
			} finally {
				subscription.close();
				await subscription.done;
			}
		}));

	it("stops reconnecting once closed", () =>
		withServer({ events: { closeAfterMs: 5 } }, async (server) => {
			const client = new ApiClient({ host: server.host, port: server.port, token: TOKEN });
			const subscription = client.events({ onState: () => undefined }, { backoff: FAST });
			await waitFor(() => server.eventConnections >= 2, "a reconnect");
			subscription.close();
			await subscription.done;
			const connections = server.eventConnections;
			await delay(60);
			expect(server.eventConnections).toBe(connections);
			expect(server.openEventStreams).toBe(0);
		}));

	it("honours an external abort signal", () =>
		withServer({}, async (server) => {
			const controller = new AbortController();
			const client = new ApiClient({ host: server.host, port: server.port, token: TOKEN });
			const subscription = client.events({ onState: () => undefined }, { backoff: FAST, signal: controller.signal });
			await waitFor(() => server.openEventStreams === 1, "the stream to open");
			controller.abort();
			await subscription.done;
			await waitFor(() => server.openEventStreams === 0, "the stream to close");
		}));

	it("reconnects when the stream goes silent for longer than the idle timeout", () =>
		withServer({ events: { silent: true } }, async (server) => {
			const closes: Error[] = [];
			const client = new ApiClient({ host: server.host, port: server.port, token: TOKEN });
			const subscription = client.events(
				{ onState: () => undefined, onClose: (reason) => closes.push(reason) },
				{ backoff: FAST, idleTimeoutMs: 30 },
			);
			try {
				await waitFor(() => server.eventConnections >= 2, "a reconnect after idling");
				expect(closes[0]).toBeInstanceOf(ConnectionError);
				expect(closes[0]?.message).toBe("no data for 30 ms");
			} finally {
				subscription.close();
				await subscription.done;
			}
		}));

	it("reports a 401 as a typed error and keeps retrying", () =>
		withServer({}, async (server) => {
			const closes: Error[] = [];
			const client = new ApiClient({ host: server.host, port: server.port, token: "wrong" });
			const subscription = client.events({ onState: () => undefined, onClose: (reason) => closes.push(reason) }, { backoff: FAST });
			try {
				await waitFor(() => closes.length >= 2, "two rejected attempts");
				expect(closes[0]).toBeInstanceOf(ApiError);
				expect(closes[0]).toMatchObject({ status: 401, code: "unauthorized" });
				expect(server.eventConnections).toBe(0);
			} finally {
				subscription.close();
				await subscription.done;
			}
		}));

	it("reports a refused connection and keeps retrying", async () => {
		const gone = await startMockServer();
		await gone.close();
		const closes: Error[] = [];
		const client = new ApiClient({ host: gone.host, port: gone.port, token: TOKEN });
		const subscription = client.events({ onState: () => undefined, onClose: (reason) => closes.push(reason) }, { backoff: FAST });
		try {
			await waitFor(() => closes.length >= 2, "two refused attempts");
			expect(closes[0]).toBeInstanceOf(ConnectionError);
		} finally {
			subscription.close();
			await subscription.done;
		}
	});

	it("survives a handler that throws and reports it", () =>
		withServer({}, async (server) => {
			const errors: Error[] = [];
			const runs: RunEvent[] = [];
			const client = new ApiClient({ host: server.host, port: server.port, token: TOKEN });
			const subscription = client.events(
				{
					onState: () => {
						throw new Error("tile exploded");
					},
					onRun: (r) => runs.push(r),
					onError: (e) => errors.push(e),
				},
				{ backoff: FAST },
			);
			try {
				await waitFor(() => runs.length >= 3, "run events after the throwing handler");
				expect(errors.map((e) => e.message)).toEqual(["tile exploded"]);
			} finally {
				subscription.close();
				await subscription.done;
			}
		}));
});

describe("backoff", () => {
	it("starts at 1 s, doubles, and caps at 30 s as API.md requires", () => {
		const delays: number[] = [];
		let current: number | undefined;
		for (let i = 0; i < 8; i++) {
			current = nextBackoff(current);
			delays.push(current);
		}
		expect(delays).toEqual([1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000]);
		expect(DEFAULT_BACKOFF).toEqual({ initialMs: 1000, maxMs: 30000, factor: 2 });
	});

	it("never exceeds the cap even for the first delay", () => {
		expect(nextBackoff(undefined, { initialMs: 50, maxMs: 20, factor: 2 })).toBe(20);
	});
});
