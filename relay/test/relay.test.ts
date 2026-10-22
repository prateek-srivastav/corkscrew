import { reset } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { network, senderName } from "../src/counter";
import worker, { type Env, maxBytes } from "../src/index";
import { backtraceLines, backtraceStart, codeBlock, issueFor } from "../src/issue";
import { parseReport } from "../src/report";
import { parseShare, shareIssue } from "../src/share";

/** A winedbg block, as `ProblemReport.crash(in:)` cuts it from a launch log. */
const backtrace = `wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001234 (thread 0024), starting debugger...
Unhandled exception: page fault on read access to 0x0000000000000000 in 64-bit code (0x0000000140001234).
Register dump:
 rip:0000000140001234 rsp:000000000011fe00 rbp:000000000011fe50 eflags:00010246 (  R- --  I  Z- -P- )
 rax:0000000000000000 rbx:0000000000000001 rcx:0000000000000000 rdx:0000000000000000
Stack dump:
0x000000000011fe00:  0000000000000000 0000000000000000
Backtrace:
=>0 0x0000000140001234 in example (+0x1234) (0x000000000011fe50)
  1 0x000000014000130a in example (+0x130a) (0x000000000011fe80)
  2 0x000000007b62c0b9 in kernel32 (+0x1c0b9) (0x000000000011fec0)
0x0000000140001234 example+0x1234: movl $0x2a,0x0(%rax)
Modules:
Module	Address			Debug info	Name (3 modules)
PE	0000000140000000-0000000140010000	Deferred        example
PE	000000007b600000-000000007b800000	Deferred        kernel32
PE	0000000170000000-0000000170200000	Deferred        ntdll
Threads:
process  tid      prio    name (all IDs are in hex)
00000020 example.exe
System information:
    Wine build: wine-11.0
    Platform: x86_64
    Version: Windows 10
    Host system: Darwin
    Host version: 27.0.0`;

const report = {
	kind: "crash",
	title: "Example crashed",
	summary: "wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001234 (thread 0024), starting debugger...",
	details: ["Corkscrew: 0.7.0", "Mac: MacBook Pro (M4, 16 GB)", "macOS: 27.0", "Program: Example", "Bottle: Offline Programs", "Backend: D3DMetal"],
	backtrace,
	log: "0024:fixme:dxgi:example_log_line_only_in_r2\nlast log line",
	note: "I pressed Play, then it quit. Thanks @someone",
	date: "2026-10-18T09:15:00Z",
};

/** What the share sheet sends: `SettingsShare` with `Steam.settingsReport(of:)` as its settings. */
const share = {
	game: "Untested Game",
	appID: "999999",
	result: "Plays well",
	backend: "DXMT",
	performance: "1440p High, 60 fps",
	issues: "",
	settings: '{"appID":"999999","name":"Untested Game","profile":{"advertiseAVX":true,"backendOverride":"dxmt","metalFX":true,"retinaMode":false,"steamOverlay":false}}',
	minutes: 47,
	version: "0.8.0 (11)",
	mac: "26.1, Mac16,1, Apple M4, 16 GB",
	date: "2026-10-18T09:15:00Z",
};

const issueLink = "https://github.com/Prateek-Srivastav/corkscrew/issues/42";

interface Sent {
	url: string;
	method: string;
	headers: Headers;
	body: { title: string; body: string; labels: string[] };
}

let github: Sent[];
let gitHubAnswer: () => Response;
/** The GitHub App's token requests, apart from the issues. */
let tokenRequests: Request[];
let tokenAnswer: () => Response;

beforeEach(() => {
	github = [];
	gitHubAnswer = () => Response.json({ html_url: issueLink, number: 42 }, { status: 201 });
	tokenRequests = [];
	tokenAnswer = () => Response.json({ token: "installation-token", expires_at: "2026-10-18T10:15:00Z" }, { status: 201 });
	// The Worker runs in the tests' isolate, so this replaces its fetch too.
	vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
		const request = new Request(input, init);
		if (request.url.endsWith("/access_tokens")) {
			tokenRequests.push(request);
			return tokenAnswer();
		}
		github.push({ url: request.url, method: request.method, headers: request.headers, body: await request.json() });
		return gitHubAnswer();
	});
});

