import { describe, expect, it } from "vitest";

import { parseParameters } from "../src/parameters.js";

describe("parseParameters", () => {
	it("returns undefined for an empty setting so no body is sent", () => {
		expect(parseParameters(undefined)).toBeUndefined();
		expect(parseParameters(null)).toBeUndefined();
		expect(parseParameters("")).toBeUndefined();
		expect(parseParameters("  \n")).toBeUndefined();
	});

	it("parses a JSON object", () => {
		expect(parseParameters('{"port": 2}')).toEqual({ port: 2 });
		expect(parseParameters(' {"display":"dualup","input":1} ')).toEqual({ display: "dualup", input: 1 });
		expect(parseParameters("{}")).toEqual({});
	});

	it("throws SyntaxError for invalid JSON", () => {
		expect(() => parseParameters("{port: 2}")).toThrow(SyntaxError);
		expect(() => parseParameters("port=2")).toThrow(/not valid JSON/);
	});

	it("throws TypeError for JSON that is not an object", () => {
		expect(() => parseParameters("[1]")).toThrow(TypeError);
		expect(() => parseParameters("2")).toThrow(TypeError);
		expect(() => parseParameters('"text"')).toThrow(TypeError);
		expect(() => parseParameters("null")).toThrow(/must be a JSON object/);
	});
});
