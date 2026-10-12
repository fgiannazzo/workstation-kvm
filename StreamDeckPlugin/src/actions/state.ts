import streamDeck, {
	action,
	SingletonAction,
	type DidReceiveSettingsEvent,
	type KeyAction,
	type KeyDownEvent,
	type WillAppearEvent,
	type WillDisappearEvent,
} from "@elgato/streamdeck";

import { hub } from "../connection.js";
import { DEFAULT_FIELD, tileTitle } from "../state-format.js";
import type { SwitchboardState } from "../types.js";

/** Settings of one State tile. `labels` arrives as JSON text from the property inspector. */
export type StateSettings = {
	field?: string;
	labels?: string | Record<string, string>;
};

const logger = streamDeck.logger.createScope("state");

/**
 * Informational tile: shows one field of `SwitchboardState`, live from the shared `/events`
 * connection, mapped through optional labels. "?" while unknown or disconnected. Key down
 * re-reads `GET /state`.
 */
@action({ UUID: "io.github.fgiannazzo.switchboard.state" })
export class StateAction extends SingletonAction<StateSettings> {
	readonly #tiles = new Map<string, Tile>();

	override onWillAppear(ev: WillAppearEvent<StateSettings>): void {
		if (!ev.action.isKey()) return;
		const existing = this.#tiles.get(ev.action.id);
		if (existing) {
			existing.update(ev.payload.settings);
			return;
		}
		this.#tiles.set(ev.action.id, new Tile(ev.action, ev.payload.settings));
	}

	override onWillDisappear(ev: WillDisappearEvent<StateSettings>): void {
		this.#tiles.get(ev.action.id)?.dispose();
		this.#tiles.delete(ev.action.id);
	}

	override onDidReceiveSettings(ev: DidReceiveSettingsEvent<StateSettings>): void {
		this.#tiles.get(ev.action.id)?.update(ev.payload.settings);
	}

	override async onKeyDown(ev: KeyDownEvent<StateSettings>): Promise<void> {
		try {
			const state = await hub.refresh();
			const tile = this.#tiles.get(ev.action.id);
			if (tile) await tile.render(state, true);
			else await ev.action.setTitle(tileTitle({ state, connected: true, field: ev.payload.settings.field, labels: ev.payload.settings.labels }));
		} catch (error) {
			logger.warn(`State refresh failed: ${error instanceof Error ? error.message : String(error)}`);
			await ev.action.showAlert();
		}
	}
}

/** One visible tile: its key, its settings and its subscription to the hub. */
class Tile {
	readonly #key: KeyAction<StateSettings>;
	readonly #unsubscribe: () => void;
	#settings: StateSettings;
	#state: SwitchboardState | undefined;
	#connected = false;
	#lastTitle: string | undefined;

	constructor(key: KeyAction<StateSettings>, settings: StateSettings) {
		this.#key = key;
		this.#settings = settings;
		this.#unsubscribe = hub.subscribe({
			onConnection: (connected) => {
				this.#connected = connected;
				if (!connected) this.#state = undefined;
				void this.render(this.#state, connected);
			},
			onState: (state) => {
				this.#state = state;
				void this.render(state, this.#connected);
			},
		});
	}

	update(settings: StateSettings): void {
		this.#settings = settings;
		void this.render(this.#state, this.#connected);
	}

	async render(state: SwitchboardState | undefined, connected: boolean): Promise<void> {
		const title = tileTitle({
			state,
			connected,
			field: this.#settings.field ?? DEFAULT_FIELD,
			labels: this.#settings.labels,
		});
		if (title === this.#lastTitle) return;
		this.#lastTitle = title;
		try {
			await this.#key.setTitle(title);
		} catch (error) {
			logger.warn(`setTitle failed: ${error instanceof Error ? error.message : String(error)}`);
		}
	}

	dispose(): void {
		this.#unsubscribe();
	}
}
