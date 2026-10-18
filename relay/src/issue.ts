import type { Kind, ProblemReport } from "./report";

export const reportLabels = ["bug", "crash-report"];

/** Lines of the backtrace that go into the public issue; the rest stays in the stored report. */
export const backtraceLines = 60;
const backtraceCharacters = 6_000;

const kindNames: Record<Kind, string> = {
	crash: "Program crash",
	launchFailed: "Program didn't start",
	error: "Error in Corkscrew",
	appCrash: "Corkscrew crash",
};

/** The public issue for a report: what happened, the details and the start of the backtrace. The
 * note and the log stay private. Everything from the report is in code blocks, so it can't
 * mention people or render as Markdown. */
export function issueFor(report: ProblemReport, id: string): { title: string; body: string } {
	const parts = [`**${kindNames[report.kind]}**, reported ${new Date(report.date).toISOString()} with Send Report in Corkscrew.`];
	if (report.summary.trim() !== "") parts.push(codeBlock(report.summary.trim()));
	parts.push("### Details", codeBlock(report.details.join("\n")));
	if (report.backtrace !== undefined && report.backtrace.trim() !== "") {
		const { head, more } = backtraceStart(report.backtrace);
		parts.push("### Backtrace (the start)", codeBlock(head));
		if (more > 0) parts.push(`… ${more} more ${more === 1 ? "line" : "lines"} in the stored report.`);
	}
	const kept = [
		report.backtrace !== undefined && "the whole backtrace",
		report.log !== undefined && "the end of the log",
		report.note.trim() !== "" && "a note from the user",
	].filter((part): part is string => part !== false);
	parts.push(
		"---",
		`The full report${kept.length > 0 ? ` (${kept.join(", ")})` : ""} is stored privately under id \`${id}\`.`,
	);
	return { title: oneLine(report.title).slice(0, 256), body: parts.join("\n\n") };
}

/** The start of a backtrace, up to winedbg's module list (hundreds of lines that rarely help). */
export function backtraceStart(backtrace: string): { head: string; more: number } {
	const lines = backtrace.replace(/\s+$/, "").split(/\r?\n/);
	let end = lines.findIndex((line) => /^(Modules|Threads):/.test(line));
	if (end === -1) end = lines.length;
	end = Math.min(end, backtraceLines);
	let head = lines.slice(0, end).join("\n");
	if (head.length > backtraceCharacters) {
		head = head.slice(0, backtraceCharacters);
		end = head.split("\n").length;
	}
	return { head, more: lines.length - end };
}

/** A fenced code block that `content` can't close early. */
export function codeBlock(content: string): string {
	const longest = Math.max(0, ...(content.match(/`+/g) ?? []).map((run) => run.length));
	const fence = "`".repeat(Math.max(3, longest + 1));
	return `${fence}text\n${content}\n${fence}`;
}

export function oneLine(text: string): string {
	return text.replace(/[\u0000-\u001f\u007f]+/g, " ").trim();
}

export interface GitHub {
	repository: string;
	token: string;
}

/** Opens the issue with `labels` and returns its link. Throws when GitHub says no. */
export async function openIssue(github: GitHub, issue: { title: string; body: string }, labels: string[]): Promise<string> {
	const response = await fetch(`https://api.github.com/repos/${github.repository}/issues`, {
		method: "POST",
		headers: {
			Accept: "application/vnd.github+json",
			Authorization: `Bearer ${github.token}`,
			"Content-Type": "application/json",
			"User-Agent": "corkscrew-relay",
			"X-GitHub-Api-Version": "2022-11-28",
		},
		body: JSON.stringify({ ...issue, labels }),
		// Well inside the app's 30 seconds, so it hears that the report is kept.
		signal: AbortSignal.timeout(10_000),
	});
	if (!response.ok) throw new Error(`GitHub answered ${response.status}: ${(await response.text()).slice(0, 500)}`);
	const answer = (await response.json()) as { html_url?: unknown };
	if (typeof answer.html_url !== "string" || !answer.html_url.startsWith("https://github.com/")) {
		throw new Error("GitHub's answer has no issue link.");
	}
	return answer.html_url;
}
