import streamDeck, { action, SingletonAction, type KeyAction, type KeyDownEvent } from "@elgato/streamdeck";

import { getClient, hub } from "../connection.js";
import { parseParameters } from "../parameters.js";

/** Settings of one Run key. `parameters` is JSON text for the request body. */
export type RunSettings = {
	id?: string;
	parameters?: string;
};

const logger = streamDeck.logger.createScope("run");

/** How long a key keeps listening for the terminal `run` event of the run it started. */
const RUN_WATCH_TIMEOUT_MS = 120_000;

/**
 * Key action: `POST /run/{id}` on key down. `202` shows the OK check mark; any other answer or a
 * network failure shows the alert triangle and logs a warning. After a 202 the key watches the
 * event stream and shows the alert again if that run ends `failed`.
 */
@action({ UUID: "io.github.fgiannazzo.switchboard.run" })
export class RunAction extends SingletonAction<RunSettings> {
	override async onKeyDown(ev: KeyDownEvent<RunSettings>): Promise<void> {
		const id = (ev.payload.settings.id ?? "").trim();
		if (id === "") {
			logger.warn("Key pressed without an id; pick a macro or action in the key's settings");
			await ev.action.showAlert();
			return;
		}

		const client = getClient();
		if (!client) {
			logger.warn(`Cannot run "${id}": host, port and token are not configured`);
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

		try {
			const accepted = await client.run(id, parameters);
			logger.info(`Run ${accepted.runId} accepted: ${accepted.kind} "${accepted.id}"`);
			await ev.action.showOk();
			watchRun(accepted.runId, ev.action);
		} catch (error) {
			logger.warn(`Run "${id}" failed: ${messageOf(error)}`);
			await ev.action.showAlert();
		}
	}
}

/**
 * Best effort: subscribes to the shared event stream until the run finishes or fails. Opening the
 * stream after the 202 can miss a very short run's events; the watch then just times out.
 */
function watchRun(runId: string, key: KeyAction<RunSettings>): void {
	let finished = false;
	let unsubscribe: (() => void) | undefined;
	const finish = (): void => {
		if (finished) return;
		finished = true;
		clearTimeout(timer);
		unsubscribe?.();
	};
	const timer = setTimeout(finish, RUN_WATCH_TIMEOUT_MS);

	unsubscribe = hub.subscribe({
		onRun: (run) => {
			if (run.runId !== runId) return;
			if (run.status === "failed") {
				logger.warn(`Run ${runId} (${run.id}) failed at step ${run.step}/${run.stepCount}: ${run.message}`);
				void key.showAlert();
				finish();
			} else if (run.status === "finished") {
				logger.info(`Run ${runId} (${run.id}) finished: ${run.message}`);
				finish();
			}
		},
	});
	if (finished) unsubscribe();
}

function messageOf(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
