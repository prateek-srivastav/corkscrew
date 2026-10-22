/** The relay's GitHub App: issues it opens show `<app-name>[bot]` as the author. */
export interface GitHubApp {
	id: string;
	installation: string;
	/** PKCS#8 PEM (`BEGIN PRIVATE KEY`). GitHub gives PKCS#1; the README says how to convert it. */
	privateKey: string;
}

/** A new installation token for `app`, good for an hour. Throws when GitHub says no. */
export async function installationToken(app: GitHubApp): Promise<string> {
	const response = await fetch(`https://api.github.com/app/installations/${app.installation}/access_tokens`, {
		method: "POST",
		headers: {
			Accept: "application/vnd.github+json",
			Authorization: `Bearer ${await appJWT(app)}`,
			"User-Agent": "corkscrew-relay",
			"X-GitHub-Api-Version": "2022-11-28",
		},
		signal: AbortSignal.timeout(10_000),
	});
	if (!response.ok) throw new Error(`GitHub answered ${response.status} for the app token: ${(await response.text()).slice(0, 500)}`);
	const answer = (await response.json()) as { token?: unknown };
	if (typeof answer.token !== "string") throw new Error("GitHub's answer has no app token.");
	return answer.token;
}

/** The app's RS256 JWT. It starts a minute early for clock drift and ends inside GitHub's 10 minutes. */
export async function appJWT(app: GitHubApp, now = Date.now()): Promise<string> {
	if (app.privateKey.includes("BEGIN RSA PRIVATE KEY")) {
		throw new Error("GITHUB_APP_PRIVATE_KEY is PKCS#1. Convert it with openssl pkcs8 -topk8 -nocrypt.");
	}
	const der = Uint8Array.from(atob(app.privateKey.replace(/-----[A-Z ]+-----|\s/g, "")), (character) => character.charCodeAt(0));
	const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
	const seconds = Math.floor(now / 1000);
	const unsigned = `${base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${base64url(JSON.stringify({ iat: seconds - 60, exp: seconds + 9 * 60, iss: app.id }))}`;
	const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
	return `${unsigned}.${base64url(new Uint8Array(signature))}`;
}

function base64url(data: string | Uint8Array): string {
	const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
	return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
