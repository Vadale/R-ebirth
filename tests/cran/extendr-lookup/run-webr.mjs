// Execute the same focused Rust/R lookup controls in the compiler's target R.
import { readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
const dist = realpathSync(process.env.RELM_WEBR_RUNTIME);
const { WebR } = await import(pathToFileURL(join(dist, "webr.mjs")).href);
const webR = new WebR({ baseUrl: dist + "/", interactive: false,
  RArgs: ["--vanilla", "--args", "/lookup.so"] });
try {
  await webR.init();
  await webR.evalRVoid('stopifnot(identical(R.version$platform, "wasm32-unknown-emscripten"))');
  await webR.FS.writeFile("/lookup.so", readFileSync(process.argv[2]));
  await webR.FS.writeFile("/check.R", readFileSync(join(dirname(fileURLToPath(import.meta.url)), "check.R")));
  await webR.evalRVoid('source("/check.R", local = TRUE)');
  console.log("EXTENDR_LOOKUP_TARGET_WEBR_OK actual_rust=true models=0");
} finally {
  await webR.close();
}
