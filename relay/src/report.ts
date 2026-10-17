/** What the app sends: `ProblemReport` in GameCore (ProblemReport.swift), as JSON. */
export interface ProblemReport {
	kind: Kind;
	title: string;
	/** One line: Wine's "Unhandled …" line, or the error message. */
	summary: string;
	/** "Name: value" lines: Corkscrew and the Mac, then the program and its settings. */
	details: string[];
	backtrace?: string;
	/** The end of the program's log. */
	log?: string;
	/** What the user was doing, if they say. */
	note: string;
	/** ISO 8601. */
	date: string;
}

export const kinds = ["crash", "launchFailed", "error", "appCrash"] as const;
export type Kind = (typeof kinds)[number];

/** The longest fields the relay takes. The backtrace and log are limited by the request size. */
export const limits = { title: 256, summary: 4_000, details: 200, detail: 2_000, note: 10_000 };

export class InvalidReport extends Error {}

/** The report in `value`, checked against the app's format. Throws `InvalidReport`. */
export function parseReport(value: unknown): ProblemReport {
	if (typeof value !== "object" || value === null || Array.isArray(value)) throw new InvalidReport("The report isn't a JSON object.");
	const fields = value as Record<string, unknown>;

	const kind = fields.kind;
	if (typeof kind !== "string" || !(kinds as readonly string[]).includes(kind)) throw new InvalidReport(`"kind" must be one of ${kinds.join(", ")}.`);

	const title = text(fields, "title", limits.title).trim();
	if (title === "") throw new InvalidReport('"title" is empty.');
	const summary = text(fields, "summary", limits.summary);

	const details = fields.details;
	if (!Array.isArray(details) || details.length > limits.details || details.some((line) => typeof line !== "string" || line.length > limits.detail)) {
		throw new InvalidReport(`"details" must be a list of at most ${limits.details} strings of at most ${limits.detail} characters.`);
	}

	const date = text(fields, "date", 64);
	if (Number.isNaN(Date.parse(date))) throw new InvalidReport('"date" isn\'t an ISO 8601 date.');

	return {
		kind: kind as Kind,
		title,
		summary,
		details,
		backtrace: optionalText(fields, "backtrace"),
		log: optionalText(fields, "log"),
		note: fields.note === undefined ? "" : text(fields, "note", limits.note),
		date,
	};
}

function text(fields: Record<string, unknown>, name: string, limit: number): string {
	const value = fields[name];
	if (typeof value !== "string") throw new InvalidReport(`"${name}" must be a string.`);
	if (value.length > limit) throw new InvalidReport(`"${name}" is longer than ${limit} characters.`);
	return value;
}

/** Swift leaves out nil fields; null is fine too. */
function optionalText(fields: Record<string, unknown>, name: string): string | undefined {
	const value = fields[name];
	if (value === undefined || value === null) return undefined;
	if (typeof value !== "string") throw new InvalidReport(`"${name}" must be a string.`);
	return value;
}