afterEach(async () => {
	vi.restoreAllMocks();
	await reset();
});

let nextAddress = 1;

/** Posts `body` to the relay as the app does, each time from a new address unless one is given. */
function send(
	body: unknown,
	options: { address?: string; headers?: Record<string, string>; method?: string; path?: string; environment?: Env } = {},
): Promise<Response> {
	const method = options.method ?? "POST";
	const request = new Request<unknown, IncomingRequestCfProperties>(`https://relay.example${options.path ?? "/"}`, {
		method,
		headers: { "Content-Type": "application/json", "CF-Connecting-IP": options.address ?? `203.0.113.${nextAddress++}`, ...options.headers },
		body: method === "GET" ? undefined : typeof body === "string" || body instanceof ReadableStream || body instanceof Uint8Array ? body : JSON.stringify(body),
	});
	return worker.fetch(request, options.environment ?? env);
}

async function stored(): Promise<string[]> {
	return (await env.REPORTS.list()).objects.map((object) => object.key);
}

describe("a report", () => {
	it("is kept whole in R2, and opens an issue with a summary", async () => {
		const response = await send(report, { address: "198.51.100.23" });
		expect(response.status).toBe(201);
		const answer = await response.json<{ issue: string; id: string }>();
		expect(answer.issue).toBe(issueLink);
		expect(answer.id).toMatch(/^[0-9a-f-]{36}$/);

		const object = await env.REPORTS.get(`reports/${answer.id}.json`);
		expect(object?.httpMetadata?.contentType).toBe("application/json");
		const text = await object!.text();
		const saved = JSON.parse(text);
		expect(saved.id).toBe(answer.id);
		expect(saved.report).toEqual(report);
		expect(text).not.toContain("198.51.100.23");

		expect(github).toHaveLength(1);
		const [issue] = github;
		expect(issue.method).toBe("POST");
		expect(issue.url).toBe("https://api.github.com/repos/Prateek-Srivastav/corkscrew/issues");
		expect(issue.headers.get("Authorization")).toBe("Bearer test-token");
		expect(issue.headers.get("User-Agent")).toBe("corkscrew-relay");
		expect(issue.body.title).toBe("Example crashed");
		expect(issue.body.labels).toEqual(["bug", "crash-report"]);
		const body = issue.body.body;
		expect(body).toContain(report.summary);
		for (const detail of report.details) expect(body).toContain(detail);
		expect(body).toContain("=>0 0x0000000140001234 in example (+0x1234)");
		expect(body).toContain("14 more lines in the stored report.");
		expect(body).toContain(`is stored privately under id \`${answer.id}\``);
		expect(body).toContain("the whole backtrace, the end of the log, a note from the user");
		// The module list, the log and the note stay private.
		expect(body).not.toContain("Deferred        kernel32");
		expect(body).not.toContain("example_log_line_only_in_r2");
		expect(body).not.toContain("I pressed Play");
		expect(body).not.toContain("198.51.100.23");
	});

	it("needs no backtrace, log or note", async () => {
		const { backtrace: _, log: __, note: ___, ...error } = { ...report, kind: "error", title: "Couldn't add the program" };
		const response = await send({ ...error, backtrace: null });
		expect(response.status).toBe(201);
		const { body } = github[0].body;
		expect(body).not.toContain("### Backtrace");
		expect(body).toContain("**Error in Corkscrew**");
		expect(body).toContain("The full report is stored privately under id");
	});

	it("is read as Swift's JSONEncoder writes it", async () => {
		// Swift escapes "/" and has no fractional seconds in .iso8601 dates.
		const json = String.raw`{"kind":"appCrash","title":"Corkscrew quit unexpectedly","summary":"EXC_BAD_ACCESS (SIGSEGV)","details":["Corkscrew: 0.7.0","Data: ~\/Library\/Application Support\/Corkscrew"],"backtrace":"0  Corkscrew  main + 12","note":"","date":"2026-10-18T09:15:00Z"}`;
		const response = await send(json);
		expect(response.status).toBe(201);
		expect(github[0].body.body).toContain("Data: ~/Library/Application Support/Corkscrew");
		expect(github[0].body.body).toContain("**Corkscrew crash**");
	});

	it("is kept without an issue when GitHub fails", async () => {
		gitHubAnswer = () => new Response('{"message":"Bad credentials"}', { status: 401 });
		const response = await send(report);
		expect(response.status).toBe(202);
		const answer = await response.json<{ issue?: string; id: string }>();
		expect(answer.issue).toBeUndefined();
		expect(await stored()).toEqual([`reports/${answer.id}.json`]);
	});
});

