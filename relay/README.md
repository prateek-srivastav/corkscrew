# Corkscrew report relay

A small Cloudflare Worker that takes the crash and error reports Corkscrew sends with **Send Report**.
For each report it:

1. checks the size (1 MB at most) and the shape, and limits how many reports one network can send;
2. keeps the whole report, with the full backtrace and the end of the log, in a private R2 bucket
   under a random id;
3. opens a public GitHub issue with a summary: the title, the summary line, the details and the start
   of the backtrace, labelled `bug` and `crash-report`. The issue says the full report is stored
   privately under its id;
4. answers the app with the issue's link.

The app posts `ProblemReport` from `Packages/GameCore/Sources/GameCore/ProblemReport.swift` as JSON
(`request(to:)`) and reads `{"issue": "<link>"}` from the answer (`send(to:)`).

## What is public and what is private

| Part of the report | Public issue | Private R2 copy |
| --- | --- | --- |
| Title, summary line, details | Yes | Yes |
| Backtrace | The start, up to Wine's module list (60 lines at most) | All of it |
| End of the log | No | Yes |
| The user's note ("what I was doing") | No | Yes |
| The sender's IP address | No | No |

The relay never stores or logs the IP address. To count reports, it names a counter by a keyed hash
(HMAC-SHA-256 with the `RATE_LIMIT_KEY` secret) of the address and the hour, and the counter deletes
itself when the hour ends. Workers Logs are off in `wrangler.toml` so that Cloudflare doesn't keep
request details either.

The app already shows home folders as `~` and the user name as `<user>` before anything is sent.

## Deploy

You need Node.js 22 or later and the GitHub CLI (`gh`). Run the commands in this folder.

1. **Make a Cloudflare account** at <https://dash.cloudflare.com/sign-up>. The free plan is enough.
   In the dashboard, open **R2** and turn it on. Cloudflare can ask for a payment method for R2; the
   free tier (10 GB) covers this relay.

2. **Install the tools and log in:**

   ```bash
   npm ci
   npx wrangler login
   ```

3. **Make the private R2 bucket.** Don't turn on public access for it.

   ```bash
   npx wrangler r2 bucket create corkscrew-reports
   ```

   Optional: delete reports after a year.

   ```bash
   npx wrangler r2 bucket lifecycle add corkscrew-reports expire-reports --expire-days 365
   ```

   The rate-limit counters are Durable Objects. `wrangler deploy` makes them from `wrangler.toml`, so
   there is no KV namespace or other storage to make.

4. **Make the `crash-report` label** (`bug` exists already):

   ```bash
   gh label create crash-report --repo Prateek-Srivastav/corkscrew --color d93f0b --description "Sent with Send Report in Corkscrew"
   ```

5. **Make a GitHub token** at <https://github.com/settings/personal-access-tokens/new>:
   - Token type: fine-grained.
   - Resource owner: `Prateek-Srivastav`.
   - Repository access: only `Prateek-Srivastav/corkscrew`.
   - Repository permissions: **Issues: Read and write**. Add nothing else (GitHub adds Metadata: Read
     by itself).
   - Expiration: one year, for example. Note the date: when the token expires, the relay still keeps
     reports but opens no issues.

6. **Deploy the Worker:**

   ```bash
   npx wrangler deploy
   ```

   Wrangler prints the address, for example `https://corkscrew-relay.<your-subdomain>.workers.dev`.
   If the account has no `workers.dev` subdomain yet, Wrangler asks you to pick one.

7. **Set the two secrets.** Until both are set, the relay answers 503.

   ```bash
   npx wrangler secret put GITHUB_TOKEN
   ```

   Paste the token from step 5 when Wrangler asks. Then make a random key for the counters:

   ```bash
   openssl rand -hex 32 | npx wrangler secret put RATE_LIMIT_KEY
   ```

8. **Try it** (this opens a real issue; close it afterwards):

   ```bash
   curl -sS https://corkscrew-relay.<your-subdomain>.workers.dev/ -H 'Content-Type: application/json' -d '{"kind":"error","title":"Relay test","summary":"A test report","details":["Corkscrew: test"],"note":"","date":"2026-10-18T12:00:00Z"}'
   ```

   The answer is `{"issue":"https://github.com/…","id":"…"}`.

9. **Point the app at the relay.** In `Packages/GameCore/Sources/GameCore/ProblemReport.swift`, set:

   ```swift
   public static let relayURL: URL? = URL(string: "https://corkscrew-relay.<your-subdomain>.workers.dev/")
   ```

   To try it in a built app first, without a code change:

   ```bash
   defaults write io.github.prateek-srivastav.Corkscrew ReportRelayURL https://corkscrew-relay.<your-subdomain>.workers.dev/
   ```

   Remove it again with `defaults delete io.github.prateek-srivastav.Corkscrew ReportRelayURL`.

## Read a stored report

The issue gives the id. Get the report with:

```bash
npx wrangler r2 object get corkscrew-reports/reports/<id>.json --remote --file report.json
```

Or open **R2 → corkscrew-reports → reports/** in the Cloudflare dashboard. The file holds the id, the
time the relay received it and the report as the app sent it.

To watch the relay live (errors from GitHub, reports kept without an issue), run `npx wrangler tail`.

## Limits

Set in `wrangler.toml` under `[vars]`; deploy again after a change.

| Limit | Default |
| --- | --- |
| Report size | 1 MB (`maxBytes` in `src/index.ts`) |
| Reports from one address in an hour (IPv6: one /64) | `REPORTS_PER_HOUR = "5"` |
| Issues the relay opens in a day (UTC), from all senders | `ISSUES_PER_DAY = "50"` |

Over the daily issue limit, the relay still keeps reports, without an issue.

## Answers

| Status | Body | When |
| --- | --- | --- |
| 201 | `{"issue", "id"}` | The report is kept and the issue is open. |
| 202 | `{"id"}` | The report is kept, without an issue: the daily limit, or GitHub failed. |
| 400 | `{"error"}` | The body isn't JSON, or isn't a report. |
| 404, 405 | `{"error"}` | Not `POST /`. |
| 413 | `{"error"}` | The report is larger than 1 MB. |
| 415 | `{"error"}` | The body isn't `application/json`. |
| 429 | `{"error"}`, `Retry-After` | Too many reports from this address in this hour. |
| 503 | `{"error"}` | A secret isn't set. |

The app treats every 2xx as sent and shows "Report sent". It doesn't open the issue.

## Develop

```bash
npm test         # the tests, in the Workers runtime (GitHub is mocked)
npm run check    # TypeScript
npx wrangler dev # a local relay; it needs a .dev.vars file with the two secrets
```

With `wrangler dev` and a real token, the local relay opens real issues. Use a test repository with
`npx wrangler dev --var GITHUB_REPOSITORY:<owner>/<test-repository>`.
