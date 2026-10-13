import streamDeck, { action, SingletonAction, type KeyAction, type KeyDownEvent } from "@elgato/streamdeck";

import { getClient, hub } from "../connection.js";
import { parseParameters } from "../parameters.js";
import { RunWatch } from "../run-watch.js";
import type { RunAccepted, RunEvent } from "../types.js";

/** Settings of one Run key. `parameters` is JSON text for the request body; `idLabel` is the
 * dropdown's text for `id`, shown while the app cannot be asked for the list. */
export type RunSettings = {
	id?: string;
	idLabel?: string;
	parameters?: string;
};

const logger = streamDeck.logger.createScope("run");

/**
 * Key action: `POST /run/{id}` on key down. `202` shows the OK check mark; any other answer or a
 * network failure shows the alert triangle and logs a warning. The key joins the event stream
 * before it posts, so it also shows the alert when an accepted run ends `failed`, however fast.
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

		const watch = new RunWatch(hub);
		if (!(await watch.ready)) logger.warn(`Event stream not ready; running "${id}" without watching for its result`);

		let accepted: RunAccepted;
		try {
			accepted = await client.run(id, parameters);
		} catch (error) {
			watch.close();
			logger.warn(`Run "${id}" failed: ${messageOf(error)}`);
			await ev.action.showAlert();
			return;
		}
		logger.info(`Run ${accepted.runId} accepted: ${accepted.kind} "${accepted.id}"`);

		const early = watch.settled(accepted.runId);
		if (early?.status === "failed") {
			watch.close();
			reportFailed(early);
			await ev.action.showAlert();
			return;
		}
		await ev.action.showOk();
		void followRun(watch, accepted.runId, ev.action);
	}
}

/** Waits for the run's last event; a `failed` run turns the key's check mark into the alert. */
async function followRun(watch: RunWatch, runId: string, key: KeyAction<RunSettings>): Promise<void> {
	const run = await watch.result(runId);
	if (!run) {
		logger.info(`Run ${runId}: no result on the event stream; the key keeps its check mark`);
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
