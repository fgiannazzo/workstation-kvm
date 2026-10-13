/**
 * When is a Run key "active"? When the desk already is what pressing the key would make it: the
 * state matches the key's target. A macro's target is its `verify` (docs/API.md, `GET /macros`),
 * or what its steps set when it has none; an action's target is what that one action sets. Ids
 * without a target (`delay`, `notify`, `monitor.read`, unknown ids) are never active.
 */
import type { Macro, MacroStep, SwitchboardState } from "./types.js";

/** `SwitchboardState` field names to the values they must hold; `hdmiInput` may name a subset of displays. */
export type Target = Record<string, unknown>;

/** What one action sets, or `undefined` for actions that do not change a state field. */
export function actionTarget(id: string, parameters: Record<string, unknown> | undefined): Target | undefined {
	switch (id) {
		case "monitor.pbp.on":
			return { pbp: "on" };
		case "monitor.pbp.off":
			return { pbp: "off" };
		case "displays.off":
			return { displays: "off" };
		case "displays.on":
			return { displays: "on" };
		case "usb.select": {
			const port = integer(parameters?.port);
			return port === undefined ? undefined : { usbPort: port };
		}
		case "hdmi.select":
		case "hdmi.resync": {
			const display = parameters?.display;
			const input = integer(parameters?.input);
			return typeof display === "string" && input !== undefined ? { hdmiInput: { [display]: input } } : undefined;
		}
		default:
			return undefined;
	}
}

/** A macro's `verify` when it has one, otherwise what its steps set in order (a later step wins). */
export function macroTarget(macro: Macro): Target | undefined {
	if (macro.verify && Object.keys(macro.verify).length > 0) return { ...macro.verify };
	let target: Target | undefined;
	for (const step of macro.steps ?? []) {
		const next = actionTarget(step.action, stepParameters(step));
		if (next) target = merge(target ?? {}, next);
	}
	return target;
}

/** The target of a Run key's id: a macro's when the id names one (macro ids win, as on the server), else the action's. */
export function keyTarget(
	id: string,
	parameters: Record<string, unknown> | undefined,
	macros: ReadonlyMap<string, Macro>,
): Target | undefined {
	const macro = macros.get(id);
	return macro ? macroTarget(macro) : actionTarget(id, parameters);
}

/** True when every field of the target holds in the state. No state or no target is never a match. */
export function matches(state: SwitchboardState | undefined, target: Target | undefined): boolean {
	if (!state || !target || Object.keys(target).length === 0) return false;
	const actual = state as unknown as Record<string, unknown>;
	return Object.entries(target).every(([field, expected]) => {
		const value = actual[field];
		if (isRecord(expected)) {
			return isRecord(value) && Object.entries(expected).every(([key, sub]) => value[key] === sub);
		}
		return value === expected;
	});
}

function stepParameters(step: MacroStep): Record<string, unknown> {
	const { action: _action, ...parameters } = step;
	return parameters;
}

function merge(into: Target, next: Target): Target {
	const out: Target = { ...into };
	for (const [field, value] of Object.entries(next)) {
		const existing = out[field];
		out[field] = isRecord(existing) && isRecord(value) ? { ...existing, ...value } : value;
	}
	return out;
}

/** An integer from a number or a numeric string (`{"port": "2"}` is what a hand-typed setting can hold). */
function integer(value: unknown): number | undefined {
	const n = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
	return typeof n === "number" && Number.isInteger(n) ? n : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
