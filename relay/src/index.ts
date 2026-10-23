import { type Counter, network, senderName, windowAt } from "./counter";
import { linkReport, maxPingBytes, parseDevice, pingsPerHour, prune, saveDevice } from "./device";
import { commentOnIssue, issueFor, isOpenReportIssue, openIssue, reportLabels } from "./issue";
import { InvalidReport, maxBytes, parseReport } from "./report";
import { isReplyKey, issueNumber, parseReply, replyComment, replyKey } from "./reply";
import { parseShare, shareIssue, shareLabels } from "./share";
import { type GitHubApp, installationToken } from "./token";

export { Counter } from "./counter";

export interface Env {
	REPORTS: R2Bucket;
	/** Macs (from /device) and which Mac sent each report: migrations/. */
	DB: D1Database;
	COUNTERS: DurableObjectNamespace<Counter>;
	GITHUB_REPOSITORY: string;
	REPORTS_PER_HOUR: string;
	ISSUES_PER_DAY: string;
	/** Secrets. The relay opens issues as the GitHub App when its three are set, else with the token. */
	GITHUB_APP_ID?: string;
	GITHUB_APP_INSTALLATION_ID?: string;
	GITHUB_APP_PRIVATE_KEY?: string;
	GITHUB_TOKEN?: string;
	RATE_LIMIT_KEY?: string;
}

const hour = 60 * 60 * 1000;
const day = 24 * hour;

/** What a path takes: the R2 folder it keeps them in, the issue's labels, and how to read one
 * (throws `InvalidReport`) into its kind and its issue. */
interface Route {
	folder: string;
	labels: string[];
	/** The answer gives the issue's reply key (POST /reply). */
	repliable?: boolean;
	read(value: unknown): { kind: string; device?: string; issue(): { title: string; body: string } };
}

