import { describe, expect, it } from "vitest";

import { ApiClient, ConnectionError, type BackoffPolicy } from "../src/api.js";
import { EventsHub, type HubLogger } from "../src/events-hub.js";
import type { RunEvent, SwitchboardState } from "../src/types.js";
import { waitFor } from "./helpers.js";
import { STATE, TOKEN, startMockServer } from "./mock-server.js";

const FAST: BackoffPolicy = { initialMs: 5, maxMs: 20, factor: 2 };
const silent: HubLogger = { info: () => undefined, warn: () => undefined, debug: () => undefined };

describe("EventsHub", () => {
	it("shares one connection among all listeners and fans events out", async () => {
		const server = await startMockServer();
		try {
			const hub = new EventsHub(silent, { backoff: FAST });
			hub.setClient(new ApiClient({ host: server.host, port: server.port, token: TOKEN }));
			expect(server.eventConnections).toBe(0); // no listeners yet, no connection

			const states: SwitchboardState[][] = [[], [], []];
			const connections: boolean[][] = [[], [], []];
			const runs: RunEvent[] = [];
			const unsubscribe = [0, 1, 2].map((i) =>
				hub.subscribe({
					onState: (s) => states[i]!.push(s),
					onConnection: (c) => connections[i]!.push(c),
					...(i === 0 ? { onRun: (r: RunEvent) => runs.push(r) } : {}),
				}),
			);

			await waitFor(() => states.every((s) => s.length >= 1) && runs.length >= 3, "the first state on every listener");
			expect(server.eventConnections).toBe(1);
			expect(connections).toEqual([[false, true], [false, true], [false, true]]);
			expect(states.map((s) => s[0])).toEqual([STATE, STATE, STATE]);
			expect(hub.connected).toBe(true);
			expect(hub.state).toEqual(STATE);

			server.pushEvent("state", { ...STATE, pbp: "off" });
			await waitFor(() => states.every((s) => s.length >= 2), "the pushed state on every listener");
			expect(states.map((s) => s[1]?.pbp)).toEqual(["off", "off", "off"]);

			const late: SwitchboardState[] = [];
			const lateConnection: boolean[] = [];
			const unsubscribeLate = hub.subscribe({ onState: (s) => late.push(s), onConnection: (c) => lateConnection.push(c) });
			expect(lateConnection).toEqual([true]);
			expect(late[0]?.pbp).toBe("off");
			expect(server.eventConnections).toBe(1);

			for (const u of unsubscribe) u();
			expect(hub.listenerCount).toBe(1);
			expect(server.openEventStreams).toBe(1);
			unsubscribeLate();
			unsubscribeLate(); // idempotent
			expect(hub.listenerCount).toBe(0);
			expect(hub.connected).toBe(false);
			expect(hub.state).toBeUndefined();
			await waitFor(() => server.openEventStreams === 0, "the shared stream to close");
		} finally {
			await server.close();
		}
	});

	it("reports disconnected and opens nothing without a client", () => {
		const hub = new EventsHub(silent);
		const connections: boolean[] = [];
		const unsubscribe = hub.subscribe({ onConnection: (c) => connections.push(c) });
		expect(connections).toEqual([false]);
		expect(hub.connected).toBe(false);
		unsubscribe();
	});

	it("refresh() reads /state and broadcasts it", async () => {
		const server = await startMockServer({ events: { silent: true } });
		try {
			const hub = new EventsHub(silent, { backoff: FAST });
			hub.setClient(new ApiClient({ host: server.host, port: server.port, token: TOKEN }));
			const states: SwitchboardState[] = [];
			const unsubscribe = hub.subscribe({ onState: (s) => states.push(s) });
			expect(await hub.refresh()).toEqual(STATE);
			expect(states).toEqual([STATE]);
			expect(server.requests.filter((r) => r.url === "/state")).toHaveLength(1);
			unsubscribe();
		} finally {
			await server.close();
		}
	});

	it("refresh() fails with ConnectionError when not configured", async () => {
		const hub = new EventsHub(silent);
		await expect(hub.refresh()).rejects.toBeInstanceOf(ConnectionError);
	});

	it("reconnects to the new server when the client changes and disconnects on undefined", async () => {
		const first = await startMockServer();
		const second = await startMockServer();
		try {
			const hub = new EventsHub(silent, { backoff: FAST });
			const connections: boolean[] = [];
			const unsubscribe = hub.subscribe({ onConnection: (c) => connections.push(c) });
			hub.setClient(new ApiClient({ host: first.host, port: first.port, token: TOKEN }));
			await waitFor(() => hub.connected, "the first server");
			expect(first.eventConnections).toBe(1);

			hub.setClient(new ApiClient({ host: second.host, port: second.port, token: TOKEN }));
			await waitFor(() => second.eventConnections === 1 && hub.connected, "the second server");
			await waitFor(() => first.openEventStreams === 0, "the first stream to close");
			expect(connections).toEqual([false, true, false, true]);

			hub.setClient(undefined);
			expect(hub.connected).toBe(false);
			await waitFor(() => second.openEventStreams === 0, "the second stream to close");
			unsubscribe();
		} finally {
			await first.close();
			await second.close();
		}
	});

	it("flags the connection as lost while the server is away", async () => {
		const server = await startMockServer({ events: { closeAfterMs: 10 } });
		try {
			const hub = new EventsHub(silent, { backoff: FAST });
			hub.setClient(new ApiClient({ host: server.host, port: server.port, token: TOKEN }));
			const connections: boolean[] = [];
			const unsubscribe = hub.subscribe({ onConnection: (c) => connections.push(c) });
			await waitFor(() => connections.length >= 4, "connect, drop, reconnect");
			expect(connections.slice(0, 4)).toEqual([false, true, false, true]);
			unsubscribe();
		} finally {
			await server.close();
		}
	});
});
