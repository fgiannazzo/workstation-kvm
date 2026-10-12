import { describe, expect, it } from "vitest";

import { DEFAULT_HOST, DEFAULT_PORT, describeConnection, parsePort, resolveConnection, sameConnection } from "../src/settings.js";

describe("resolveConnection", () => {
	it("defaults to 127.0.0.1:48600 with no token", () => {
		expect(resolveConnection(undefined)).toEqual({ host: DEFAULT_HOST, port: DEFAULT_PORT, token: "" });
		expect(resolveConnection({})).toEqual({ host: "127.0.0.1", port: 48600, token: "" });
		expect(resolveConnection({ host: "  ", port: "", token: "" })).toEqual({ host: "127.0.0.1", port: 48600, token: "" });
	});

	it("accepts the strings a property inspector stores and trims them", () => {
		expect(resolveConnection({ host: " localhost ", port: " 48601 ", token: " abc " })).toEqual({ host: "localhost", port: 48601, token: "abc" });
	});

	it("accepts a numeric port", () => {
		expect(resolveConnection({ port: 9000 }).port).toBe(9000);
	});

	it("falls back to the default port for anything that is not a port", () => {
		for (const bad of ["abc", "0", "65536", "-1", "48600.5", 0, 70000, 1.5, null, true]) {
			expect(resolveConnection({ port: bad as never }).port).toBe(DEFAULT_PORT);
		}
	});
});

describe("parsePort", () => {
	it("parses valid ports and rejects the rest", () => {
		expect(parsePort("1")).toBe(1);
		expect(parsePort("65535")).toBe(65535);
		expect(parsePort(48600)).toBe(48600);
		expect(parsePort("65536")).toBeUndefined();
		expect(parsePort("")).toBeUndefined();
		expect(parsePort(undefined)).toBeUndefined();
	});
});

describe("describeConnection and sameConnection", () => {
	it("describes host and port but never the token", () => {
		expect(describeConnection({ host: "127.0.0.1", port: 48600, token: "secret" })).toBe("127.0.0.1:48600");
	});

	it("compares every field including the token", () => {
		const a = { host: "127.0.0.1", port: 48600, token: "t" };
		expect(sameConnection(a, { ...a })).toBe(true);
		expect(sameConnection(a, { ...a, token: "u" })).toBe(false);
		expect(sameConnection(a, { ...a, port: 1 })).toBe(false);
		expect(sameConnection(a, { ...a, host: "localhost" })).toBe(false);
	});
});
