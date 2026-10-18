import { type Counter, network, senderName, windowAt } from "./counter";
import { issueFor, openIssue, reportLabels } from "./issue";
import { InvalidReport, parseReport } from "./report";
import { parseShare, shareIssue, shareLabels } from "./share";

export { Counter } from "./counter";

export interface Env {
	REPORTS: R2Bucket;
	COUNTERS: DurableObjectNamespace<Counter>;
	GITHUB_REPOSITORY: string;
	REPORTS_PER_HOUR: string;
	ISSUES_PER_DAY: string;
	/** Secrets. */
	GITHUB_TOKEN?: string;
	RATE_LIMIT_KEY?: string;
}

/** The largest report the relay takes, in bytes. */
export const maxBytes = 1 << 20;

const hour = 60 * 60 * 1000;
const day = 24 * hour;

/** What a path takes: the R2 folder it keeps them in, the issue's labels, and how to read one
 * (throws `InvalidReport`) into its kind and its issue. */
interface Route {
	folder: string;
	labels: string[];
	read(value: unknown): { kind: string; issue(id: string): { title: string; body: string } };
}

const routes = new Map<string, Route>([
	["/", {
		folder: "reports",
		labels: reportLabels,
		read(value) {
			const report = parseReport(value);
			return { kind: report.kind, issue: (id) => issueFor(report, id) };
		},
	}],
	["/settings", {
		folder: "settings",
		labels: shareLabels,
		read(value) {
			const share = parseShare(value);
			return { kind: "settings", issue: () => shareIssue(share) };
		},
	}],
]);

/**
 * POST / with a crash or error report as JSON (see `ProblemReport`), or POST /settings with the
 * settings a player shares (see `SettingsShare`). Both share the limits. Answers 201 `{"issue", "id"}`
 * when it opened an issue, or 202 `{"id"}` when it only kept the report (the daily limit, or GitHub
 * failed).
 */
export default {
	async fetch(request, env): Promise<Response> {
		const url = new URL(request.url);
		const route = routes.get(url.pathname);
		if (route === undefined) return answer(404, { error: "Not found." });
		if (request.method !== "POST") return answer(405, { error: "Use POST." }, { Allow: "POST" });
		if (!env.GITHUB_TOKEN || !env.RATE_LIMIT_KEY) return answer(503, { error: "The relay isn't set up yet." });
		if (!(request.headers.get("Content-Type") ?? "").toLowerCase().startsWith("application/json")) {
			return answer(415, { error: "Send the report as application/json." });
		}

		const body = await readBody(request, maxBytes);
		if (body === "tooLarge") return answer(413, { error: `The report is larger than ${maxBytes} bytes.` });
		let value: unknown;
		try {
			value = JSON.parse(body ?? "");
		} catch {
			return answer(400, { error: "The report isn't valid JSON." });
		}
		let report;
		try {
			report = route.read(value);
		} catch (error) {
			if (error instanceof InvalidReport) return answer(400, { error: error.message });
			throw error;
		}

		// The address is only hashed into the counter's name: never stored, never logged.
		const now = Date.now();
		const address = network(request.headers.get("CF-Connecting-IP") ?? "unknown");
		const sender = windowAt(now, hour);
		const counter = env.COUNTERS.get(env.COUNTERS.idFromName(await senderName(address, sender.window, env.RATE_LIMIT_KEY)));
		if (!(await counter.take(limit(env.REPORTS_PER_HOUR, 5), sender.until))) {
			return answer(429, { error: "Too many reports from this network. Try again later." }, {
				"Retry-After": String(Math.ceil((sender.until - now) / 1000)),
			});
		}

		const id = crypto.randomUUID();
		await env.REPORTS.put(`${route.folder}/${id}.json`, JSON.stringify({ id, received: new Date(now).toISOString(), report: value }, null, 2), {
			httpMetadata: { contentType: "application/json" },
			customMetadata: { kind: report.kind },
		});

		const today = windowAt(now, day);
		const issues = env.COUNTERS.get(env.COUNTERS.idFromName(`issues:${today.window}`));
		if (!(await issues.take(limit(env.ISSUES_PER_DAY, 50), today.until))) {
			console.warn(`Report ${id} kept without an issue: the daily limit is reached.`);
			return answer(202, { id });
		}
		try {
			const issue = await openIssue({ repository: env.GITHUB_REPOSITORY, token: env.GITHUB_TOKEN }, report.issue(id), route.labels);
			return answer(201, { issue, id });
		} catch (error) {
			console.error(`Report ${id} kept without an issue: ${error instanceof Error ? error.message : error}`);
			return answer(202, { id });
		}
	},
} satisfies ExportedHandler<Env>;

/** The request body as text; "tooLarge" past `max` bytes. Reads the stream, so a missing or wrong
 * Content-Length doesn't matter. Nil for a body that isn't UTF-8. */
async function readBody(request: Request, max: number): Promise<string | "tooLarge" | null> {
	if (Number(request.headers.get("Content-Length") ?? 0) > max) return "tooLarge";
	if (request.body === null) return "";
	const reader = request.body.getReader();
	const chunks: Uint8Array[] = [];
	let size = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		size += value.byteLength;
		if (size > max) {
			await reader.cancel();
			return "tooLarge";
		}
		chunks.push(value);
	}
	const bytes = new Uint8Array(size);
	let offset = 0;
	for (const chunk of chunks) {
		bytes.set(chunk, offset);
		offset += chunk.byteLength;
	}
	try {
		return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
	} catch {
		return null;
	}
}

function limit(value: string | undefined, fallback: number): number {
	const number = Number.parseInt(value ?? "", 10);
	return Number.isFinite(number) && number >= 0 ? number : fallback;
}

function answer(status: number, body: object, headers: Record<string, string> = {}): Response {
	return Response.json(body, { status, headers: { "Cache-Control": "no-store", ...headers } });
}
