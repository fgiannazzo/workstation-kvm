import type { SwitchboardState } from "./types.js";

/** Fields a State tile can show. Dotted names address the `hdmiInput` object. */
export const STATE_FIELDS = [
	"pbp",
	"mainInput",
	"usbPort",
	"controllerReachable",
	"hdmiInput.dualup",
	"hdmiInput.lg4k",
	"hdmiInput.samsung",
] as const;

export type StateField = (typeof STATE_FIELDS)[number];

export const DEFAULT_FIELD: StateField = "pbp";

/** Shown when the value is unknown or the plugin is not connected to the app. */
export const UNKNOWN_TITLE = "?";

export function isStateField(value: unknown): value is StateField {
	return typeof value === "string" && (STATE_FIELDS as readonly string[]).includes(value);
}

/**
 * Reads one field out of the state as a display string. `undefined` means "no value": the state is
 * missing, the field is `null`, the `hdmiInput` key is absent, or the field name is not known.
 * The literal `"unknown"` enum value is returned as is so a label can rename it.
 */
export function extractField(state: SwitchboardState | undefined | null, field: string): string | undefined {
	if (!state) return undefined;
	switch (field) {
		case "pbp":
			return typeof state.pbp === "string" ? state.pbp : undefined;
		case "mainInput":
			return typeof state.mainInput === "string" ? state.mainInput : undefined;
		case "usbPort":
			return typeof state.usbPort === "number" ? String(state.usbPort) : undefined;
		case "controllerReachable":
			return typeof state.controllerReachable === "boolean" ? String(state.controllerReachable) : undefined;
		default: {
			if (!field.startsWith("hdmiInput.")) return undefined;
			const display = field.slice("hdmiInput.".length);
			const inputs: Record<string, unknown> = state.hdmiInput ?? {};
			const value = inputs[display];
			return typeof value === "number" ? String(value) : undefined;
		}
	}
}

/**
 * Accepts the `labels` setting in either form: an object, or the JSON text a property inspector
 * text area stores. Anything else, including invalid JSON, yields no labels.
 */
export function normalizeLabels(raw: unknown): Record<string, string> | undefined {
	let value = raw;
	if (typeof value === "string") {
		if (value.trim() === "") return undefined;
		try {
			value = JSON.parse(value);
		} catch {
			return undefined;
		}
	}
	if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
	const labels: Record<string, string> = {};
	for (const [key, label] of Object.entries(value as Record<string, unknown>)) {
		if (typeof label === "string") labels[key] = label;
	}
	return labels;
}

/**
 * Maps a raw value to the tile title. A label wins when one exists for the value (including for
 * `"unknown"`); otherwise `"unknown"` and missing values become `"?"`, and anything else is shown
 * verbatim.
 */
export function formatTitle(value: string | undefined, labels?: Record<string, string>): string {
	const key = value ?? "unknown";
	const label = labels?.[key];
	if (label !== undefined) return label;
	return key === "unknown" ? UNKNOWN_TITLE : key;
}

export interface TileInput {
	state: SwitchboardState | undefined;
	/** False while the event stream is down: the tile shows the unknown title regardless of state. */
	connected: boolean;
	field: string | undefined;
	labels?: unknown;
}

/** The complete title computation for a State tile. */
export function tileTitle(input: TileInput): string {
	const labels = normalizeLabels(input.labels);
	if (!input.connected) return formatTitle(undefined, labels);
	return formatTitle(extractField(input.state, input.field ?? DEFAULT_FIELD), labels);
}