describe("shared settings", () => {
	it("are kept in R2, and open a Game report as the form writes one", async () => {
		const response = await send(share, { path: "/settings" });
		expect(response.status).toBe(201);
		const answer = await response.json<{ issue: string; id: string }>();
		expect(answer.issue).toBe(issueLink);
		expect(await stored()).toEqual([`settings/${answer.id}.json`]);
		expect(JSON.parse(await (await env.REPORTS.get(`settings/${answer.id}.json`))!.text()).report).toEqual(share);

		expect(github).toHaveLength(1);
		expect(github[0].body.title).toBe("Untested Game: plays well");
		expect(github[0].body.labels).toEqual(["game-report"]);
		expect(github[0].body.body).toBe(`**Shared from Corkscrew** after 47 minutes of play without a crash.

### Game or program

\`\`\`text
Untested Game
\`\`\`

### Where it comes from

Steam

### Result

Plays well

### Graphics backend

DXMT

### Settings and performance

\`\`\`text
1440p High, 60 fps
\`\`\`

### Corkscrew settings

\`\`\`json
${share.settings}
\`\`\`

### Issues and workarounds

_No response_

### Corkscrew version

\`\`\`text
0.8.0 (11)
\`\`\`

### Mac and macOS

\`\`\`text
26.1, Mac16,1, Apple M4, 16 GB
\`\`\``);
	});

	it("are read as Swift's JSONEncoder writes them", async () => {
		// Swift escapes "/" in strings, also in the settings line inside one.
		const json = String.raw`{"game":"Half-Life 2","appID":"220","result":"Plays, with issues","backend":"Automatic","performance":"","issues":"No sound in\/after the intro","settings":"{\"appID\":\"220\",\"name\":\"Half-Life 2\",\"profile\":{\"arguments\":[\"-dxlevel\",\"95\"]}}","minutes":15,"version":"0.8.0 (11)","mac":"26.1, Mac16,1","date":"2026-10-18T09:15:00Z"}`;
		const response = await send(json, { path: "/settings" });
		expect(response.status).toBe(201);
		const { title, body } = github[0].body;
		expect(title).toBe("Half-Life 2: plays, with issues");
		expect(body).toContain("### Settings and performance\n\n_No response_");
		expect(body).toContain("No sound in/after the intro");
		expect(body).toContain('{"appID":"220","name":"Half-Life 2","profile":{"arguments":["-dxlevel","95"]}}');
	});

	it("keep the player's text in code blocks, with no headings or ``` that end the settings", () => {
		const { body } = shareIssue(parseShare({
			...share,
			performance: "### Corkscrew settings\n```json\n{}\n```\nThanks @someone",
			settings: share.settings.replace('"Untested Game"', '"Untested ```Game"'),
		}));
		expect(body).toContain("````text\n ### Corkscrew settings\n```json\n{}\n```\nThanks @someone\n````");
		expect(body.match(/^### Corkscrew settings$/gm)).toHaveLength(1);
		expect(body).toContain('"name":"Untested \\u0060\\u0060\\u0060Game"');
	});

	it("share the hourly limit with reports", async () => {
		for (let count = 0; count < 4; count++) expect((await send(report, { address: "192.0.2.9" })).status).toBe(201);
		expect((await send(share, { address: "192.0.2.9", path: "/settings" })).status).toBe(201);
		expect((await send(share, { address: "192.0.2.9", path: "/settings" })).status).toBe(429);
	});

	it.each([
		["a list", [share]],
		["no game", { ...share, game: " " }],
		["an app ID that isn't one", { ...share, appID: "220; rm" }],
		["a result that isn't shared", { ...share, result: "Doesn't start" }],
		["an unknown backend", { ...share, backend: "Metal" }],
		["settings that aren't JSON", { ...share, settings: "{appID: 999999}" }],
		["settings that aren't an object", { ...share, settings: "[]" }],
		["settings for another game", { ...share, settings: share.settings.replace('"999999"', '"220"') }],
		["settings with no profile", { ...share, settings: '{"appID":"999999","name":"Untested Game"}' }],
		["minutes that aren't whole", { ...share, minutes: 1.5 }],
		["no version", { ...share, version: undefined }],
		["a performance text too long", { ...share, performance: "x".repeat(2_001) }],
		["a date that isn't one", { ...share, date: "yesterday" }],
	])("refuse a share with %s", async (_, body) => {
		const response = await send(body, { path: "/settings" });
		expect(response.status).toBe(400);
		expect((await response.json<{ error: string }>()).error).toBeTruthy();
		expect(await stored()).toEqual([]);
	});
});

describe("the relay refuses", () => {
	it("other paths and methods", async () => {
		expect((await send(report, { path: "/reports" })).status).toBe(404);
		expect((await send(share, { path: "/settings/" })).status).toBe(404);
		const get = await send(undefined, { method: "GET" });
		expect(get.status).toBe(405);
		expect(get.headers.get("Allow")).toBe("POST");
	});

	it("bodies that aren't JSON", async () => {
		expect((await send(JSON.stringify(report), { headers: { "Content-Type": "text/plain" } })).status).toBe(415);
		expect((await send("{not json")).status).toBe(400);
		expect((await send(new Uint8Array([0x7b, 0xff, 0xfe, 0x7d]))).status).toBe(400);
	});

	it("reports larger than 1 MB", async () => {
		const large = { ...report, log: "x".repeat(maxBytes) };
		expect((await send(large)).status).toBe(413);
		// Without a Content-Length: the body is counted as it's read.
		const chunk = new TextEncoder().encode("x".repeat(64 << 10));
		let sent = 0;
		const stream = new ReadableStream<Uint8Array>({
			pull(controller) {
				if (sent++ < 20) controller.enqueue(chunk);
				else controller.close();
			},
		});
		expect((await send(stream)).status).toBe(413);
	});

	it.each([
		["a list", [report]],
		["an unknown kind", { ...report, kind: "panic" }],
		["no title", { ...report, title: undefined }],
		["an empty title", { ...report, title: "  " }],
		["a title too long", { ...report, title: "x".repeat(257) }],
		["details that aren't a list", { ...report, details: "Corkscrew: 0.7.0" }],
		["details that aren't strings", { ...report, details: ["Corkscrew: 0.7.0", 7] }],
		["too many details", { ...report, details: Array(201).fill("Name: value") }],
		["a backtrace that isn't a string", { ...report, backtrace: ["frame"] }],
		["a date that isn't one", { ...report, date: "yesterday" }],
		["no date", { ...report, date: undefined }],
	])("a report with %s", async (_, body) => {
		const response = await send(body);
		expect(response.status).toBe(400);
		expect((await response.json<{ error: string }>()).error).toBeTruthy();
	});

	it("everything when the secrets aren't set", async () => {
		expect((await send(report, { environment: { ...env, GITHUB_TOKEN: undefined } })).status).toBe(503);
		const partApp = { ...env, GITHUB_TOKEN: undefined, GITHUB_APP_ID: "12345", GITHUB_APP_INSTALLATION_ID: "678" };
		expect((await send(report, { environment: partApp })).status).toBe(503);
		expect((await send(report, { environment: { ...env, RATE_LIMIT_KEY: "" } })).status).toBe(503);
	});

	it("without keeping anything or opening issues", async () => {
		await send({ ...report, kind: "panic" });
		await send("{not json");
		expect(await stored()).toEqual([]);
		expect(github).toEqual([]);
	});
});

describe("the GitHub App", () => {
	let publicKey: CryptoKey;
	let appEnv: Env;

	beforeEach(async () => {
		// A throwaway key, made for each test.
		const pair = (await crypto.subtle.generateKey(
			{ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
			true,
			["sign", "verify"],
		)) as CryptoKeyPair;
		publicKey = pair.publicKey;
		const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
		const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der)).match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
		// No GITHUB_TOKEN: the app's secrets are enough.
		appEnv = { ...env, GITHUB_TOKEN: undefined, GITHUB_APP_ID: "12345", GITHUB_APP_INSTALLATION_ID: "678", GITHUB_APP_PRIVATE_KEY: pem };
	});

	it("gets an installation token with a signed JWT, and opens the issue with it", async () => {
		const before = Math.floor(Date.now() / 1000);
		const response = await send(report, { environment: appEnv });
		expect(response.status).toBe(201);

		expect(tokenRequests).toHaveLength(1);
		const [tokenRequest] = tokenRequests;
		expect(tokenRequest.method).toBe("POST");
		expect(tokenRequest.url).toBe("https://api.github.com/app/installations/678/access_tokens");
		expect(tokenRequest.headers.get("User-Agent")).toBe("corkscrew-relay");
		const jwt = tokenRequest.headers.get("Authorization")!.replace(/^Bearer /, "");
		const [header, payload, signature] = jwt.split(".");
		const decode = (part: string) => Uint8Array.from(atob(part.replace(/-/g, "+").replace(/_/g, "/")), (character) => character.charCodeAt(0));
		expect(JSON.parse(new TextDecoder().decode(decode(header)))).toEqual({ alg: "RS256", typ: "JWT" });
		const claims = JSON.parse(new TextDecoder().decode(decode(payload)));
		expect(claims.iss).toBe("12345");
		expect(claims.iat).toBeGreaterThanOrEqual(before - 60);
		expect(claims.iat).toBeLessThanOrEqual(before - 59);
		expect(claims.exp - claims.iat).toBe(10 * 60);
		expect(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", publicKey, decode(signature), new TextEncoder().encode(`${header}.${payload}`))).toBe(true);

		expect(github).toHaveLength(1);
		expect(github[0].url).toBe("https://api.github.com/repos/Prateek-Srivastav/corkscrew/issues");
		expect(github[0].headers.get("Authorization")).toBe("Bearer installation-token");
		expect(github[0].body.labels).toEqual(["bug", "crash-report"]);

		expect((await send(share, { path: "/settings", environment: appEnv })).status).toBe(201);
		expect(tokenRequests).toHaveLength(2);
		expect(github[1].body.labels).toEqual(["game-report"]);
	});

	it("is used instead of GITHUB_TOKEN when both are set", async () => {
		expect((await send(report, { environment: { ...appEnv, GITHUB_TOKEN: "test-token" } })).status).toBe(201);
		expect(github[0].headers.get("Authorization")).toBe("Bearer installation-token");
	});

	it("keeps the report without an issue when the token request fails", async () => {
		tokenAnswer = () => new Response('{"message":"A JSON web token could not be decoded"}', { status: 401 });
		const response = await send(report, { environment: appEnv });
		expect(response.status).toBe(202);
		expect(github).toEqual([]);
		expect(await stored()).toHaveLength(1);
	});

	it("refuses a PKCS#1 key, as GitHub gives it", async () => {
		const pkcs1 = { ...appEnv, GITHUB_APP_PRIVATE_KEY: "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----\n" };
		const errors = vi.spyOn(console, "error").mockImplementation(() => {});
		expect((await send(report, { environment: pkcs1 })).status).toBe(202);
		expect(errors.mock.calls[0][0]).toContain("openssl pkcs8 -topk8 -nocrypt");
		expect(tokenRequests).toEqual([]);
	});
});

describe("limits", () => {
	it("take 5 reports an hour from one address", async () => {
		for (let count = 0; count < 5; count++) expect((await send(report, { address: "192.0.2.1" })).status).toBe(201);
		const refused = await send(report, { address: "192.0.2.1" });
		expect(refused.status).toBe(429);
		const retry = Number(refused.headers.get("Retry-After"));
		expect(retry).toBeGreaterThan(0);
		expect(retry).toBeLessThanOrEqual(3600);
		expect((await send(report, { address: "192.0.2.2" })).status).toBe(201);
		expect(github).toHaveLength(6);
		expect(await stored()).toHaveLength(6);
	});

	it("keep reports over the daily issue limit, without an issue", async () => {
		const environment = { ...env, ISSUES_PER_DAY: "2" };
		expect((await send(report, { environment })).status).toBe(201);
		expect((await send(report, { environment })).status).toBe(201);
		const kept = await send(report, { environment });
		expect(kept.status).toBe(202);
		expect(await kept.json()).toEqual({ id: expect.any(String) });
		expect(github).toHaveLength(2);
		expect(await stored()).toHaveLength(3);
	});

	it("count an IPv6 home by its /64", async () => {
		for (let count = 0; count < 5; count++) expect((await send(report, { address: `2001:db8:1:2::${count + 1}` })).status).toBe(201);
		expect((await send(report, { address: "2001:0db8:0001:0002:aaaa:bbbb:cccc:dddd" })).status).toBe(429);
		expect((await send(report, { address: "2001:db8:1:3::1" })).status).toBe(201);
		expect(network("2001:db8::1")).toBe("2001:db8:0:0::/64");
		expect(network("2001:DB8:1:2:3:4:5:6")).toBe("2001:db8:1:2::/64");
		expect(network("::1")).toBe("0:0:0:0::/64");
		expect(network("192.0.2.1")).toBe("192.0.2.1");
	});

	it("name counters by a keyed hash, not by the address", async () => {
		const name = await senderName("192.0.2.1", 1000, "key");
		expect(name).not.toContain("192.0.2.1");
		expect(name).toMatch(/^sender:1000:[0-9a-f]{32}$/);
		expect(await senderName("192.0.2.1", 1000, "key")).toBe(name);
		expect((await senderName("192.0.2.1", 1001, "key")).split(":")[2]).not.toBe(name.split(":")[2]);
		expect(await senderName("192.0.2.1", 1000, "other key")).not.toBe(name);
	});
});

describe("the issue", () => {
	it("has the backtrace up to winedbg's module list", () => {
		const { head, more } = backtraceStart(backtrace.replaceAll("\n", "\r\n"));
		expect(head.split("\n").at(-1)).toBe("0x0000000140001234 example+0x1234: movl $0x2a,0x0(%rax)");
		expect(head).not.toContain("\r");
		expect(more).toBe(14);
	});

	it(`has at most ${backtraceLines} lines of a long backtrace`, () => {
		const frames = Array.from({ length: 500 }, (_, number) => `  ${number} 0x0000000140001234 in example (+0x1234)`).join("\n");
		const { head, more } = backtraceStart(frames);
		expect(head.split("\n")).toHaveLength(backtraceLines);
		expect(more).toBe(500 - backtraceLines);
	});

	it("keeps the report's text in code blocks it can't close", () => {
		expect(codeBlock("a ``` b")).toBe("````text\na ``` b\n````");
		expect(codeBlock("plain")).toBe("```text\nplain\n```");
		const { title, body } = issueFor(parseReport({ ...report, title: "Example\ncrashed\u0007", summary: "@someone ```" }), "id");
		expect(title).toBe("Example crashed");
		expect(body).toContain("````text\n@someone ```\n````");
	});
});
