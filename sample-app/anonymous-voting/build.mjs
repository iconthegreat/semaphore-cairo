import * as esbuild from "esbuild";

await esbuild.build({
  entryPoints: ["src/browser-entry.ts"],
  bundle: true,
  platform: "browser",
  target: "es2020",
  format: "iife",
  globalName: "SemaphoreCairo",
  outfile: "public/bundle.js",
  // Polyfill Node.js built-ins for browser
  define: {
    "process.env.NODE_ENV": '"production"',
    "global": "globalThis",
  },
  // Mark heavy Node.js-only things external (they're not needed in browser)
  external: ["child_process", "fs", "os", "path", "crypto"],
  // Allow large bundle (snarkjs + circuit deps are big)
  logLevel: "info",
});

console.log("Bundle written to bundle.js");
