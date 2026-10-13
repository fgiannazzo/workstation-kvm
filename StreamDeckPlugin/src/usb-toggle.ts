/**
 * Pure parts of the USB toggle key: which ports it cycles through, which port a press selects, and
 * the key face that shows the active port at a glance.
 */

export const DEFAULT_PORTS: readonly number[] = [1, 2];

/** One colour per port so the active port reads at a glance; white text stays legible on each. */
export const PORT_COLORS: Readonly<Record<number, string>> = {
	1: "#1d5fd1",
	2: "#c2410c",
	3: "#7e22ce",
	4: "#0f766e",
};

/** Background while the port is unknown or the plugin is not connected. */
export const UNKNOWN_COLOR = "#3a3a3c";

/**
 * The `ports` setting: ports 1 to 4 separated by commas or spaces (`"1,2"`, `"1 3 4"`), duplicates
 * dropped, order kept. Empty or invalid text falls back to {@link DEFAULT_PORTS}.
 */
export function parsePorts(raw: unknown): number[] {
	const items = Array.isArray(raw) ? raw : typeof raw === "string" ? raw.split(/[\s,;]+/) : [];
	const ports: number[] = [];
	for (const item of items) {
		const port = typeof item === "number" ? item : typeof item === "string" && /^\d+$/.test(item) ? Number(item) : NaN;
		if (Number.isInteger(port) && port >= 1 && port <= 4 && !ports.includes(port)) ports.push(port);
	}
	return ports.length > 0 ? ports : [...DEFAULT_PORTS];
}

/** The port after `current` in `ports`, wrapping around; the first port when `current` is unknown or not listed. */
export function nextPort(current: number | null | undefined, ports: readonly number[]): number {
	const list = ports.length > 0 ? ports : DEFAULT_PORTS;
	const index = current === null || current === undefined ? -1 : list.indexOf(current);
	return list[(index + 1) % list.length]!;
}

export interface UsbFace {
	/** The active port, or `undefined` when unknown or disconnected. */
	port: number | undefined;
	/** The port a press selects. */
	next: number;
	labels?: Record<string, string> | undefined;
}

/** The key face as an SVG document: "USB" on top, the active port (or its label) large, "next N" below. */
export function usbKeySvg({ port, next, labels }: UsbFace): string {
	const name = (p: number): string => labels?.[String(p)] ?? String(p);
	const big = port === undefined ? "?" : name(port);
	const background = port === undefined ? UNKNOWN_COLOR : (PORT_COLORS[port] ?? UNKNOWN_COLOR);
	const size = big.length <= 2 ? 72 : big.length <= 4 ? 46 : big.length <= 6 ? 34 : 26;
	const font = `font-family="Helvetica Neue, Helvetica, Arial, sans-serif" fill="#ffffff" text-anchor="middle"`;
	return (
		`<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">` +
		`<rect width="144" height="144" fill="${background}"/>` +
		`<text x="72" y="34" ${font} font-size="24" font-weight="600" fill-opacity="0.85">USB</text>` +
		`<text x="72" y="${Math.round(80 + size * 0.36)}" ${font} font-size="${size}" font-weight="700">${escapeXml(big)}</text>` +
		`<text x="72" y="130" ${font} font-size="20" fill-opacity="0.8">next ${escapeXml(name(next))}</text>` +
		`</svg>`
	);
}

/** `usbKeySvg` as a data URL for `setImage`. */
export function usbKeyImage(face: UsbFace): string {
	return `data:image/svg+xml;base64,${Buffer.from(usbKeySvg(face), "utf8").toString("base64")}`;
}

function escapeXml(text: string): string {
	return text.replace(/[<>&"']/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&apos;" })[c]!);
}
