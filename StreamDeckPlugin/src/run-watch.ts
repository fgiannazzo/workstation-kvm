import type { HubListener } from "./events-hub.js";
import type { RunEvent } from "./types.js";

/** What a watch needs from the event stream; `EventsHub` is one. */
export interface RunEventSource {
	subscribe(listener: HubListener): () => void;
}

export interface RunWatchOptions {
	/** How long `ready` waits for the stream's first `state` event. Default 1 s. */
	readyTimeoutMs?: number;
	/** How long `result` waits for the run's `finished` or `failed` event. Default 2 min. */
	resultTimeoutMs?: number;
}

const DEFAULT_READY_TIMEOUT_MS = 1000;
const DEFAULT_RESULT_TIMEOUT_MS = 120_000;

/**
 * Follows one run on the shared event stream. Create it before `POST /run/{id}` and post once
 * `ready` has resolved: by then the stream has delivered a `state` event, and the server subscribes
 * to run progress before it sends that event (`docs/API.md`, "Ordering"), so no event of the run can
 * be missed. A `finished` or `failed` event that arrives before the 202 has been read is kept until
 * `settled` or `result` asks for it.
 */
export class RunWatch {
	/** True once the stream has delivered a state; false after the timeout or `close()`. */
	readonly ready: Promise<boolean>;
	readonly #resultTimeoutMs: number;
	readonly #ended = new Map<string, RunEvent>();
	readonly #readyTimer: ReturnType<typeof setTimeout>;
	#settleReady: (ready: boolean) => void = () => undefined;
	#unsubscribe: (() => void) | undefined;
	#waiting: { runId: string; settle: (run: RunEvent | undefined) => void } | undefined;

	constructor(source: RunEventSource, options: RunWatchOptions = {}) {
		this.#resultTimeoutMs = options.resultTimeoutMs ?? DEFAULT_RESULT_TIMEOUT_MS;
		this.ready = new Promise<boolean>((resolve) => {
			this.#settleReady = resolve;
		});
		this.#readyTimer = setTimeout(() => this.#settleReady(false), options.readyTimeoutMs ?? DEFAULT_READY_TIMEOUT_MS);
		// `subscribe` replays the current state at once when the stream is already up.
		this.#unsubscribe = source.subscribe({
			onState: () => {
				clearTimeout(this.#readyTimer);
				this.#settleReady(true);
			},
			onRun: (run) => this.#onRun(run),
		});
	}

	/** The run's `finished` or `failed` event if it has already arrived. */
	settled(runId: string): RunEvent | undefined {
		return this.#ended.get(runId);
	}

	/** The run's `finished` or `failed` event, or `undefined` if none arrives in time. Ends the watch. */
	result(runId: string): Promise<RunEvent | undefined> {
		const ended = this.#ended.get(runId);
		if (ended || !this.#unsubscribe) {
			this.close();
			return Promise.resolve(ended);
		}
		return new Promise((resolve) => {
			const timer = setTimeout(() => settle(undefined), this.#resultTimeoutMs);
			const settle = (run: RunEvent | undefined): void => {
				clearTimeout(timer);
				this.#waiting = undefined;
				this.close();
				resolve(run);
			};
			this.#waiting = { runId, settle };
		});
	}

	/** Stops listening; a pending `result` resolves to `undefined`. Safe to call more than once. */
	close(): void {
		clearTimeout(this.#readyTimer);
		this.#settleReady(false);
		this.#unsubscribe?.();
		this.#unsubscribe = undefined;
		this.#ended.clear();
		this.#waiting?.settle(undefined);
	}

	#onRun(run: RunEvent): void {
		if (run.status !== "finished" && run.status !== "failed") return;
		if (this.#waiting?.runId === run.runId) this.#waiting.settle(run);
		else this.#ended.set(run.runId, run);
	}
}
