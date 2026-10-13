import streamDeck, {
	action,
	SingletonAction,
	type DidReceiveSettingsEvent,
	type KeyAction,
	type KeyDownEvent,
	type WillAppearEvent,
	type WillDisappearEvent,
} from "@elgato/streamdeck";

import { keyTarget, matches } from "../active.js";
import { catalog, getClient, hub } from "../connection.js";
import { parseParameters } from "../parameters.js";
import { RunWatch } from "../run-watch.js";
import type { RunAccepted, RunEvent, SwitchboardState } from "../types.js";

/** Settings of one Run key. `parameters` is JSON text for the request body; `idLabel` is the
 * dropdown's text for `id`, shown while the app cannot be asked for the list. */
export type RunSettings = {
	id?: string;
	idLabel?: string;
	parameters?: string;
};

/** What `runOnKey` needs of a key: the alert overlay. */
export type FeedbackKey = Pick<KeyAction<RunSettings>, "showAlert">;

/** Manifest states of the Run action: 0 is the plain key, 1 the lit key. */
const INACTIVE = 0;
const ACTIVE = 1;

const logger = streamDeck.logger.createScope("run");

/**
 * Key action: `POST /run/{id}` on key down, with the alert triangle when the run is refused or
 * fails. Success shows no overlay: while visible the key lights up (state 1) whenever the desk
 * already matches what it would do (a macro's `verify`, the port of `usb.select`, ...; `active.ts`),
 * and that new state is the feedback.
 */
@action({ UUID: "io.github.fgiannazzo.switchboard.run" })
export class RunAction extends SingletonAction<RunSettings> {
	readonly #keys = new Map<string, RunKey>();

	override onWillAppear(ev: WillAppearEvent<RunSettings>): void {
		if (!ev.action.isKey()) return;
		const existing = this.#keys.get(ev.action.id);
		if (existing) existing.update(ev.payload.settings);
		else this.#keys.set(ev.action.id, new RunKey(ev.action, ev.payload.settings));
	}

	override onWillDisappear(ev: WillDisappearEvent<RunSettings>): void {
		this.#keys.get(ev.action.id)?.dispose();
		this.#keys.delete(ev.action.id);
	}

	override onDidReceiveSettings(ev: DidReceiveSettingsEvent<RunSettings>): void {
		this.#keys.get(ev.action.id)?.update(ev.payload.settings);
	}

	override async onKeyDown(ev: KeyDownEvent<RunSettings>): Promise<void> {
		const id = (ev.payload.settings.id ?? "").trim();
		if (id === "") {
			logger.warn("Key pressed without an id; pick a macro or action in the key's settings");
			await ev.action.showAlert();
			return;
		}

		let parameters: Record<string, unknown> | undefined;
		try {
			parameters = parseParameters(ev.payload.settings.parameters);
		} catch (error) {
			logger.warn(`Cannot run "${id}": ${messageOf(error)}`);
			await ev.action.showAlert();
			return;
		}

		await runOnKey(ev.action, id, parameters);
	}
}

/** One visible Run key: keeps its lit state in step with the desk. */
class RunKey {
	readonly #key: KeyAction<RunSettings>;
	readonly #unsubscribe: () => void;
	#settings: RunSettings;
	#state: SwitchboardState | undefined;
	#shown: number | undefined;

	constructor(key: KeyAction<RunSettings>, settings: RunSettings) {
		this.#key = key;
		this.#settings = settings;
		const unsubscribeHub = hub.subscribe({
			onConnection: (connected) => {
				if (!connected) this.#state = undefined;
				else void catalog.reload();
				this.render();
			},
			onState: (state) => {
				this.#state = state;
				this.render();
			},
		});
		const unsubscribeCatalog = catalog.subscribe(() => this.render());
		this.#unsubscribe = () => {
			unsubscribeHub();
			unsubscribeCatalog();
		};
		void catalog.reload();
		this.render();
	}

	update(settings: RunSettings): void {
		this.#settings = settings;
		void catalog.reload();
		this.render();
	}

	render(): void {
		const next = matches(this.#state, this.#target()) ? ACTIVE : INACTIVE;
		if (next === this.#shown) return;
		this.#shown = next;
		this.#key.setState(next).catch((error: unknown) => logger.warn(`setState failed: ${messageOf(error)}`));
	}

	dispose(): void {
		this.#unsubscribe();
	}

	#target(): ReturnType<typeof keyTarget> {
		const id = (this.#settings.id ?? "").trim();
		if (id === "") return undefined;
		let parameters: Record<string, unknown> | undefined;
		try {
			parameters = parseParameters(this.#settings.parameters);
		} catch {
			return undefined;
		}
		return keyTarget(id, parameters, catalog.macros);
	}
}

/**
 * Runs `id` for a key press: joins the event stream, posts once it is ready (or after 1 s), and
 * shows the alert when the API refuses the run or the accepted run ends `failed`. A good run shows
 * nothing here; the keys' lit state and faces show the new state. Shared by every key that starts runs.
 */
export async function runOnKey(key: FeedbackKey, id: string, parameters?: Record<string, unknown>): Promise<void> {
	const client = getClient();
	if (!client) {
		logger.warn(`Cannot run "${id}": host, port and token are not configured`);
		await key.showAlert();
		return;
	}

	const watch = new RunWatch(hub);
	if (!(await watch.ready)) logger.warn(`Event stream not ready; running "${id}" without watching for its result`);

	let accepted: RunAccepted;
	try {
		accepted = await client.run(id, parameters);
	} catch (error) {
		watch.close();
		logger.warn(`Run "${id}" failed: ${messageOf(error)}`);
		await key.showAlert();
		return;
	}
	logger.info(`Run ${accepted.runId} accepted: ${accepted.kind} "${accepted.id}"`);

	void followRun(watch, accepted.runId, key);
}

/** Waits for the run's last event (it may already have arrived) and shows the alert if it `failed`. */
async function followRun(watch: RunWatch, runId: string, key: FeedbackKey): Promise<void> {
	const run = await watch.result(runId);
	if (!run) {
		logger.info(`Run ${runId}: no result on the event stream within the watch time`);
	} else if (run.status === "failed") {
		reportFailed(run);
		await key.showAlert();
	} else {
		logger.info(`Run ${runId} (${run.id}) finished: ${run.message}`);
	}
}

function reportFailed(run: RunEvent): void {
	logger.warn(`Run ${run.runId} (${run.id}) failed at step ${run.step}/${run.stepCount}: ${run.message}`);
}

function messageOf(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
