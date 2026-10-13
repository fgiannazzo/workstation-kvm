import { describe, expect, it } from "vitest";

import { actionTarget, keyTarget, macroTarget, matches } from "../src/active.js";
import type { Macro } from "../src/types.js";
import { MACROS, STATE } from "./mock-server.js";

const macros = new Map(MACROS.map((macro) => [macro.id, macro]));

describe("actionTarget", () => {
	it("maps the actions that set a state field", () => {
		expect(actionTarget("monitor.pbp.on", undefined)).toEqual({ pbp: "on" });
		expect(actionTarget("monitor.pbp.off", undefined)).toEqual({ pbp: "off" });
		expect(actionTarget("displays.off", undefined)).toEqual({ displays: "off" });
		expect(actionTarget("displays.on", undefined)).toEqual({ displays: "on" });
		expect(actionTarget("usb.select", { port: 2 })).toEqual({ usbPort: 2 });
		expect(actionTarget("usb.select", { port: "3" })).toEqual({ usbPort: 3 });
		expect(actionTarget("hdmi.select", { display: "lg4k", input: 2 })).toEqual({ hdmiInput: { lg4k: 2 } });
		expect(actionTarget("hdmi.resync", { display: "dualup", input: 1 })).toEqual({ hdmiInput: { dualup: 1 } });
	});

	it("has no target for other actions or incomplete parameters", () => {
		for (const id of ["delay", "notify", "monitor.read", "nope"]) expect(actionTarget(id, { ms: 5 })).toBeUndefined();
		expect(actionTarget("usb.select", undefined)).toBeUndefined();
		expect(actionTarget("usb.select", { port: "two" })).toBeUndefined();
		expect(actionTarget("usb.select", { port: 1.5 })).toBeUndefined();
		expect(actionTarget("hdmi.select", { display: "lg4k" })).toBeUndefined();
	});
});

describe("macroTarget", () => {
	it("uses verify when the macro has one", () => {
		expect(macroTarget(macros.get("guest")!)).toEqual({ pbp: "on", usbPort: 2 });
	});

	it("derives the target from the steps without verify, later steps winning", () => {
		const macro: Macro = {
			id: "desk",
			name: "Desk",
			steps: [
				{ action: "usb.select", port: 1 },
				{ action: "hdmi.select", display: "lg4k", input: 2 },
				{ action: "delay", ms: 100 },
				{ action: "hdmi.select", display: "samsung", input: 1 },
				{ action: "usb.select", port: 3 },
			],
		};
		expect(macroTarget(macro)).toEqual({ usbPort: 3, hdmiInput: { lg4k: 2, samsung: 1 } });
		expect(macroTarget({ ...macro, verify: {} })).toEqual({ usbPort: 3, hdmiInput: { lg4k: 2, samsung: 1 } });
	});

	it("has no target when no step sets anything", () => {
		expect(macroTarget({ id: "wait", name: "Wait", steps: [{ action: "delay", ms: 5 }, { action: "notify", text: "hi" }] })).toBeUndefined();
	});
});

describe("keyTarget", () => {
	it("prefers a macro over an action with the same id", () => {
		const both = new Map(macros);
		both.set("usb.select", { id: "usb.select", name: "Shadow", steps: [], verify: { pbp: "off" } });
		expect(keyTarget("usb.select", { port: 2 }, both)).toEqual({ pbp: "off" });
		expect(keyTarget("usb.select", { port: 2 }, macros)).toEqual({ usbPort: 2 });
		expect(keyTarget("solo", undefined, macros)).toEqual({ pbp: "off", usbPort: 1 });
	});
});

describe("matches", () => {
	it("is true when every target field holds", () => {
		expect(matches(STATE, { pbp: "on", usbPort: 2 })).toBe(true);
		expect(matches(STATE, { usbPort: 2 })).toBe(true);
		expect(matches(STATE, { hdmiInput: { lg4k: 2 } })).toBe(true);
	});

	it("is false when any field differs or is unknown", () => {
		expect(matches(STATE, { pbp: "off", usbPort: 2 })).toBe(false);
		expect(matches(STATE, { hdmiInput: { lg4k: 1 } })).toBe(false);
		expect(matches({ ...STATE, usbPort: null }, { usbPort: 2 })).toBe(false);
		expect(matches({ ...STATE, hdmiInput: {} }, { hdmiInput: { lg4k: 2 } })).toBe(false);
	});

	it("is false without a state or a target", () => {
		expect(matches(undefined, { pbp: "on" })).toBe(false);
		expect(matches(STATE, undefined)).toBe(false);
		expect(matches(STATE, {})).toBe(false);
	});

	it("lights displays.off only while every display is off, and neither key while mixed", () => {
		const off = actionTarget("displays.off", undefined);
		const on = actionTarget("displays.on", undefined);
		expect([matches(STATE, off), matches(STATE, on)]).toEqual([false, true]);
		expect([matches({ ...STATE, displays: "off" }, off), matches({ ...STATE, displays: "off" }, on)]).toEqual([true, false]);
		expect([matches({ ...STATE, displays: "mixed" }, off), matches({ ...STATE, displays: "mixed" }, on)]).toEqual([false, false]);
	});

	it("makes Guest and Solo exclusive", () => {
		const guest = macroTarget(macros.get("guest")!);
		const solo = macroTarget(macros.get("solo")!);
		expect([matches(STATE, guest), matches(STATE, solo)]).toEqual([true, false]);
		const soloState = { ...STATE, pbp: "off" as const, usbPort: 1 };
		expect([matches(soloState, guest), matches(soloState, solo)]).toEqual([false, true]);
		const between = { ...STATE, pbp: "on" as const, usbPort: 1 };
		expect([matches(between, guest), matches(between, solo)]).toEqual([false, false]);
	});
});
