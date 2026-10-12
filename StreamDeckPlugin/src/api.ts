import { SseParser } from "./sse.js";
import { DEFAULT_HOST, DEFAULT_PORT } from "./settings.js";
import type { ActionDescriptor, ApiErrorBody, Health, Macro, RunAccepted, RunEvent, SwitchboardState } from "./types.js";

export { DEFAULT_HOST, DEFAULT_PORT };

export interface ApiClientOptions {
	host?: string;
	port?: number;
	/** Bearer token. Sent on every request except `GET /health`; omitted when empty. */
	token?: string;
	/** Timeout for the non-streaming requests. Default 5000 ms. */
	timeoutMs?: number;
	/** Injectable `fetch`, for tests. */
	fetch?: typeof fetch;
}

/**
 * The server answered with a status the contract does not treat as success for that call.
 * `status` and `code` (the body's `error` string) are the discriminators clients switch on:
 * 400 `missing parameter`, 401 `unauthorized`, 404 `unknown id`, 409 `busy`.
 */
export class ApiError extends Error {
	override readonly name = "ApiError";
	readonly status: number;
	readonly code: string;
	readonly body: unknown;

	constructor(status: number, body: unknown) {
		const code = isErrorBody(body) ? body.error : "";
		super(code ? `HTTP ${status}: ${code}${detail(body)}` : `HTTP ${status}`);
		this.status = status;
		this.code = code;
		this.body = body;
	}

	get isUnauthorized(): boolean {
		return this.status === 401;
	}

	get isNotFound(): boolean {
		return this.status === 404;
	}

	get isBusy(): boolean {
		return this.status === 409;
	}

	get isBadRequest(): boolean {
		return this.status === 400;
	}
}

/** The request never produced a response: app not running, wrong host or port, reset, timeout. */
export class ConnectionError extends Error {
	override readonly name = "ConnectionError";

	constructor(message: string, options?: { cause?: unknown }) {
		super(message, options);
	}
}

export interface EventsHandlers {
	onState(state: SwitchboardState): void;
	onRun?(run: RunEvent): void;
	/** A connection was established (status 200 and a body). */
	onOpen?(): void;
	/** A connection attempt failed or an established stream ended; a reconnect follows unless closed. */
	onClose?(reason: Error): void;
	/** A handler threw or an event carried data that is not JSON; the stream keeps going. */
	onError?(error: Error): void;
}

export interface BackoffPolicy {
	initialMs: number;
	maxMs: number;
	factor: number;
}

/** `docs/API.md`: reconnect with backoff starting at 1 s, capped at 30 s. */
export const DEFAULT_BACKOFF: BackoffPolicy = { initialMs: 1000, maxMs: 30_000, factor: 2 };

/** The delay to wait before the next reconnect, given the delay used for the previous one. */
export function nextBackoff(previousMs: number | undefined, policy: BackoffPolicy = DEFAULT_BACKOFF): number {
	if (previousMs === undefined) return Math.min(policy.initialMs, policy.maxMs);
	return Math.min(previousMs * policy.factor, policy.maxMs);
}

export interface EventsOptions {
	signal?: AbortSignal;
	backoff?: BackoffPolicy;
	/**
	 * Reconnect when nothing (events or keepalive comments) arrives for this long. The server sends a
	 * keepalive every 15 s; the default of 45 s tolerates two missed ones.
	 */
	idleTimeoutMs?: number;
}

export interface EventsSubscription {
	/** Stops the stream and any pending reconnect. Idempotent. */
	close(): void;
	/** Settles once the loop has exited after `close()` (or the external signal aborted). */
	readonly done: Promise<void>;
}

/**
 * Client for the Switchboard local API in `docs/API.md`. Talks to exactly one origin,
 * `http://{host}:{port}`, and nowhere else.
 */
export class ApiClient {
	readonly host: string;
	readonly port: number;
	readonly baseUrl: string;
	readonly #token: string;
	readonly #timeoutMs: number;
	readonly #fetch: typeof fetch;

	constructor(options: ApiClientOptions = {}) {
		this.host = options.host ?? DEFAULT_HOST;
		this.port = options.port ?? DEFAULT_PORT;
		this.#token = options.token ?? "";
		this.#timeoutMs = options.timeoutMs ?? 5000;
		this.#fetch = options.fetch ?? ((input, init) => fetch(input, init));
		const host = this.host.includes(":") && !this.host.startsWith("[") ? `[${this.host}]` : this.host;
		this.baseUrl = `http://${host}:${this.port}`;
	}

