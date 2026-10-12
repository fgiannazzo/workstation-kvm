import { describe, expect, it } from "vitest";

import { DEFAULT_FIELD, STATE_FIELDS, UNKNOWN_TITLE, extractField, formatTitle, isStateField, normalizeLabels, tileTitle } from "../src/state-format.js";
import type { SwitchboardState } from "../src/types.js";
import { STATE } from "./mock-server.js";

describe("extractField", () => {
	it("reads every supported field as a string", () => {
		expect(STATE_FIELDS.map((field) => [field, extractField(STATE, field)])).toEqual([
			["pbp", "on"],
			["mainInput", "hdmi1"],
			["usbPort", "2"],
			["controllerReachable", "true"],
			["hdmiInput.dualup", "1"],
			["hdmiInput.lg4k", "2"],
			["hdmiInput.samsung", "1"],
		]);
	});

	it("returns undefined for null, missing keys, unknown fields and no state", () => {
		const sparse: SwitchboardState = { ...STATE, usbPort: null, hdmiInput: { dualup: 2 }, controllerReachable: false };
		expect(extractField(sparse, "usbPort")).toBeUndefined();
		expect(extractField(sparse, "hdmiInput.lg4k")).toBeUndefined();
		expect(extractField(sparse, "hdmiInput.dualup")).toBe("2");
		expect(extractField(sparse, "controllerReachable")).toBe("false");
		expect(extractField(sparse, "lastError")).toBeUndefined();
		expect(extractField(sparse, "hdmiInput.")).toBeUndefined();
		expect(extractField(undefined, "pbp")).toBeUndefined();
		expect(extractField(null, "pbp")).toBeUndefined();
	});

	it("keeps the literal unknown enum value so a label can rename it", () => {
		expect(extractField({ ...STATE, pbp: "unknown" }, "pbp")).toBe("unknown");
		expect(extractField({ ...STATE, mainInput: "unknown" }, "mainInput")).toBe("unknown");
	});

	it("tolerates a state object missing hdmiInput entirely", () => {
		const partial = { ...STATE } as Partial<SwitchboardState>;
		delete partial.hdmiInput;
		expect(extractField(partial as SwitchboardState, "hdmiInput.dualup")).toBeUndefined();
	});
});

describe("formatTitle", () => {
	it("maps values through labels", () => {
		const labels = { on: "PBP ON", off: "PBP OFF" };
		expect(formatTitle("on", labels)).toBe("PBP ON");
		expect(formatTitle("off", labels)).toBe("PBP OFF");
	});

	it("shows the value verbatim without a label", () => {
		expect(formatTitle("hdmi2")).toBe("hdmi2");
		expect(formatTitle("3", { on: "x" })).toBe("3");
	});

	it("shows ? for unknown and missing values unless a label renames them", () => {
		expect(formatTitle(undefined)).toBe(UNKNOWN_TITLE);
		expect(formatTitle("unknown")).toBe("?");
		expect(formatTitle(undefined, { unknown: "n/a" })).toBe("n/a");
		expect(formatTitle("unknown", { unknown: "n/a" })).toBe("n/a");
	});
});

describe("normalizeLabels", () => {
	it("accepts an object and keeps only string values", () => {
		expect(normalizeLabels({ on: "ON", off: "OFF", "1": 1, nested: { a: "b" } })).toEqual({ on: "ON", off: "OFF" });
	});

	it("accepts the JSON text a property inspector stores", () => {
		expect(normalizeLabels('{"true":"Online","false":"Offline"}')).toEqual({ true: "Online", false: "Offline" });
	});

	it("yields no labels for empty, invalid or non-object input", () => {
		expect(normalizeLabels("")).toBeUndefined();
		expect(normalizeLabels("   ")).toBeUndefined();
		expect(normalizeLabels("{not json")).toBeUndefined();
		expect(normalizeLabels('["on"]')).toBeUndefined();
		expect(normalizeLabels("42")).toBeUndefined();
		expect(normalizeLabels(null)).toBeUndefined();
		expect(normalizeLabels(undefined)).toBeUndefined();
		expect(normalizeLabels(["on"])).toBeUndefined();
	});
});

describe("tileTitle", () => {
	it("defaults to the pbp field", () => {
		expect(DEFAULT_FIELD).toBe("pbp");
		expect(tileTitle({ state: STATE, connected: true, field: undefined })).toBe("on");
	});

	it("shows ? while disconnected even when a stale state exists", () => {
		expect(tileTitle({ state: STATE, connected: false, field: "pbp" })).toBe("?");
		expect(tileTitle({ state: STATE, connected: false, field: "pbp", labels: { on: "PBP ON", unknown: "offline" } })).toBe("offline");
	});

	it("combines field extraction and label mapping", () => {
		expect(tileTitle({ state: STATE, connected: true, field: "pbp", labels: '{"on":"PBP ON","off":"PBP OFF"}' })).toBe("PBP ON");
		expect(tileTitle({ state: STATE, connected: true, field: "controllerReachable", labels: { true: "ESP32 up", false: "ESP32 down" } })).toBe("ESP32 up");
		expect(tileTitle({ state: STATE, connected: true, field: "usbPort", labels: { "2": "Guest" } })).toBe("Guest");
		expect(tileTitle({ state: { ...STATE, usbPort: null }, connected: true, field: "usbPort" })).toBe("?");
		expect(tileTitle({ state: STATE, connected: true, field: "hdmiInput.samsung" })).toBe("1");
	});
});

describe("isStateField", () => {
	it("recognises the supported names only", () => {
		expect(STATE_FIELDS.every(isStateField)).toBe(true);
		expect(isStateField("lastError")).toBe(false);
		expect(isStateField(undefined)).toBe(false);
	});
});
