import { codeBlock, oneLine } from "./issue";
import { InvalidReport, text } from "./report";

/** What the share sheet sends: `SettingsShare` in GameCore (TestedGames.swift), as JSON. */
export interface SettingsShare {
	/** The Steam game's name. */
	game: string;
	appID: string;
	result: (typeof results)[number];
	backend: (typeof backends)[number];
	/** In-game settings, resolution and frame rate, as the player writes them. */
	performance: string;
	/** What doesn't work, and what helped. */
	issues: string;
	/** The Game report's "Corkscrew settings" field: one JSON object with the app ID, the name and
	 * the shared profile (`Steam.settingsReport(of:)`). */
	settings: string;
	/** How long the game ran, without a crash, before the app asked. */
	minutes: number;
	version: string;
	mac: string;
	/** ISO 8601. */
	date: string;
}

/** The Game report's results and backends that a share can have. */
export const results = ["Plays well", "Plays, with issues"] as const;
export const backends = ["Automatic", "D3DMetal", "DXMT", "DXVK", "WineD3D"] as const;

export const shareLabels = ["game-report"];

/** The longest fields the relay takes. */
export const shareLimits = { game: 200, text: 2_000, settings: 4_000, line: 200 };

/** The share in `value`, checked against the app's format. Throws `InvalidReport`. */
export function parseShare(value: unknown): SettingsShare {
	if (typeof value !== "object" || value === null || Array.isArray(value)) throw new InvalidReport("The report isn't a JSON object.");
	const fields = value as Record<string, unknown>;

	const game = oneLine(text(fields, "game", shareLimits.game));
	if (game === "") throw new InvalidReport('"game" is empty.');
	const appID = text(fields, "appID", 10);
	if (!/^[0-9]{1,10}$/.test(appID)) throw new InvalidReport('"appID" must be a Steam app ID.');

	const minutes = fields.minutes;
	if (typeof minutes !== "number" || !Number.isSafeInteger(minutes) || minutes < 0) throw new InvalidReport('"minutes" must be a whole number.');
	const version = oneLine(text(fields, "version", shareLimits.line));
	const mac = oneLine(text(fields, "mac", shareLimits.line));
	if (version === "" || mac === "") throw new InvalidReport('"version" and "mac" must not be empty.');
	const date = text(fields, "date", 64);
	if (Number.isNaN(Date.parse(date))) throw new InvalidReport('"date" isn\'t an ISO 8601 date.');

	return {
		game,
		appID,
		result: oneOf(fields, "result", results),
		backend: oneOf(fields, "backend", backends),
		performance: fields.performance === undefined ? "" : text(fields, "performance", shareLimits.text),
		issues: fields.issues === undefined ? "" : text(fields, "issues", shareLimits.text),
		settings: settingsLine(text(fields, "settings", shareLimits.settings), appID),
		minutes,
		version,
		mac,
		date,
	};
}

/** The Game report (.github/ISSUE_TEMPLATE/game_report.yml) as GitHub writes a filled-in form: each
 * field is "### Label", a blank line and the value, or "_No response_". So `tested-settings.py`
 * reads it as it reads a report from the form. The player's text is in code blocks, so it can't
 * mention people or render as Markdown, and none of its lines starts with "#", so it can't add a
 * field. */
export function shareIssue(share: SettingsShare): { title: string; body: string } {
	const fields: [string, string][] = [
		["Game or program", block(share.game)],
		["Where it comes from", "Steam"],
		["Result", share.result],
		["Graphics backend", share.backend],
		["Settings and performance", block(share.performance)],
		["Corkscrew settings", `\`\`\`json\n${share.settings}\n\`\`\``],
		["Issues and workarounds", block(share.issues)],
		["Corkscrew version", block(share.version)],
		["Mac and macOS", block(share.mac)],
	];
	const played = share.minutes === 1 ? "1 minute" : `${share.minutes} minutes`;
	return {
		title: `${share.game}: ${share.result.toLowerCase()}`.slice(0, 256),
		body: [`**Shared from Corkscrew** after ${played} of play without a crash.`, ...fields.map(([label, value]) => `### ${label}\n\n${value}`)].join("\n\n"),
	};
}

/** The player's text in a code block, or "_No response_" when it's empty. */
function block(text: string): string {
	const trimmed = text.trim();
	return trimmed === "" ? "_No response_" : codeBlock(trimmed.replace(/^#/gm, " #"));
}

/** The settings, checked only as far as the issue needs: an object for this game. The script that
 * adds them to the tested list checks each setting. Written again as one line. */
function settingsLine(line: string, appID: string): string {
	let settings: unknown;
	try {
		settings = JSON.parse(line);
	} catch {
		throw new InvalidReport('"settings" isn\'t valid JSON.');
	}
	if (typeof settings !== "object" || settings === null || Array.isArray(settings)) throw new InvalidReport('"settings" isn\'t a JSON object.');
	const { appID: id, name, profile } = settings as Record<string, unknown>;
	if (id !== appID) throw new InvalidReport('"settings" is for another app ID.');
	if (typeof name !== "string" || name.trim() === "") throw new InvalidReport('"settings" has no name.');
	if (typeof profile !== "object" || profile === null || Array.isArray(profile)) throw new InvalidReport('"settings" has no profile.');
	// A backtick can only be in a string, where ` reads the same: the ```json block can't close early.
	return JSON.stringify(settings).replaceAll("`", "\\u0060");
}

function oneOf<T extends string>(fields: Record<string, unknown>, name: string, values: readonly T[]): T {
	const value = fields[name];
	if (typeof value !== "string" || !(values as readonly string[]).includes(value)) throw new InvalidReport(`"${name}" must be one of ${values.join(", ")}.`);
	return value as T;
}
