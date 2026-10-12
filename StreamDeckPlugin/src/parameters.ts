/**
 * The Run key's optional `parameters` setting: JSON text for the request body of `POST /run/{id}`.
 * Returns `undefined` for an empty setting (no body is sent) and throws for anything that is not a
 * JSON object, so the key can show an alert instead of posting garbage.
 */
export function parseParameters(raw: string | undefined | null): Record<string, unknown> | undefined {
	if (raw === undefined || raw === null || raw.trim() === "") return undefined;
	let value: unknown;
	try {
		value = JSON.parse(raw);
	} catch (error) {
		throw new SyntaxError(`parameters is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		throw new TypeError("parameters must be a JSON object, for example {\"port\": 2}");
	}
	return value as Record<string, unknown>;
}
