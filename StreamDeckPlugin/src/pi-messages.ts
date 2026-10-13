import streamDeck from "@elgato/streamdeck";

import { ApiClient, ApiError } from "./api.js";
import { catalog, getClient } from "./connection.js";
import { describeConnection, resolveConnection, type GlobalSettings } from "./settings.js";

const logger = streamDeck.logger.createScope("ui");

/** Item shapes understood by `sdpi-select datasource="..."`. */
type DataSourceItem = { label: string; value: string; disabled?: boolean };
type DataSourceGroup = { label: string; children: DataSourceItem[] };

/** Messages the property inspectors send with `sendToPlugin`; the reply echoes `event`. */
export const PI_EVENTS = {
	/** `sdpi-select` datasource for the Run key: macros and actions from the app. */
	getIds: "getIds",
	/** The "Test connection" button: `/health`, then `/state` with the token. */
	testConnection: "testConnection",
} as const;

/** Routes messages from any of the plugin's property inspectors. */
export function registerPropertyInspectorHandlers(): void {
	streamDeck.ui.onSendToPlugin(async (ev) => {
		const payload = ev.payload;
		if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return;
		const event = payload.event;
		if (typeof event !== "string") return;

		try {
			switch (event) {
				case PI_EVENTS.getIds:
					await streamDeck.ui.sendToPropertyInspector({ event, items: await loadIdItems() });
					break;
				case PI_EVENTS.testConnection:
					await streamDeck.ui.sendToPropertyInspector({ event, ...(await testConnection()) });
					break;
				default:
					logger.debug(`Ignoring unknown property inspector message "${event}"`);
			}
		} catch (error) {
			logger.warn(`Property inspector request "${event}" failed: ${messageOf(error)}`);
		}
	});
}

async function loadIdItems(): Promise<(DataSourceItem | DataSourceGroup)[]> {
	const client = getClient();
	if (!client) {
		return [{ label: "Enter host, port and token under Connection", value: "", disabled: true }];
	}
	try {
		const [macros, actions] = await Promise.all([client.macros(), client.actions()]);
		catalog.update(macros);
		const groups: DataSourceGroup[] = [];
		if (macros.length) {
			groups.push({ label: "Macros", children: macros.map((m) => ({ label: `${m.name} (${m.id})`, value: m.id })) });
		}
		if (actions.length) {
			groups.push({ label: "Actions", children: actions.map((a) => ({ label: `${a.title} (${a.id})`, value: a.id })) });
		}
		return groups.length ? groups : [{ label: "The app has no macros or actions", value: "", disabled: true }];
	} catch (error) {
		logger.warn(`Could not list ids from ${client.baseUrl}: ${messageOf(error)}`);
		return [{ label: "Switchboard unreachable; start the app, then refresh", value: "", disabled: true }];
	}
}

async function testConnection(): Promise<{ ok: boolean; message: string }> {
	// Read fresh: the user may still be typing and the plugin's client lags the debounce.
	const connection = resolveConnection(await streamDeck.settings.getGlobalSettings<GlobalSettings>());
	const where = describeConnection(connection);
	const client = new ApiClient({ ...connection, timeoutMs: 3000 });

	let health;
	try {
		health = await client.health();
	} catch (error) {
		return { ok: false, message: `No Switchboard at ${where}: ${messageOf(error)}` };
	}
	const app = `${health.name} ${health.version}`;
	if (connection.token === "") return { ok: false, message: `${app} answers at ${where}, but no token is set` };

	try {
		const state = await client.state();
		const usb = state.usbPort ?? "?";
		const controller = state.controllerReachable ? "reachable" : "unreachable";
		return { ok: true, message: `${app}: token accepted. PBP ${state.pbp}, USB port ${usb}, controller ${controller}` };
	} catch (error) {
		if (error instanceof ApiError && error.isUnauthorized) {
			return { ok: false, message: `${app} rejected the token (401). Copy it again from the app or \`switchboardctl token\`` };
		}
		return { ok: false, message: `${app} answered /health but /state failed: ${messageOf(error)}` };
	}
}

function messageOf(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
