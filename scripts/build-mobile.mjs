import { spawnSync } from "node:child_process";

const target = process.argv[2];
if (!new Set(["driver", "passenger"]).has(target)) {
  throw new Error("Uso: node scripts/build-mobile.mjs driver|passenger");
}

// Production contains the public Maps browser key and map style. The app role
// remains explicit so each Capacitor package keeps its isolated login flow.
const result = spawnSync(process.execPath, ["node_modules/vite/bin/vite.js", "build", "--mode", "production"], {
  env: { ...process.env, VITE_YAVOI_APP_TARGET: target },
  stdio: "inherit",
});
process.exit(result.status ?? 1);