const routes = new Map<string, Route>([
	["/", {
		folder: "reports",
		labels: reportLabels,
		repliable: true,
		read(value) {
			const report = parseReport(value);
			return { kind: report.kind, device: report.device, issue: () => issueFor(report) };
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
 * failed). A report's 201 also has `"key"`, which lets its sender answer on the issue with POST /reply
 * (see `reply`). POST /device with a Mac's ID and details (see `DevicePing`) answers 204.
 */
export default {
	async fetch(request, env): Promise<Response> {
		const url = new URL(request.url);
		const route = routes.get(url.pathname);
		if (route === undefined && url.pathname !== "/device" && url.pathname !== "/reply") return answer(404, { error: "Not found." });
		if (request.method !== "POST") return answer(405, { error: "Use POST." }, { Allow: "POST" });
		if (url.pathname === "/reply") return reply(request, env);
		if (route === undefined) return device(request, env);
		const app = gitHubApp(env);
		if ((app === undefined && !env.GITHUB_TOKEN) || !env.RATE_LIMIT_KEY) return answer(503, { error: "The relay isn't set up yet." });
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
		const received = new Date(now);
		// The device ID stays in R2 and D1: the issue is made from the parsed report, without it.
		const link = async (issue?: string) => {
			if (report.device === undefined) return;
			try {
				await linkReport(env.DB, { id, issue, device: report.device, received });
			} catch (error) {
				console.error(`Report ${id} kept without its device link: ${error instanceof Error ? error.message : error}`);
			}
		};
		await env.REPORTS.put(`${route.folder}/${id}.json`, JSON.stringify({ id, received: new Date(now).toISOString(), report: value }, null, 2), {
			httpMetadata: { contentType: "application/json" },
			customMetadata: { kind: report.kind },
		});

		const today = windowAt(now, day);
		const issues = env.COUNTERS.get(env.COUNTERS.idFromName(`issues:${today.window}`));
		if (!(await issues.take(limit(env.ISSUES_PER_DAY, 50), today.until))) {
			console.warn(`Report ${id} kept without an issue: the daily limit is reached.`);
			await link();
			return answer(202, { id });
		}
		try {
			const token = app !== undefined ? await installationToken(app) : env.GITHUB_TOKEN!;
			const issue = await openIssue({ repository: env.GITHUB_REPOSITORY, token }, report.issue(), route.labels);
			await link(issue);
			const number = issueNumber(issue);
			if (number !== undefined) await pointTo(env, number, `${route.folder}/${id}.json`, "kept");
			if (route.repliable && number !== undefined) return answer(201, { issue, id, key: await replyKey(number, env.RATE_LIMIT_KEY) });
			return answer(201, { issue, id });
		} catch (error) {
			console.error(`Report ${id} kept without an issue: ${error instanceof Error ? error.message : error}`);
			await link();
			return answer(202, { id });
		}
	},

	/** Daily (wrangler.toml's cron): deletes Macs and report links past `keptDays`. */
	async scheduled(_controller, env): Promise<void> {
		await prune(env.DB, new Date());
	},
} satisfies ExportedHandler<Env>;

/** POST /device: keeps the Mac's ID and details, with the country Cloudflare reads from the
 * connection. Needs no GitHub secrets; has its own hourly limit per network. */
async function device(request: Request, env: Env): Promise<Response> {
	if (!env.RATE_LIMIT_KEY) return answer(503, { error: "The relay isn't set up yet." });
	if (!(request.headers.get("Content-Type") ?? "").toLowerCase().startsWith("application/json")) {
		return answer(415, { error: "Send the ping as application/json." });
	}
	const body = await readBody(request, maxPingBytes);
	if (body === "tooLarge") return answer(413, { error: `The ping is larger than ${maxPingBytes} bytes.` });
	let ping;
	try {
		ping = parseDevice(JSON.parse(body ?? ""));
	} catch (error) {
		if (error instanceof InvalidReport) return answer(400, { error: error.message });
		if (error instanceof SyntaxError) return answer(400, { error: "The ping isn't valid JSON." });
		throw error;
	}

	const now = Date.now();
	const address = network(request.headers.get("CF-Connecting-IP") ?? "unknown");
	const sender = windowAt(now, hour);
	const counter = env.COUNTERS.get(env.COUNTERS.idFromName(await senderName(`device|${address}`, sender.window, env.RATE_LIMIT_KEY)));
	if (!(await counter.take(pingsPerHour, sender.until))) {
		return answer(429, { error: "Too many pings from this network. Try again later." }, {
			"Retry-After": String(Math.ceil((sender.until - now) / 1000)),
		});
	}
	const country = (request.cf as IncomingRequestCfProperties | undefined)?.country;
	await saveDevice(env.DB, ping, typeof country === "string" ? country : undefined, new Date(now));
	return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
}

/**
 * POST /reply: the sender's answer to the developer's note, with launch logs if they chose. The
 * answer and the logs are kept privately in R2 (`replies/<issue>/<id>.json`), and a comment on the issue
 * says there is one. Only an open issue with the `crash-report` label takes replies. A reply with
 * the report's key is checked; one without (reports from 1.0.2 and older) is taken but marked as
 * unchecked. Shares the hourly limit with reports, and the daily limit with issues. Answers 201
 * `{"id"}` with the comment, 202 `{"id"}` when only kept, 403 for a wrong key, 404 for an issue
 * that takes no replies.
 */
async function reply(request: Request, env: Env): Promise<Response> {
	const app = gitHubApp(env);
	if ((app === undefined && !env.GITHUB_TOKEN) || !env.RATE_LIMIT_KEY) return answer(503, { error: "The relay isn't set up yet." });
	if (!(request.headers.get("Content-Type") ?? "").toLowerCase().startsWith("application/json")) {
		return answer(415, { error: "Send the reply as application/json." });
	}
	const body = await readBody(request, maxBytes);
	if (body === "tooLarge") return answer(413, { error: `The reply is larger than ${maxBytes} bytes.` });
	let value;
	try {
		value = parseReply(JSON.parse(body ?? ""));
	} catch (error) {
		if (error instanceof InvalidReport) return answer(400, { error: error.message });
		if (error instanceof SyntaxError) return answer(400, { error: "The reply isn't valid JSON." });
		throw error;
	}
	const verified = value.key !== undefined;
	if (value.key !== undefined && !(await isReplyKey(value.key, value.issue, env.RATE_LIMIT_KEY))) {
		return answer(403, { error: "The key isn't this issue's." });
	}

	const now = Date.now();
	const address = network(request.headers.get("CF-Connecting-IP") ?? "unknown");
	const sender = windowAt(now, hour);
	const counter = env.COUNTERS.get(env.COUNTERS.idFromName(await senderName(address, sender.window, env.RATE_LIMIT_KEY)));
	if (!(await counter.take(limit(env.REPORTS_PER_HOUR, 5), sender.until))) {
		return answer(429, { error: "Too many reports from this network. Try again later." }, {
			"Retry-After": String(Math.ceil((sender.until - now) / 1000)),
		});
	}

	let github;
	try {
		github = { repository: env.GITHUB_REPOSITORY, token: app !== undefined ? await installationToken(app) : env.GITHUB_TOKEN! };
		if (!(await isOpenReportIssue(github, value.issue))) return answer(404, { error: "That issue takes no replies." });
	} catch (error) {
		// GitHub can't say: the reply is kept, so the sender's answer isn't lost.
		console.error(`Couldn't check issue ${value.issue}: ${error instanceof Error ? error.message : error}`);
		github = undefined;
	}

	const id = crypto.randomUUID();
	await env.REPORTS.put(`replies/${value.issue}/${id}.json`, JSON.stringify({ id, received: new Date(now).toISOString(), issue: value.issue, verified, reply: value }, null, 2), {
		httpMetadata: { contentType: "application/json" },
		customMetadata: { issue: String(value.issue), verified: String(verified) },
	});
	await pointTo(env, value.issue, `replies/${value.issue}/${id}.json`, "replies");
	if (github === undefined) return answer(202, { id });

	const today = windowAt(now, day);
	const issues = env.COUNTERS.get(env.COUNTERS.idFromName(`issues:${today.window}`));
	if (!(await issues.take(limit(env.ISSUES_PER_DAY, 50), today.until))) {
		console.warn(`Reply ${id} kept without a comment: the daily limit is reached.`);
		return answer(202, { id });
	}
	try {
		await commentOnIssue(github, value.issue, replyComment(value, verified));
		return answer(201, { id });
	} catch (error) {
		console.error(`Reply ${id} kept without a comment: ${error instanceof Error ? error.message : error}`);
		return answer(202, { id });
	}
}

/** Keeps `issues/<number>.json` with the R2 keys of the issue's private copies: `kept` for the report
 * or the shared settings, `replies` for the sender's answers. The public issue names neither, so the
 * maintainer finds them by the issue's number. */
async function pointTo(env: Env, issue: number, key: string, as: "kept" | "replies"): Promise<void> {
	const name = `issues/${issue}.json`;
	try {
		const link: { issue: number; kept?: string; replies?: string[] } = (await (await env.REPORTS.get(name))?.json()) ?? { issue };
		if (as === "kept") link.kept = key;
		else link.replies = [...(link.replies ?? []), key];
		await env.REPORTS.put(name, JSON.stringify(link), { httpMetadata: { contentType: "application/json" } });
	} catch (error) {
		console.error(`Issue ${issue} has no link to ${key}: ${error instanceof Error ? error.message : error}`);
	}
}

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

function gitHubApp(env: Env): GitHubApp | undefined {
	if (!env.GITHUB_APP_ID || !env.GITHUB_APP_INSTALLATION_ID || !env.GITHUB_APP_PRIVATE_KEY) return undefined;
	return { id: env.GITHUB_APP_ID, installation: env.GITHUB_APP_INSTALLATION_ID, privateKey: env.GITHUB_APP_PRIVATE_KEY };
}

function limit(value: string | undefined, fallback: number): number {
	const number = Number.parseInt(value ?? "", 10);
	return Number.isFinite(number) && number >= 0 ? number : fallback;
}

function answer(status: number, body: object, headers: Record<string, string> = {}): Response {
	return Response.json(body, { status, headers: { "Cache-Control": "no-store", ...headers } });
}
