import streamDeck from "@elgato/streamdeck";

import { ApiClient } from "./api.js";
import { EventsHub } from "./events-hub.js";
import { describeConnection, resolveConnection, sameConnection, type ConnectionSettings, type GlobalSettings } from "./settings.js";

const logger = streamDeck.logger.createScope("connection");

/** The process-wide event stream shared by every tile and key. */
export const hub = new EventsHub(streamDeck.logger.createScope("events"));

let current: ConnectionSettings | undefined;
let client: ApiClient | undefined;

/** The client for the current global settings, or `undefined` until a token has been entered. */
export function getClient(): ApiClient | undefined {
	return client;
}

/**
 * Applies global settings from Stream Deck. Without a token there is no client: the tiles show "?"
 * and the keys alert, instead of hammering the API with requests that can only get 401.
 */
export function applyGlobalSettings(settings: GlobalSettings | undefined): void {
	const next = resolveConnection(settings);
	if (current && sameConnection(current, next)) return;
	current = next;

	if (next.token === "") {
		client = undefined;
		hub.setClient(undefined);
		logger.warn(`No token configured for ${describeConnection(next)}; open a Switchboard key's settings and paste the token from the app`);
		return;
	}

	client = new ApiClient(next);
	hub.setClient(client);
	logger.info(`Using the Switchboard API at ${describeConnection(next)}`);
}

/** Reads the global settings once and follows every later change made in a property inspector. */
export async function initConnection(): Promise<void> {
	streamDeck.settings.onDidReceiveGlobalSettings<GlobalSettings>((ev) => applyGlobalSettings(ev.settings));
	applyGlobalSettings(await streamDeck.settings.getGlobalSettings<GlobalSettings>());
}
