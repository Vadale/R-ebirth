// Use the cross-compilation toolchain's local target R. No downloaded runtime,
// pre-generated wrapper fallback, or host DLL substitution is permitted here.
import { readFileSync, writeFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const args = process.argv.slice(2);
if (args.length !== 2) throw new Error("Expected DLL and wrapper output paths");
const root = process.env.RELM_WEBR_RUNTIME;
if (!root) throw new Error("Wasm wrapper generation requires RELM_WEBR_RUNTIME: a local Node-compatible webR runtime for the target toolchain");
const dist = realpathSync(root);
const { WebR } = await import(pathToFileURL(join(dist, "webr.mjs")).href);
const webR = new WebR({
  baseUrl: dist + "/",
  interactive: false,
  RArgs: ["--vanilla", "--args", "/relm.so", "/wrappers.R"],
});
try {
  await webR.init();
  await webR.evalRVoid('stopifnot(identical(R.version$platform, "wasm32-unknown-emscripten"))');
  await webR.FS.writeFile("/relm.so", readFileSync(args[0]));
  await webR.FS.writeFile("/generate-wrappers.R",
    readFileSync(join(dirname(fileURLToPath(import.meta.url)), "generate-wrappers.R")));
  // Execute the same registration, metadata and R syntax checks as native R.
  await webR.evalRVoid('source("/generate-wrappers.R", local = TRUE)');
  const output = await webR.FS.readFile("/wrappers.R");
  writeFileSync(args[1], output);
  console.log("RELM_WASM_R_HOSTED_WRAPPERS_OK");
} finally {
  await webR.close();
}