	/** `GET /health`, no authentication. */
	health(): Promise<Health> {
		return this.#request<Health>("GET", "/health", { auth: false });
	}

	/** `GET /state`. */
	state(): Promise<SwitchboardState> {
		return this.#request<SwitchboardState>("GET", "/state");
	}

	/** `GET /actions`, unwrapped. */
	async actions(): Promise<ActionDescriptor[]> {
		const body = await this.#request<{ actions?: ActionDescriptor[] }>("GET", "/actions");
		return Array.isArray(body.actions) ? body.actions : [];
	}

	/** `GET /macros`, unwrapped. */
	async macros(): Promise<Macro[]> {
		const body = await this.#request<{ macros?: Macro[] }>("GET", "/macros");
		return Array.isArray(body.macros) ? body.macros : [];
	}

	/**
	 * `POST /run/{id}`. Resolves only on `202 Accepted`; any other status throws an {@link ApiError}
	 * (400 missing parameter, 401, 404 unknown id, 409 busy), a network failure a {@link ConnectionError}.
	 * @param id Macro or action id.
	 * @param parameters Optional JSON body with the action's parameters (ignored by the server for macros).
	 */
	run(id: string, parameters?: Record<string, unknown>): Promise<RunAccepted> {
		if (typeof id !== "string" || id.trim() === "") {
			return Promise.reject(new TypeError("run() needs a macro or action id"));
		}
		return this.#request<RunAccepted>("POST", `/run/${encodeURIComponent(id.trim())}`, {
			body: parameters,
			expectStatus: 202,
		});
	}

	/**
	 * `GET /events`: a long-lived subscription that reconnects with backoff until closed. The server
	 * sends one `state` event on connect, then `state` on every change and `run` for run progress.
	 */
	events(handlers: EventsHandlers, options: EventsOptions = {}): EventsSubscription {
		const controller = new AbortController();
		const signal = options.signal ? AbortSignal.any([options.signal, controller.signal]) : controller.signal;
		const done = this.#eventsLoop(handlers, options, signal).catch(() => undefined);
		return {
			close: () => controller.abort(),
			done,
		};
	}

	async #request<T>(
		method: "GET" | "POST",
		path: string,
		options: { auth?: boolean; body?: unknown; expectStatus?: number } = {},
	): Promise<T> {
		const headers = this.#headers("application/json", options.auth !== false);
		const init: RequestInit = { method, headers, signal: AbortSignal.timeout(this.#timeoutMs) };
		if (options.body !== undefined) {
			headers["Content-Type"] = "application/json";
			init.body = JSON.stringify(options.body);
		}

		let response: Response;
		let body: unknown;
		try {
			response = await this.#fetch(new URL(path, this.baseUrl), init);
			body = await readBody(response);
		} catch (cause) {
			throw new ConnectionError(describeFailure(cause, this.baseUrl), { cause });
		}

		const ok = options.expectStatus !== undefined ? response.status === options.expectStatus : response.ok;
		if (!ok) throw new ApiError(response.status, body);
		return body as T;
	}

	#headers(accept: string, auth: boolean): Record<string, string> {
		const headers: Record<string, string> = { Accept: accept };
		if (auth && this.#token !== "") headers.Authorization = `Bearer ${this.#token}`;
		return headers;
	}

	async #eventsLoop(handlers: EventsHandlers, options: EventsOptions, signal: AbortSignal): Promise<void> {
		const policy = options.backoff ?? DEFAULT_BACKOFF;
		const idleTimeoutMs = options.idleTimeoutMs ?? 45_000;
		let delay: number | undefined;

		while (!signal.aborted) {
			try {
				await this.#consumeEvents(handlers, signal, idleTimeoutMs, () => {
					delay = undefined;
					handlers.onOpen?.();
				});
				if (signal.aborted) break;
				handlers.onClose?.(new ConnectionError("event stream ended"));
			} catch (error) {
				if (signal.aborted) break;
				handlers.onClose?.(toError(error));
			}
			delay = nextBackoff(delay, policy);
			await sleep(delay, signal);
		}
	}

	async #consumeEvents(
		handlers: EventsHandlers,
		signal: AbortSignal,
		idleTimeoutMs: number,
		onOpen: () => void,
	): Promise<void> {
		const attempt = new AbortController();
		const forwardAbort = (): void => attempt.abort(signal.reason);
		signal.addEventListener("abort", forwardAbort, { once: true });

		let idle: NodeJS.Timeout | undefined;
		const armIdle = (): void => {
			if (idle) clearTimeout(idle);
			idle = setTimeout(() => attempt.abort(new ConnectionError(`no data for ${idleTimeoutMs} ms`)), idleTimeoutMs);
		};

		// Why the abort reason is rethrown as is: the idle timer aborts with a ConnectionError that names
		// the cause, and close() aborts with the caller's reason; neither should be re-wrapped.
		const abortReason = (): Error | undefined =>
			attempt.signal.aborted && attempt.signal.reason instanceof Error ? attempt.signal.reason : undefined;

		try {
			// The timer also covers the connect phase: a server that accepts the socket but never sends
			// headers would otherwise hang this attempt forever.
			armIdle();
			let response: Response;
			try {
				response = await this.#fetch(new URL("/events", this.baseUrl), {
					method: "GET",
					headers: this.#headers("text/event-stream", true),
					signal: attempt.signal,
				});
			} catch (cause) {
				throw abortReason() ?? new ConnectionError(describeFailure(cause, this.baseUrl), { cause });
			}
			if (!response.ok) {
				let body: unknown;
				try {
					body = await readBody(response);
				} catch (cause) {
					throw abortReason() ?? new ConnectionError(describeFailure(cause, this.baseUrl), { cause });
				}
				throw new ApiError(response.status, body);
			}
			if (!response.body) throw new ConnectionError("event stream has no body");

			onOpen();
			const parser = new SseParser({
				onMessage: (message) => {
					try {
						if (message.event === "state") handlers.onState(parseJson(message.data) as SwitchboardState);
						else if (message.event === "run") handlers.onRun?.(parseJson(message.data) as RunEvent);
					} catch (error) {
						handlers.onError?.(toError(error));
					}
				},
			});

			armIdle();
			try {
				for await (const chunk of response.body) {
					armIdle();
					parser.feed(chunk);
				}
			} catch (error) {
				// Aborted on purpose (close(), idle timeout) or dropped: either way report the reason.
				throw abortReason() ?? error;
			} finally {
				parser.end();
			}
		} finally {
			if (idle) clearTimeout(idle);
			signal.removeEventListener("abort", forwardAbort);
		}
	}
}

