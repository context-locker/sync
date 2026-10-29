// Builds the command npm runs: one file holding everything it needs, with
// the sync scripts beside it, which setup saves on the computer.
import { chmodSync, copyFileSync, mkdirSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

const at = (path) => fileURLToPath(new URL(path, import.meta.url));

rmSync(at("../dist"), { recursive: true, force: true });
mkdirSync(at("../dist"), { recursive: true });
await build({
  entryPoints: [at("../src/main.ts")],
  outfile: at("../dist/cli.js"),
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node20",
  banner: { js: "#!/usr/bin/env node" },
  legalComments: "none",
  logLevel: "warning",
});
chmodSync(at("../dist/cli.js"), 0o755);
for (const name of ["sync.sh", "sync.ps1"]) {
  copyFileSync(at(`../../compilers/scripts/${name}`), at(`../dist/${name}`));
}
