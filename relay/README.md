# Corkscrew report relay

A small Cloudflare Worker that takes what Corkscrew sends to GitHub, so players need no GitHub
account: the crash and error reports from **Send Report** (`POST /`), and the settings players share
from the share sheet (`POST /settings`, see [Shared settings](#shared-settings)). For each report it:

1. checks the size (1 MB at most) and the shape, and limits how many reports one network can send;
2. keeps the whole report, with the full backtrace and the end of the log, in a private R2 bucket
   under a random id;
3. opens a public GitHub issue with a summary: the title, the summary line, the details and the start
   of the backtrace, labelled `bug` and `crash-report`. The issue says the full report is stored
   privately under its id. A GitHub App opens it, so the author is the app's bot (for example
   `corkscrew-reports[bot]`), not a person;
4. answers the app with the issue's link.

The app posts `ProblemReport` from `Packages/GameCore/Sources/GameCore/ProblemReport.swift` as JSON
(`request(to:)`) and reads `{"issue": "<link>"}` from the answer (`send(to:)`).

## Shared settings

After a Steam game runs 15 minutes without a crash, with settings that aren't on the tested list,
the app offers to share them. **Share** posts `SettingsShare` from
`Packages/GameCore/Sources/GameCore/Stores/TestedGames.swift` to `/settings`: the game and its Steam
app ID, the result (Plays well, or Plays, with issues), the graphics backend, the player's notes, the
Corkscrew settings line (`Steam.settingsReport(of:)`), the minutes played, the Corkscrew version and
the Mac.

The relay keeps the share in R2 under `settings/<id>.json` and opens a Game report labelled
`game-report`. The issue has the fields in the layout GitHub gives a filled-in
`.github/ISSUE_TEMPLATE/game_report.yml`, so a maintainer's **tested** label runs
`scripts/tested-settings.py` on it as on a report from the form. All of the share is public. The
player's text is in code blocks, so it can't mention people, render as Markdown or add a field.
Shares count against the same limits as reports.

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

4. **Make the `crash-report` label** (`bug` and `game-report` exist already):

   ```bash
   gh label create crash-report --repo Prateek-Srivastav/corkscrew --color d93f0b --description "Sent with Send Report in Corkscrew"
   ```

5. **Make the GitHub App** at <https://github.com/settings/apps/new>:
   - GitHub App name: for example `Corkscrew Reports`. Issues show its slug with `[bot]` as the
     author, here `corkscrew-reports[bot]`. The name must be free on all of GitHub.
   - Homepage URL: `https://github.com/Prateek-Srivastav/corkscrew`.
   - Webhook: clear **Active**. The relay needs no events.
   - Repository permissions: **Issues: Read and write**. Add nothing else (GitHub adds Metadata: Read
     by itself).
   - Where can this GitHub App be installed: **Only on this account**.

   Click **Create GitHub App**. On the app's page:
   - Note the **App ID** (under About).
   - Under Private keys, click **Generate a private key**. The browser downloads a `.pem` file.
   - Click **Install App** in the sidebar, install it on `Prateek-Srivastav`, and pick **Only select
     repositories** → `corkscrew`. After the install, the address is
     `https://github.com/settings/installations/<installation-id>`. Note that number.

   The app's key doesn't expire. Its tokens last an hour; the relay gets a new one for each report.

   GitHub gives the key in PKCS#1 (`BEGIN RSA PRIVATE KEY`). Workers read PKCS#8 only, so convert it
   once:

   ```bash
   openssl pkcs8 -topk8 -nocrypt -in ~/Downloads/<app-name>.<date>.private-key.pem -out app-key.pem
   ```

6. **Deploy the Worker:**

   ```bash
   npx wrangler deploy
   ```

   Wrangler prints the address, for example `https://corkscrew-relay.<your-subdomain>.workers.dev`.
   If the account has no `workers.dev` subdomain yet, Wrangler asks you to pick one.

7. **Set the secrets.** Until they are set, the relay answers 503. Type the App ID and the
   installation ID from step 5 when Wrangler asks, and send the key from the file:

   ```bash
   npx wrangler secret put GITHUB_APP_ID
   ```

   ```bash
   npx wrangler secret put GITHUB_APP_INSTALLATION_ID
   ```

   ```bash
   npx wrangler secret put GITHUB_APP_PRIVATE_KEY < app-key.pem
   ```

   Then delete both key files (`app-key.pem` and the download). To make a new key later, generate
   one on the app's page, set it again and delete the old one there.

   Make a random key for the counters:

   ```bash
   openssl rand -hex 32 | npx wrangler secret put RATE_LIMIT_KEY
   ```

8. **Try it** (this opens a real issue; close it afterwards):

   ```bash
   curl -sS https://corkscrew-relay.<your-subdomain>.workers.dev/ -H 'Content-Type: application/json' -d '{"kind":"error","title":"Relay test","summary":"A test report","details":["Corkscrew: test"],"note":"","date":"2026-10-18T12:00:00Z"}'
   ```

   The answer is `{"issue":"https://github.com/…","id":"…"}`. The issue's author is the app's bot.
   If the answer is `{"id":"…"}` without an issue, run `npx wrangler tail` and try again to see what
   GitHub said.

9. **Point the app at the relay.** In `Packages/GameCore/Sources/GameCore/ProblemReport.swift`, set:

   ```swift
   public static let relayURL: URL? = URL(string: "https://corkscrew-relay.<your-subdomain>.workers.dev/")
   ```

   To try it in a built app first, without a code change:

   ```bash
   defaults write io.github.prateek-srivastav.Corkscrew ReportRelayURL https://corkscrew-relay.<your-subdomain>.workers.dev/
   ```

   Remove it again with `defaults delete io.github.prateek-srivastav.Corkscrew ReportRelayURL`.

## Move from a token to the app

Relays deployed before the app used a fine-grained token in `GITHUB_TOKEN`, and the issues showed
the maintainer as the author. The relay still takes that token while any of the three app secrets is
missing, and uses the app when all three are set. To move:

1. Deploy this version (`npx wrangler deploy`). It keeps using the token.
2. Make the app, convert its key and set its three secrets (steps 5 and 7 above).
3. Send a test report (step 8) and check that the author is the app's bot.
4. Remove the token: `npx wrangler secret delete GITHUB_TOKEN`, then delete it at
   <https://github.com/settings/personal-access-tokens>.

## Read a stored report

The issue gives the id. Get the report with:

```bash
npx wrangler r2 object get corkscrew-reports/reports/<id>.json --remote --file report.json
```

Or open **R2 → corkscrew-reports → reports/** in the Cloudflare dashboard. The file holds the id, the
time the relay received it and the report as the app sent it. Shared settings are under `settings/`.

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
| 404, 405 | `{"error"}` | Not `POST /` or `POST /settings`. |
| 413 | `{"error"}` | The report is larger than 1 MB. |
| 415 | `{"error"}` | The body isn't `application/json`. |
| 429 | `{"error"}`, `Retry-After` | Too many reports from this address in this hour. |
| 503 | `{"error"}` | `RATE_LIMIT_KEY` isn't set, or neither the app's three secrets nor `GITHUB_TOKEN` are. |

The app treats every 2xx as sent and shows "Report sent" (or "Shared. Thanks!" for settings). It
doesn't open the issue.

## Develop

```bash
npm test         # the tests, in the Workers runtime (GitHub is mocked)
npm run check    # TypeScript
npx wrangler dev # a local relay; it needs a .dev.vars file with the secrets
```

With `wrangler dev` and real secrets, the local relay opens real issues. Use a test repository with
`npx wrangler dev --var GITHUB_REPOSITORY:<owner>/<test-repository>`.
