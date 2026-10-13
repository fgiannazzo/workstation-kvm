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
import { normalizeLabels } from "../state-format.js";
import type { SwitchboardState } from "../types.js";
import { nextPort, parsePorts, usbKeyImage } from "../usb-toggle.js";
import { runOnKey } from "./run.js";

/** Settings of one USB toggle key: the ports it cycles through (`"1,2"`) and optional names (JSON text). */
export type UsbSettings = {
	ports?: string;
	labels?: string | Record<string, string>;
};

const logger = streamDeck.logger.createScope("usb");

/**
 * Key action: shows the active USB port large, on that port's colour, live from the event stream.
 * A press runs `usb.select` with the next port in the key's list.
 */
@action({ UUID: "io.github.fgiannazzo.switchboard.usb" })
export class UsbAction extends SingletonAction<UsbSettings> {
	readonly #keys = new Map<string, UsbKey>();

	override onWillAppear(ev: WillAppearEvent<UsbSettings>): void {
		if (!ev.action.isKey()) return;
		const existing = this.#keys.get(ev.action.id);
		if (existing) existing.update(ev.payload.settings);
		else this.#keys.set(ev.action.id, new UsbKey(ev.action, ev.payload.settings));
	}

	override onWillDisappear(ev: WillDisappearEvent<UsbSettings>): void {
		this.#keys.get(ev.action.id)?.dispose();
		this.#keys.delete(ev.action.id);
	}

	override onDidReceiveSettings(ev: DidReceiveSettingsEvent<UsbSettings>): void {
		this.#keys.get(ev.action.id)?.update(ev.payload.settings);
	}

	override async onKeyDown(ev: KeyDownEvent<UsbSettings>): Promise<void> {
		let current = hub.connected ? hub.state?.usbPort : undefined;
		if (current === undefined || current === null) {
			// Not on the stream yet: ask once so the first press does not pick the wrong "next".
			current = await hub.refresh().then(
				(state) => state.usbPort,
				() => undefined,
			);
		}
		const port = nextPort(current, parsePorts(ev.payload.settings.ports));
		await runOnKey(ev.action, "usb.select", { port });
	}
}

/** One visible USB toggle key: redraws its face when the port or its settings change. */
class UsbKey {
	readonly #key: KeyAction<UsbSettings>;
	readonly #unsubscribe: () => void;
	#settings: UsbSettings;
	#state: SwitchboardState | undefined;
	#shown: string | undefined;

	constructor(key: KeyAction<UsbSettings>, settings: UsbSettings) {
		this.#key = key;
		this.#settings = settings;
		this.#unsubscribe = hub.subscribe({
			onConnection: (connected) => {
				if (!connected) this.#state = undefined;
				this.render();
			},
			onState: (state) => {
				this.#state = state;
				this.render();
			},
		});
		this.render();
	}

	update(settings: UsbSettings): void {
		this.#settings = settings;
		this.render();
	}

	render(): void {
		const port = this.#state?.usbPort ?? undefined;
		const image = usbKeyImage({
			port,
			next: nextPort(port, parsePorts(this.#settings.ports)),
			labels: normalizeLabels(this.#settings.labels),
		});
		if (image === this.#shown) return;
		this.#shown = image;
		this.#key.setImage(image).catch((error: unknown) => {
			logger.warn(`setImage failed: ${error instanceof Error ? error.message : String(error)}`);
		});
	}

	dispose(): void {
		this.#unsubscribe();
	}
}