function isErrorBody(body: unknown): body is ApiErrorBody {
	return typeof body === "object" && body !== null && typeof (body as ApiErrorBody).error === "string";
}

function detail(body: unknown): string {
	if (!isErrorBody(body)) return "";
	const extras = Object.entries(body)
		.filter(([key, value]) => key !== "error" && (typeof value === "string" || typeof value === "number"))
		.map(([key, value]) => `${key}=${String(value)}`);
	return extras.length ? ` (${extras.join(", ")})` : "";
}

async function readBody(response: Response): Promise<unknown> {
	const text = await response.text();
	if (text === "") return undefined;
	try {
		return JSON.parse(text);
	} catch {
		return text;
	}
}

function parseJson(text: string): unknown {
	try {
		return JSON.parse(text);
	} catch (error) {
		throw new SyntaxError(`event data is not JSON: ${error instanceof Error ? error.message : String(error)}`);
	}
}

function toError(value: unknown): Error {
	return value instanceof Error ? value : new Error(String(value));
}

function describeFailure(cause: unknown, baseUrl: string): string {
	const code = errorCode(cause);
	if (code === "ECONNREFUSED") return `nothing is listening at ${baseUrl}; is the Switchboard app running?`;
	if (cause instanceof Error && cause.name === "TimeoutError") return `${baseUrl} did not answer in time`;
	if (cause instanceof Error && cause.name === "AbortError") return `request to ${baseUrl} was aborted`;
	const message = cause instanceof Error ? (errorCode(cause) ?? cause.message) : String(cause);
	return `cannot reach ${baseUrl}: ${message}`;
}

function errorCode(error: unknown): string | undefined {
	let current: unknown = error;
	for (let depth = 0; depth < 4 && current instanceof Error; depth++) {
		const code = (current as Error & { code?: unknown }).code;
		if (typeof code === "string") return code;
		current = current.cause;
	}
	return undefined;
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
	return new Promise((resolve) => {
		if (signal.aborted) {
			resolve();
			return;
		}
		const finish = (): void => {
			clearTimeout(timer);
			signal.removeEventListener("abort", finish);
			resolve();
		};
		const timer = setTimeout(finish, ms);
		signal.addEventListener("abort", finish, { once: true });
	});
}
