import { describe, expect, it } from "vitest";

import { ApiClient } from "../src/api.js";
import type { HubLogger } from "../src/events-hub.js";
import { MacroCatalog } from "../src/macro-catalog.js";
import { MACROS, TOKEN, startMockServer } from "./mock-server.js";

const silent: HubLogger = { info: () => undefined, warn: () => undefined, debug: () => undefined };

describe("MacroCatalog", () => {
	it("loads the macros when it gets a client and tells listeners once", async () => {
		const server = await startMockServer();
		try {
			const catalog = new MacroCatalog(silent);
			let changes = 0;
			catalog.subscribe(() => changes++);
			catalog.setClient(new ApiClient({ host: server.host, port: server.port, token: TOKEN }));
			await catalog.reload(); // joins the load setClient started
			expect([...catalog.macros.keys()]).toEqual(["guest", "solo"]);
			expect(catalog.macros.get("guest")?.verify).toEqual({ pbp: "on", usbPort: 2 });
			expect(changes).toBe(1);
			expect(server.requests.filter((r) => r.url === "/macros")).toHaveLength(1);
		} finally {
			await server.close();
		}
	});

	it("coalesces reloads within the minimum interval", async () => {
		const server = await startMockServer();
		try {
			const catalog = new MacroCatalog(silent, { minIntervalMs: 60_000 });
			catalog.setClient(new ApiClient({ host: server.host, port: server.port, token: TOKEN }));
			await Promise.all([catalog.reload(), catalog.reload(), catalog.reload()]);
			await catalog.reload();
			expect(server.requests.filter((r) => r.url === "/macros")).toHaveLength(1);
		} finally {
			await server.close();
		}
	});

	it("takes a list from elsewhere and only notifies on a real change", () => {
		const catalog = new MacroCatalog(silent);
		let changes = 0;
		catalog.subscribe(() => changes++);
		catalog.update(MACROS);
		catalog.update(MACROS.map((m) => ({ ...m })));
		expect(changes).toBe(1);
		catalog.update([{ ...MACROS[0]!, verify: { pbp: "on", usbPort: 3 } }]);
		expect(changes).toBe(2);
		expect([...catalog.macros.keys()]).toEqual(["guest"]);
	});

	it("keeps no macros and makes no request without a client or when the app is down", async () => {
		const catalog = new MacroCatalog(silent);
		await catalog.reload();
		expect(catalog.macros.size).toBe(0);

		const server = await startMockServer();
		const { host, port } = server;
		await server.close();
		catalog.setClient(new ApiClient({ host, port, token: TOKEN, timeoutMs: 500 }));
		await catalog.reload();
		expect(catalog.macros.size).toBe(0);
	});

	it("forgets the old macros when the client changes", async () => {
		const catalog = new MacroCatalog(silent);
		catalog.update(MACROS);
		catalog.setClient(undefined);
		expect(catalog.macros.size).toBe(0);
	});
});
