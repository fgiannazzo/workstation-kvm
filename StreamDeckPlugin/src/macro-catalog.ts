import type { ApiClient } from "./api.js";
import type { HubLogger } from "./events-hub.js";
import type { Macro } from "./types.js";

export interface MacroCatalogOptions {
	/** A `reload()` within this long of the last load is skipped. Default 2 s. */
	minIntervalMs?: number;
}

/**
 * The app's macros (`GET /macros`), kept so Run keys can tell whether the desk already matches a
 * macro. There is no event for macro edits, so it reloads when the client changes, when keys
 * appear or change settings, when the event stream reconnects, and whenever a property inspector
 * lists the ids; reloads closer together than `minIntervalMs` are coalesced.
 */
export class MacroCatalog {
	readonly #logger: HubLogger;
	readonly #minIntervalMs: number;
	readonly #listeners = new Set<() => void>();
	#macros: ReadonlyMap<string, Macro> = new Map();
	#client: ApiClient | undefined;
	#loading: Promise<void> | undefined;
	#loadedAt = Number.NEGATIVE_INFINITY;

	constructor(logger: HubLogger, options: MacroCatalogOptions = {}) {
		this.#logger = logger;
		this.#minIntervalMs = options.minIntervalMs ?? 2000;
	}

	get macros(): ReadonlyMap<string, Macro> {
		return this.#macros;
	}

	/** Replaces the client, forgets the old macros and loads the new ones. */
	setClient(client: ApiClient | undefined): void {
		this.#client = client;
		this.#loading = undefined;
		this.#loadedAt = Number.NEGATIVE_INFINITY;
		this.#set(new Map());
		if (client) void this.reload();
	}

	/** Calls `listener` whenever the macros change. Returns the unsubscribe function. */
	subscribe(listener: () => void): () => void {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	}

	/** Loads the macros unless a load is running or finished less than `minIntervalMs` ago. */
	reload(): Promise<void> {
		const client = this.#client;
		if (!client) return Promise.resolve();
		if (this.#loading) return this.#loading;
		if (Date.now() - this.#loadedAt < this.#minIntervalMs) return Promise.resolve();
		const loading = client
			.macros()
			.then((macros) => {
				if (this.#client === client) this.update(macros);
			})
			.catch((error: unknown) => {
				this.#logger.debug(`Could not load macros: ${error instanceof Error ? error.message : String(error)}`);
			})
			.finally(() => {
				if (this.#loading === loading) this.#loading = undefined;
			});
		this.#loading = loading;
		return loading;
	}

	/** Takes a fresh list, for example the one a property inspector just fetched. */
	update(macros: readonly Macro[]): void {
		this.#loadedAt = Date.now();
		this.#set(new Map(macros.map((macro) => [macro.id, macro])));
	}

	#set(macros: ReadonlyMap<string, Macro>): void {
		if (sameMacros(this.#macros, macros)) return;
		this.#macros = macros;
		for (const listener of [...this.#listeners]) {
			try {
				listener();
			} catch (error) {
				this.#logger.warn(`Macro listener failed: ${error instanceof Error ? error.message : String(error)}`);
			}
		}
	}
}

function sameMacros(a: ReadonlyMap<string, Macro>, b: ReadonlyMap<string, Macro>): boolean {
	if (a.size !== b.size) return false;
	for (const [id, macro] of a) {
		const other = b.get(id);
		if (!other || JSON.stringify(other) !== JSON.stringify(macro)) return false;
	}
	return true;
}
