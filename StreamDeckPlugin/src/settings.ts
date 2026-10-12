/**
 * Global plugin settings (shared by every key) and how they resolve to a connection.
 * The token is a secret: nothing in this module formats it into a string.
 */

export const DEFAULT_HOST = "127.0.0.1";
export const DEFAULT_PORT = 48600;

/** Shape persisted by Stream Deck. The property inspector writes strings for every field. */
export type GlobalSettings = {
	host?: string;
	port?: string | number;
	token?: string;
};

export interface ConnectionSettings {
	host: string;
	port: number;
	token: string;
}

/** Parses a TCP port from a number or numeric string; `undefined` when it is not one. */
export function parsePort(value: unknown): number | undefined {
	let port: number;
	if (typeof value === "number") {
		port = value;
	} else if (typeof value === "string" && /^\s*\d{1,5}\s*$/.test(value)) {
		port = Number(value.trim());
	} else {
		return undefined;
	}
	return Number.isInteger(port) && port >= 1 && port <= 65535 ? port : undefined;
}

/** Fills in the defaults from `docs/API.md` for anything missing or malformed. */
export function resolveConnection(settings: GlobalSettings | undefined): ConnectionSettings {
	const host = typeof settings?.host === "string" && settings.host.trim() !== "" ? settings.host.trim() : DEFAULT_HOST;
	const port = parsePort(settings?.port) ?? DEFAULT_PORT;
	const token = typeof settings?.token === "string" ? settings.token.trim() : "";
	return { host, port, token };
}

/** `host:port`, safe to log. */
export function describeConnection(connection: ConnectionSettings): string {
	return `${connection.host}:${connection.port}`;
}

/** True when both settings point at the same server with the same token. */
export function sameConnection(a: ConnectionSettings, b: ConnectionSettings): boolean {
	return a.host === b.host && a.port === b.port && a.token === b.token;
}
