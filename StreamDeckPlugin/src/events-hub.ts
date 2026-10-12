import { ConnectionError, type ApiClient, type BackoffPolicy, type EventsSubscription } from "./api.js";
import type { RunEvent, SwitchboardState } from "./types.js";

export interface HubListener {
	onState?(state: SwitchboardState): void;
	onRun?(run: RunEvent): void;
	/** Fired on subscribe with the current status and whenever it changes. */
	onConnection?(connected: boolean): void;
}

/** The subset of the SDK logger the hub needs; keeps this module free of the SDK for tests. */
export interface HubLogger {
	info(message: string): unknown;
	warn(message: string): unknown;
	debug(message: string): unknown;
}

export interface EventsHubOptions {
	backoff?: BackoffPolicy;
	idleTimeoutMs?: number;
}

/**
 * One `GET /events` connection per plugin process, fanned out to every State tile and every Run key
 * waiting on a run. The connection opens with the first listener and closes with the last one, and
 * reopens when the client (host, port, token) changes.
 */
export class EventsHub {
	readonly #logger: HubLogger;
	readonly #options: EventsHubOptions;
	readonly #listeners = new Set<HubListener>();
	#client: ApiClient | undefined;
	#subscription: EventsSubscription | undefined;
	#state: SwitchboardState | undefined;
	#connected = false;

	constructor(logger: HubLogger, options: EventsHubOptions = {}) {
		this.#logger = logger;
		this.#options = options;
	}

	/** Last state received on the current connection, if any. */
	get state(): SwitchboardState | undefined {
		return this.#state;
	}

	get connected(): boolean {
		return this.#connected;
	}

	get listenerCount(): number {
		return this.#listeners.size;
	}

	get client(): ApiClient | undefined {
		return this.#client;
	}

	/** Replaces the client; `undefined` disconnects and keeps tiles at "?". */
	setClient(client: ApiClient | undefined): void {
		this.#disconnect();
		this.#client = client;
		this.#ensureConnected();
	}

	/** Adds a listener, replaying the current connection status and state. Returns the unsubscribe function. */
	subscribe(listener: HubListener): () => void {
		this.#listeners.add(listener);
		listener.onConnection?.(this.#connected);
		if (this.#connected && this.#state) listener.onState?.(this.#state);
		this.#ensureConnected();

		let active = true;
		return () => {
			if (!active) return;
			active = false;
			this.#listeners.delete(listener);
			if (this.#listeners.size === 0) this.#disconnect();
		};
	}

	/** `GET /state` on demand, broadcast to listeners as if it had arrived on the stream. */
	async refresh(): Promise<SwitchboardState> {
		if (!this.#client) throw new ConnectionError("host, port and token are not configured");
		const state = await this.#client.state();
		this.#state = state;
		this.#emit((listener) => listener.onState?.(state));
		return state;
	}

	/** Closes the connection whatever the listener count; used on plugin shutdown. */
	close(): void {
		this.#disconnect();
	}

	#ensureConnected(): void {
		if (this.#subscription || !this.#client || this.#listeners.size === 0) return;
		const client = this.#client;
		this.#logger.info(`Connecting to ${client.baseUrl}/events`);
		this.#subscription = client.events(
			{
				onOpen: () => {
					this.#logger.info("Event stream connected");
					this.#setConnected(true);
				},
				onState: (state) => {
					this.#state = state;
					this.#emit((listener) => listener.onState?.(state));
				},
				onRun: (run) => {
					this.#emit((listener) => listener.onRun?.(run));
				},
				onClose: (reason) => {
					this.#logger.warn(`Event stream closed: ${reason.message}; reconnecting with backoff`);
					this.#setConnected(false);
				},
				onError: (error) => {
					this.#logger.warn(`Event ignored: ${error.message}`);
				},
			},
			this.#options,
		);
	}

	#disconnect(): void {
		if (this.#subscription) {
			this.#subscription.close();
			this.#subscription = undefined;
			this.#logger.debug("Event stream closed by the plugin");
		}
		this.#state = undefined;
		this.#setConnected(false);
	}

	#setConnected(connected: boolean): void {
		if (this.#connected === connected) return;
		this.#connected = connected;
		if (!connected) this.#state = undefined;
		this.#emit((listener) => listener.onConnection?.(connected));
	}

	#emit(call: (listener: HubListener) => void): void {
		for (const listener of [...this.#listeners]) {
			try {
				call(listener);
			} catch (error) {
				this.#logger.warn(`Listener failed: ${error instanceof Error ? error.message : String(error)}`);
			}
		}
	}
}
