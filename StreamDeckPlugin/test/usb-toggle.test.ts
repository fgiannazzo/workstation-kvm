import { describe, expect, it } from "vitest";

import { nextPort, parsePorts, PORT_COLORS, UNKNOWN_COLOR, usbKeyImage, usbKeySvg } from "../src/usb-toggle.js";

describe("parsePorts", () => {
	it("reads commas, spaces and arrays, keeps order and drops duplicates", () => {
		expect(parsePorts("1,2")).toEqual([1, 2]);
		expect(parsePorts(" 3, 1 ;4 ")).toEqual([3, 1, 4]);
		expect(parsePorts("2 2 1 2")).toEqual([2, 1]);
		expect(parsePorts([4, "1"])).toEqual([4, 1]);
		expect(parsePorts("3")).toEqual([3]);
	});

	it("ignores ports outside 1 to 4 and falls back to 1,2", () => {
		expect(parsePorts("0, 5, 2")).toEqual([2]);
		expect(parsePorts("")).toEqual([1, 2]);
		expect(parsePorts("usb")).toEqual([1, 2]);
		expect(parsePorts(undefined)).toEqual([1, 2]);
		expect(parsePorts("1.5")).toEqual([1, 2]);
	});
});

describe("nextPort", () => {
	it("cycles through the list", () => {
		expect(nextPort(1, [1, 2])).toBe(2);
		expect(nextPort(2, [1, 2])).toBe(1);
		expect(nextPort(3, [1, 3, 4])).toBe(4);
		expect(nextPort(4, [1, 3, 4])).toBe(1);
		expect(nextPort(2, [2])).toBe(2);
	});

	it("starts at the first port when the current one is unknown or not listed", () => {
		expect(nextPort(null, [2, 1])).toBe(2);
		expect(nextPort(undefined, [1, 2])).toBe(1);
		expect(nextPort(3, [1, 2])).toBe(1);
		expect(nextPort(1, [])).toBe(2);
	});
});

describe("usbKeySvg", () => {
	it("shows the active port large on its colour, and the next port", () => {
		const svg = usbKeySvg({ port: 2, next: 1 });
		expect(svg).toContain(`fill="${PORT_COLORS[2]}"`);
		expect(svg).toContain('font-size="72" font-weight="700">2</text>');
		expect(svg).toContain(">next 1</text>");
		expect(svg).toContain(">USB</text>");
	});

	it("uses labels and shrinks long ones", () => {
		const svg = usbKeySvg({ port: 1, next: 2, labels: { "1": "Studio", "2": "Guest" } });
		expect(svg).toContain('font-size="34" font-weight="700">Studio</text>');
		expect(svg).toContain(">next Guest</text>");
	});

	it("shows ? on grey while the port is unknown", () => {
		const svg = usbKeySvg({ port: undefined, next: 1 });
		expect(svg).toContain(`fill="${UNKNOWN_COLOR}"`);
		expect(svg).toContain(">?</text>");
	});

	it("escapes label text", () => {
		expect(usbKeySvg({ port: 1, next: 2, labels: { "1": "A&B<" } })).toContain(">A&amp;B&lt;</text>");
	});

	it("is a base64 SVG data URL for setImage", () => {
		const url = usbKeyImage({ port: 1, next: 2 });
		expect(url.startsWith("data:image/svg+xml;base64,")).toBe(true);
		const svg = Buffer.from(url.slice("data:image/svg+xml;base64,".length), "base64").toString("utf8");
		expect(svg).toBe(usbKeySvg({ port: 1, next: 2 }));
	});
});
