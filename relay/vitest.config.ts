import { fileURLToPath } from "node:url";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// The tests apply them to the empty test D1 before each test (test/relay.test.ts).
const migrations = await readD1Migrations(fileURLToPath(new URL("./migrations", import.meta.url)));

export default defineConfig({
	plugins: [
		cloudflareTest({
			wrangler: { configPath: "./wrangler.toml" },
			// Stand-ins for the secrets. GitHub is mocked in the tests: nothing leaves the Mac.
			miniflare: { bindings: { GITHUB_TOKEN: "test-token", RATE_LIMIT_KEY: "test-key", TEST_MIGRATIONS: migrations } },
		}),
	],
});
