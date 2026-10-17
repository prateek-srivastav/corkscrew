import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
	plugins: [
		cloudflareTest({
			wrangler: { configPath: "./wrangler.toml" },
			// Stand-ins for the secrets. GitHub is mocked in the tests: nothing leaves the Mac.
			miniflare: { bindings: { GITHUB_TOKEN: "test-token", RATE_LIMIT_KEY: "test-key" } },
		}),
	],
});
