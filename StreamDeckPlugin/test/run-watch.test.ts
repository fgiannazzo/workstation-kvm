import { describe, expect, it } from "vitest";

import { ApiClient } from "../src/api.js";
import { EventsHub, type HubListener, type HubLogger } from "../src/events-hub.js";
import { RunWatch, type RunEventSource } from "../src/run-watch.js";
import type { RunEvent, SwitchboardState } from "../src/types.js";
import { STATE, TOKEN, startMockServer } from "./mock-server.js";

const silent: HubLogger = { info: () => undefined, warn: () => undefined, debug: () => undefined };

/** A hand-driven event source: the test decides when states and runs arrive. */
class FakeSource implements RunEventSource {
	readonly listeners = new Set<HubListener>();
	replay: SwitchboardState | undefined;

	subscribe(listener: HubListener): () => void {
		this.listeners.add(listener);
		if (this.replay) listener.onState?.(this.replay);
		return () => this.listeners.delete(listener);
	}

	state(state: SwitchboardState = STATE): void {
		for (const listener of this.listeners) listener.onState?.(state);
	}

	run(runId: string, status: RunEvent["status"], message = ""): void {
		const event: RunEvent = { runId, id: "usb.select", kind: "action", status, step: status === "started" ? 0 : 1, stepCount: 1, message };
		for (const listener of this.listeners) listener.onRun?.(event);
	}
}

describe("RunWatch", () => {
	it("is ready at once when the stream already has a state", async () => {
		const source = new FakeSource();
		source.replay = STATE;
		const watch = new RunWatch(source, { readyTimeoutMs: 10_000 });
		expect(await watch.ready).toBe(true);
		watch.close();
		expect(source.listeners.size).toBe(0);
	});

	it("becomes ready with the first state event", async () => {
		const source = new FakeSource();
		const watch = new RunWatch(source, { readyTimeoutMs: 10_000 });
		source.state();
		expect(await watch.ready).toBe(true);
		watch.close();
	});

	it("is not ready when no state arrives in time, and keeps listening for the run", async () => {
		const source = new FakeSource();
		const watch = new RunWatch(source, { readyTimeoutMs: 10 });
		expect(await watch.ready).toBe(false);
		expect(source.listeners.size).toBe(1);
		const result = watch.result("run-1");
		source.run("run-1", "finished", "ok");
		expect((await result)?.status).toBe("finished");
		expect(source.listeners.size).toBe(0);
	});

	it("keeps a run's last event that arrives before the 202 has been read", async () => {
		const source = new FakeSource();
		const watch = new RunWatch(source);
		source.run("run-1", "started");
		source.run("run-1", "failed", "controller unreachable");
		expect(watch.settled("run-1")?.message).toBe("controller unreachable");
		expect(watch.settled("run-2")).toBeUndefined();
		expect((await watch.result("run-1"))?.status).toBe("failed");
		expect(source.listeners.size).toBe(0);
	});

	it("resolves with the matching run's last event and ignores other runs", async () => {
		const source = new FakeSource();
		const watch = new RunWatch(source);
		const result = watch.result("run-2");
		source.run("run-1", "failed", "someone else's run");
		source.run("run-2", "started");
		source.run("run-2", "step");
		expect(source.listeners.size).toBe(1);
		source.run("run-2", "finished", "ok");
		const run = await result;
		expect(run?.runId).toBe("run-2");
		expect(run?.status).toBe("finished");
		expect(source.listeners.size).toBe(0);
	});

	it("gives up after the result timeout", async () => {
		const source = new FakeSource();
		const watch = new RunWatch(source, { resultTimeoutMs: 10 });
		expect(await watch.result("run-1")).toBeUndefined();
		expect(source.listeners.size).toBe(0);
	});

	it("close() ends a pending result and is safe to repeat", async () => {
		const source = new FakeSource();
		const watch = new RunWatch(source);
		const result = watch.result("run-1");
		watch.close();
		watch.close();
		expect(await result).toBeUndefined();
		expect(await watch.ready).toBe(false);
		expect(await watch.result("run-1")).toBeUndefined();
		expect(source.listeners.size).toBe(0);
	});

	it("catches a run that fails before its 202 arrives, over a real event stream", async () => {
		const server = await startMockServer({ runEnds: "failed" });
		try {
			const client = new ApiClient({ host: server.host, port: server.port, token: TOKEN });
			const hub = new EventsHub(silent);
			hub.setClient(client);

			const watch = new RunWatch(hub);
			expect(await watch.ready).toBe(true);
			const accepted = await client.run("usb.select", { port: 2 });
			const run = await watch.result(accepted.runId);
			expect(run).toMatchObject({ runId: accepted.runId, status: "failed", message: "controller unreachable" });
			expect(hub.listenerCount).toBe(0);
			expect(server.eventConnections).toBe(1);
		} finally {
			await server.close();
		}
	});

	it("reuses the open stream when a tile already holds it", async () => {
		const server = await startMockServer({ runEnds: "finished" });
		try {
			const client = new ApiClient({ host: server.host, port: server.port, token: TOKEN });
			const hub = new EventsHub(silent);
			hub.setClient(client);
			const tile = new RunWatch(hub);
			expect(await tile.ready).toBe(true);

			const watch = new RunWatch(hub, { readyTimeoutMs: 50 });
			expect(await watch.ready).toBe(true);
			const accepted = await client.run("guest");
			expect((await watch.result(accepted.runId))?.status).toBe("finished");
			expect(server.eventConnections).toBe(1);
			tile.close();
		} finally {
			await server.close();
		}
	});
});
