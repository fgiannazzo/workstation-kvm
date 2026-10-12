import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { ApiClient, ApiError, ConnectionError } from "../src/api.js";
import { ACTIONS, HEALTH, MACROS, STATE, TOKEN, startMockServer, type MockServer } from "./mock-server.js";

describe("ApiClient", () => {
	let server: MockServer;

	beforeAll(async () => {
		server = await startMockServer();
	});

	afterAll(async () => {
		await server.close();
	});

	const client = (token: string = TOKEN): ApiClient => new ApiClient({ host: server.host, port: server.port, token });

	it("sends the bearer token on authenticated calls", async () => {
		await client().state();
		const request = server.requests.findLast((r) => r.url === "/state");
		expect(request?.method).toBe("GET");
		expect(request?.headers.authorization).toBe(`Bearer ${TOKEN}`);
		expect(request?.headers.accept).toBe("application/json");
	});

	it("health() needs no token and returns the health document", async () => {
		const anonymous = new ApiClient({ host: server.host, port: server.port });
		expect(await anonymous.health()).toEqual(HEALTH);
		const request = server.requests.findLast((r) => r.url === "/health");
		expect(request?.headers.authorization).toBeUndefined();
	});

	it("state() returns the SwitchboardState object", async () => {
		expect(await client().state()).toEqual(STATE);
	});

	it("actions() and macros() unwrap their envelopes", async () => {
		expect(await client().actions()).toEqual(ACTIONS);
		expect(await client().macros()).toEqual(MACROS);
	});

	it("talks to exactly one origin", () => {
		expect(client().baseUrl).toBe(`http://127.0.0.1:${server.port}`);
		expect(new ApiClient({ host: "::1", port: 1 }).baseUrl).toBe("http://[::1]:1");
		expect(new ApiClient().baseUrl).toBe("http://127.0.0.1:48600");
	});

	describe("run()", () => {
		it("returns the accepted run on 202 and sends no body without parameters", async () => {
			const accepted = await client().run("guest");
			expect(accepted).toMatchObject({ id: "guest", kind: "macro" });
			expect(accepted.runId).toMatch(/^run-\d+$/);
			const request = server.requests.findLast((r) => r.url === "/run/guest");
			expect(request?.method).toBe("POST");
			expect(request?.headers.authorization).toBe(`Bearer ${TOKEN}`);
			expect(request?.body).toBe("");
			expect(request?.headers["content-type"]).toBeUndefined();
		});

		it("posts the parameters as the JSON body", async () => {
			const accepted = await client().run("usb.select", { port: 2 });
			expect(accepted).toMatchObject({ id: "usb.select", kind: "action" });
			const request = server.requests.findLast((r) => r.url === "/run/usb.select");
			expect(request?.headers["content-type"]).toBe("application/json");
			expect(JSON.parse(request?.body ?? "")).toEqual({ port: 2 });
		});

		it("URL-encodes the id", async () => {
			await expect(client().run("odd id/with slash")).rejects.toBeInstanceOf(ApiError);
			expect(server.requests.at(-1)?.url).toBe("/run/odd%20id%2Fwith%20slash");
		});

		it("throws a typed 401 on a wrong token", async () => {
			const error = await client("wrong").run("guest").catch((e: unknown) => e);
			expect(error).toBeInstanceOf(ApiError);
			const apiError = error as ApiError;
			expect(apiError.status).toBe(401);
			expect(apiError.code).toBe("unauthorized");
			expect(apiError.isUnauthorized).toBe(true);
			expect(apiError.body).toEqual({ error: "unauthorized" });
		});

		it("throws a typed 401 when no token is configured", async () => {
			await expect(client("").state()).rejects.toMatchObject({ name: "ApiError", status: 401, code: "unauthorized" });
			expect(server.requests.at(-1)?.headers.authorization).toBeUndefined();
		});

		it("throws a typed 404 for an unknown id", async () => {
			const error = await client().run("nope").catch((e: unknown) => e);
			expect(error).toBeInstanceOf(ApiError);
			expect(error).toMatchObject({ status: 404, code: "unknown id", isNotFound: true, body: { error: "unknown id", id: "nope" } });
			expect((error as ApiError).message).toBe("HTTP 404: unknown id (id=nope)");
		});

		it("throws a typed 400 when a parameter is missing", async () => {
			const error = await client().run("usb.select").catch((e: unknown) => e);
			expect(error).toMatchObject({ status: 400, code: "missing parameter", isBadRequest: true, body: { parameter: "port" } });
		});

		it("throws a typed 409 while another run is in progress", async () => {
			const busy = await startMockServer({ busy: true });
			try {
				const error = await new ApiClient({ host: busy.host, port: busy.port, token: TOKEN }).run("guest").catch((e: unknown) => e);
				expect(error).toBeInstanceOf(ApiError);
				expect(error).toMatchObject({ status: 409, code: "busy", isBusy: true, body: { runId: "busy-0001" } });
			} finally {
				await busy.close();
			}
		});

		it("rejects an empty id without touching the network", async () => {
			const before = server.requests.length;
			await expect(client().run("  ")).rejects.toBeInstanceOf(TypeError);
			expect(server.requests.length).toBe(before);
		});
	});

	it("throws ConnectionError when nothing listens on the port", async () => {
		const gone = await startMockServer();
		await gone.close();
		const error = await new ApiClient({ host: gone.host, port: gone.port, token: TOKEN }).state().catch((e: unknown) => e);
		expect(error).toBeInstanceOf(ConnectionError);
		expect((error as Error).message).toContain("is the Switchboard app running?");
	});

	it("throws ConnectionError when the server does not answer in time", async () => {
		const hang: typeof fetch = (_input, init) =>
			new Promise((_resolve, reject) => init?.signal?.addEventListener("abort", () => reject(init.signal?.reason)));
		const slow = new ApiClient({ host: server.host, port: server.port, token: TOKEN, timeoutMs: 20, fetch: hang });
		const error = await slow.state().catch((e: unknown) => e);
		expect(error).toBeInstanceOf(ConnectionError);
		expect((error as Error).message).toContain("did not answer in time");
	});

	it("throws ConnectionError when the body never completes", async () => {
		const stalled = await startMockServer({ events: { silent: true } });
		try {
			// /events sends headers and then nothing, so reading its body as a plain request stalls.
			const toEvents: typeof fetch = (input, init) => fetch(new URL("/events", String(input)), init);
			const slow = new ApiClient({ host: stalled.host, port: stalled.port, token: TOKEN, timeoutMs: 50, fetch: toEvents });
			const error = await slow.state().catch((e: unknown) => e);
			expect(error).toBeInstanceOf(ConnectionError);
			expect((error as Error).message).toContain("did not answer in time");
		} finally {
			await stalled.close();
		}
	});
});
