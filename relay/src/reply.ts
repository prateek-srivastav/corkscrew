import { InvalidReport, text } from "./report";

/** What the app sends with Reply on its Reports page: `ReportReply` in GameCore (ReportReply.swift). */
export interface Reply {
	/** The issue the sender's report opened. */
	issue: number;
	/** The key the relay gave with that report. Reports from Corkscrew 1.0.2 and older have none. */
	key?: string;
	/** The sender's answer to the developer's note. */
	text: string;
	/** Launch logs the sender chose to attach: the start and the end of each. */
	logs: { name: string; text: string }[];
}

/** The longest fields the relay takes. The logs are limited by the request size. */
export const replyLimits = { text: 10_000, logs: 3, name: 200 };

/** The reply in `value`, checked against the app's format. Throws `InvalidReport`. */
export function parseReply(value: unknown): Reply {
	if (typeof value !== "object" || value === null || Array.isArray(value)) throw new InvalidReport("The reply isn't a JSON object.");
	const fields = value as Record<string, unknown>;

	const issue = fields.issue;
	if (typeof issue !== "number" || !Number.isSafeInteger(issue) || issue <= 0) throw new InvalidReport('"issue" must be an issue number.');

	const key = fields.key ?? undefined;
	if (key !== undefined && (typeof key !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(key))) throw new InvalidReport('"key" isn\'t a reply key.');

	const answer = text(fields, "text", replyLimits.text).trim();
	if (answer === "") throw new InvalidReport('"text" is empty.');

	const logs = fields.logs ?? [];
	if (!Array.isArray(logs) || logs.length > replyLimits.logs
		|| logs.some((log) => typeof log !== "object" || log === null || typeof log.name !== "string" || log.name.length > replyLimits.name
			|| typeof log.text !== "string")) {
		throw new InvalidReport(`"logs" must be a list of at most ${replyLimits.logs} logs, each with a name and a text.`);
	}
	return { issue, key, text: answer, logs: logs.map((log) => ({ name: log.name, text: log.text })) };
}

/** The key the relay gives with the issue a report opened: a keyed hash of the issue's number, so
 * the relay keeps nothing to check it, and only the Mac that sent the report has it. */
export async function replyKey(issue: number, secret: string): Promise<string> {
	const hmac = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	const mac = new Uint8Array(await crypto.subtle.sign("HMAC", hmac, new TextEncoder().encode(`reply-key|${issue}`)));
	return btoa(String.fromCharCode(...mac)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Whether `key` is the key for `issue`, compared in constant time. */
export async function isReplyKey(key: string, issue: number, secret: string): Promise<boolean> {
	const expected = new TextEncoder().encode(await replyKey(issue, secret));
	const given = new TextEncoder().encode(key);
	return given.byteLength === expected.byteLength && crypto.subtle.timingSafeEqual(given, expected);
}

/** The issue number in a link to it (`…/issues/42`). */
export function issueNumber(link: string): number | undefined {
	const match = /\/issues\/(\d+)$/.exec(link);
	return match === null ? undefined : Number(match[1]);
}

/** The public comment for a reply. The answer and the logs stay private. */
export function replyComment(reply: Reply, verified: boolean): string {
	const logs = reply.logs.length === 0 ? "" : `, with ${reply.logs.length} launch ${reply.logs.length === 1 ? "log" : "logs"}`;
	const parts = [`**The sender answered**${logs}, with Reply in Corkscrew. The answer is stored privately.`];
	if (!verified) {
		parts.push("It came without the report's key (Corkscrew 1.0.2 and older don't keep one), so it may not be from the person who sent the report.");
	}
	return parts.join("\n\n");
}
