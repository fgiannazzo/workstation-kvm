/**
 * Wire types transcribed from `docs/API.md`. That file is the contract; nothing here goes beyond it.
 * Unknown fields are ignored by clients, so every type is open to extra properties at runtime.
 */

export type PbpState = "on" | "off" | "unknown";
export type MainInput = "hdmi1" | "hdmi2" | "unknown";
export type DisplayId = "dualup" | "lg4k" | "samsung";
/** Whether the Mac drives the physical displays (`displays.off` / `displays.on`). */
export type DisplaysState = "on" | "off" | "mixed" | "unknown";

/** `GET /state` and the payload of every `state` event on `GET /events`. */
export interface SwitchboardState {
	pbp: PbpState;
	mainInput: MainInput;
	/** 1..4, or `null` when unknown. */
	usbPort: number | null;
	/** Assumed HDMI input per display; keys may be missing. */
	hdmiInput: Partial<Record<DisplayId, number>>;
	controllerReachable: boolean;
	dualUpReachable: boolean;
	/** Absent from servers older than `displays.off`; treated as unknown. */
	displays?: DisplaysState;
	lastError: string | null;
	/** ISO 8601 with fractional seconds and `Z`. */
	updatedAt: string;
}

/** `GET /health`, the only unauthenticated resource. */
export interface Health {
	ok: boolean;
	name: string;
	version: string;
}

export type ActionParameter =
	| { name: string; type: "enum"; values: string[] }
	| { name: string; type: "int"; min?: number; max?: number }
	| { name: string; type: "string" };

/** One entry of `GET /actions`. */
export interface ActionDescriptor {
	id: string;
	title: string;
	parameters: ActionParameter[];
}

/** A macro step: `action` plus that action's parameters as sibling keys. */
export interface MacroStep {
	action: string;
	[parameter: string]: unknown;
}

/** One entry of `GET /macros`. */
export interface Macro {
	id: string;
	name: string;
	steps: MacroStep[];
	verify?: Partial<Record<keyof SwitchboardState, unknown>>;
}

export type RunKind = "macro" | "action";

/** `202 Accepted` body of `POST /run/{id}`. */
export interface RunAccepted {
	runId: string;
	id: string;
	kind: RunKind;
}

export type RunStatus = "started" | "step" | "finished" | "failed";

/** Payload of a `run` event on `GET /events`. `message` carries the error when `status` is `failed`. */
export interface RunEvent {
	runId: string;
	id: string;
	kind: RunKind;
	status: RunStatus;
	step: number;
	stepCount: number;
	message: string;
}

/** Error body shape shared by 400, 401, 404 and 409. */
export interface ApiErrorBody {
	error: string;
	[detail: string]: unknown;
}
