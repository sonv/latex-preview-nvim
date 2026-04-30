#!/usr/bin/env node
//
// mathjax-daemon.mjs
//
// A long-running MathJax daemon for the latex-preview.nvim plugin. Reads
// newline-delimited JSON requests from stdin and writes newline-delimited
// JSON responses to stdout. Loads MathJax once at startup (~1.3s) so
// per-request cost drops to ~10-50ms — enough for inline live preview
// as the user types.
//
// Protocol (one JSON object per line, both directions):
//
//   request:   {"id": <any>, "preamble": "<tex>", "equation": "<tex>",
//               "display": false, "color": "000000"}
//   response:  {"id": <echoed>, "ok": true,  "svg": "<svg>...</svg>"}
//          or  {"id": <echoed>, "ok": false, "err": "..."}
//
// Errors during preamble parsing are swallowed line-by-line (Overleaf
// pattern) so that \RequirePackage / \DeclareOption / \makeatletter inside
// a .sty file don't kill the render. Errors on the actual equation
// propagate so the plugin can surface them.
//
// One-shot mode (for ad-hoc use and tests):
//   mathjax-daemon.mjs --in FILE --out FILE.svg [--display] [--color HEX]
//
// Requires:  npm i -g mathjax-full   (or local install — auto-detected)
//

import { argv, exit, stderr, stdin, stdout } from "node:process";
import { promises as fs } from "node:fs";
import { createInterface } from "node:readline";
import { execFileSync } from "node:child_process";

function parseArgs(a) {
  const o = { display: false, color: "000000", daemon: false };
  for (let i = 2; i < a.length; i++) {
    const k = a[i];
    if (k === "--in") o.input = a[++i];
    else if (k === "--out") o.output = a[++i];
    else if (k === "--display") o.display = true;
    else if (k === "--color") o.color = a[++i];
    else if (k === "--ex") o.ex = parseFloat(a[++i]);
    else if (k === "--daemon") o.daemon = true;
  }
  return o;
}

// ---------------------------------------------------------------------------
// MathJax bootstrap. Resolved once at startup and kept in module scope so
// the daemon loop can reuse the loaded modules across thousands of requests.
// ---------------------------------------------------------------------------
async function bootMathJax() {
  const path = await import("node:path");
  const fsSync = await import("node:fs");
  const { fileURLToPath, pathToFileURL } = await import("node:url");
  const here = path.dirname(fileURLToPath(import.meta.url));

  const candidates = [];
  const seen = new Set();
  const addCandidate = (p) => {
    if (!p || seen.has(p)) return;
    seen.add(p);
    candidates.push(p);
  };

  addCandidate(process.env.LATEX_PREVIEW_MATHJAX_PATH);
  addCandidate(process.env.SNACKS_MATHJAX_PATH);
  addCandidate(path.join(here, "node_modules", "mathjax-full"));
  addCandidate(path.join(here, "..", "node_modules", "mathjax-full"));
  addCandidate(path.join(process.cwd(), "node_modules", "mathjax-full"));
  for (const p of [
    "/usr/lib/node_modules/mathjax-full",
    "/usr/local/lib/node_modules/mathjax-full",
    "/opt/homebrew/lib/node_modules/mathjax-full",
    "/opt/local/lib/node_modules/mathjax-full",
    path.join(process.env.HOME || "", ".npm-global/lib/node_modules/mathjax-full"),
    path.join(process.env.HOME || "",
      ".nvm/versions/node/" + process.version + "/lib/node_modules/mathjax-full"),
  ]) addCandidate(p);
  try {
    const npmRoot = execFileSync("npm", ["root", "-g"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    addCandidate(path.join(npmRoot, "mathjax-full"));
  } catch (_) {
    // npm is optional here; explicit env/local/hardcoded paths may still work.
  }

  let mjPath = null;
  for (const c of candidates) {
    if (c && fsSync.existsSync(path.join(c, "package.json"))) { mjPath = c; break; }
  }
  if (!mjPath) {
    stderr.write(
      "latex-preview/mathjax-daemon: mathjax-full not found. Install with:\n" +
      "  npm install -g mathjax-full@3\n" +
      "Or set LATEX_PREVIEW_MATHJAX_PATH to its install dir.\n" +
      "Checked:\n" +
      candidates.filter(Boolean).map((p) => "  " + p).join("\n") +
      "\n"
    );
    exit(1);
  }

  const u = (sub) => pathToFileURL(path.join(mjPath, sub)).href;
  const { mathjax }            = await import(u("js/mathjax.js"));
  const { TeX }                = await import(u("js/input/tex.js"));
  const { SVG }                = await import(u("js/output/svg.js"));
  const { liteAdaptor }        = await import(u("js/adaptors/liteAdaptor.js"));
  const { RegisterHTMLHandler } = await import(u("js/handlers/html.js"));
  const { AllPackages }        = await import(u("js/input/tex/AllPackages.js"));

  // RegisterHTMLHandler installs a global handler against an adaptor. We
  // create a single "boot adaptor" here just to register; per-request work
  // creates fresh adaptors so macros from request N don't leak into N+1.
  const bootAdaptor = liteAdaptor();
  RegisterHTMLHandler(bootAdaptor);

  return { mathjax, TeX, SVG, liteAdaptor, AllPackages };
}

let MJ = null; // populated by bootMathJax()

function splitPreambleBlocks(preamble) {
  const blocks = [];
  let block = [];
  let depth = 0;
  let started = false;

  const update = (line) => {
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (c === "\\") {
        i++;
      } else if (c === "{") {
        depth++;
        started = true;
      } else if (c === "}") {
        depth--;
      }
    }
  };

  const flush = () => {
    const text = block.join("\n").trim();
    if (text) blocks.push(text);
    block = [];
    depth = 0;
    started = false;
  };

  for (const raw of preamble.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("%")) {
      if (block.length) flush();
      continue;
    }
    block.push(raw);
    update(line.replace(/(?<!\\)%.*/, ""));
    if (started && depth <= 0) flush();
    else if (!started && /^\\(?:let|newcounter)\b/.test(line)) flush();
  }
  if (block.length) flush();
  return blocks;
}

function normalizeEquation(equation, display, displayMathStyle) {
  if (!equation) return equation;
  let math = equation.replace(/\\label\s*\{[^{}]*\}/g, "").trim();
  const style = display && displayMathStyle === "text" ? "\\textstyle " : "";
  if (!display || !math.includes("\n")) return style + math;
  if (/\\begin\s*\{(?:aligned|alignedat|align|alignat|split|gathered|gather|matrix|pmatrix|bmatrix|cases)\}/.test(math)) {
    return style + math;
  }
  const lines = math
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !/^\\(?:notag|nonumber)\b/.test(line))
    .map((line) => line.replace(/\\\\\s*$/, "").trim())
    .map((line) => style + line);
  if (lines.length <= 1) return lines[0] || math;
  return "\\begin{aligned}\n" + lines.join(" \\\\\n") + "\n\\end{aligned}";
}

// ---------------------------------------------------------------------------
// Render one equation. Fresh adaptor per call, so a \newcommand the user
// edits in their buffer correctly invalidates without daemon restart.
// ---------------------------------------------------------------------------
function renderOne({ preamble, equation, display, color, font_size, display_math_style, ex }) {
  if (!MJ) throw new Error("mathjax not booted");
  const { mathjax, TeX, SVG, liteAdaptor, AllPackages } = MJ;

  const adaptor = liteAdaptor();
  // Exclude `noerrors` and `noundefined` from the package list. AllPackages
  // includes them by default; they convert TeX errors into rendered red
  // text rather than throwing. That's the right behavior for a public web
  // page (graceful degradation), but for us it makes engine="auto" unable
  // to detect failure and fall back to pdflatex. We want strict errors.
  const packages = AllPackages.filter(p => p !== "noerrors" && p !== "noundefined");
  const tex = new TeX({
    packages,
    formatError: (jax, err) => { throw err; },
  });
  const svg = new SVG({ fontCache: "local" });
  const html = mathjax.document("", { InputJax: tex, OutputJax: svg });

  const em = Number(font_size) > 0 ? Number(font_size) : 11;
  const opts = { display: false, em, ex: ex || em / 2, containerWidth: 1280 };

  // Pass 1: register macros from the preamble. MathJax's `html.convert`
  // takes raw math content (no \(...\) or \[...\] delimiters) and
  // processes it in math mode; the `newcommand` package handles bare
  // \newcommand / \def / \let / \DeclareMathOperator definitions in math
  // mode with no wrapping needed. We pass everything as one string first
  // (one MathJax invocation = ~3ms), then on error fall back to per-line
  // parsing so a single bad line doesn't lose all the good ones.
  if (preamble && preamble.trim()) {
    try {
      html.convert(preamble, opts);
    } catch {
      for (const block of splitPreambleBlocks(preamble)) {
        try { html.convert(block, opts); } catch { /* swallow */ }
      }
    }
  }

  // Pass 2: render the equation. The caller passes math content WITHOUT
  // delimiters (the plugin strips them upstream), and `display` says whether
  // to render inline or display style. Errors here are caller-visible —
  // the plugin surfaces ok=false as a notification; no automatic fallback.
  const math = normalizeEquation(equation, !!display, display_math_style);
  const out = html.convert(math, { ...opts, display: !!display });
  let svgStr = adaptor.innerHTML(out);
  const m = svgStr.match(/<svg[\s\S]*<\/svg>/);
  if (m) svgStr = m[0];
  const viewBox = svgStr.match(/viewBox="([^"]+)"/);
  if (viewBox) {
    const nums = viewBox[1].trim().split(/\s+/).map(Number);
    if (nums.length === 4 && nums.every(Number.isFinite)) {
      const widthPx = Math.max(1, (nums[2] / 1000) * em);
      const heightPx = Math.max(1, (nums[3] / 1000) * em);
      svgStr = svgStr
        .replace(/\swidth="[^"]*"/, ` width="${widthPx.toFixed(3)}px"`)
        .replace(/\sheight="[^"]*"/, ` height="${heightPx.toFixed(3)}px"`);
    }
  }
  if (color && color !== "currentColor") {
    svgStr = svgStr.replace(/<svg\b/, `<svg fill="#${color}" color="#${color}"`);
    svgStr = svgStr.replace(/currentColor/g, `#${color}`);
  }
  if (!svgStr.startsWith("<?xml")) {
    svgStr = '<?xml version="1.0" encoding="UTF-8"?>\n' + svgStr;
  }
  return svgStr;
}

// ---------------------------------------------------------------------------
// Daemon mode. Newline-delimited JSON in / out.
// ---------------------------------------------------------------------------
async function runDaemon() {
  // Pre-warm so the first real request is fast.
  MJ = await bootMathJax();
  // Signal readiness to the parent. Snacks waits for this line before
  // dispatching queued requests.
  stdout.write(JSON.stringify({ ready: true }) + "\n");

  const rl = createInterface({ input: stdin, terminal: false });
  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let req;
    try {
      req = JSON.parse(trimmed);
    } catch (e) {
      stdout.write(JSON.stringify({ ok: false, err: "bad json: " + e.message }) + "\n");
      continue;
    }
    if (req.quit) { exit(0); }
    try {
      const svg = renderOne(req);
      stdout.write(JSON.stringify({ id: req.id, ok: true, svg }) + "\n");
    } catch (e) {
      stdout.write(JSON.stringify({
        id: req.id,
        ok: false,
        err: (e && e.message) ? e.message : String(e),
      }) + "\n");
    }
  }
}

// ---------------------------------------------------------------------------
// One-shot mode. Useful for tests and as an emergency fallback if the daemon
// pipe is wedged on the plugin side.
// ---------------------------------------------------------------------------
async function runOneShot(opts) {
  if (!opts.input || !opts.output) {
    stderr.write("usage: mathjax-daemon.mjs --in FILE --out FILE.svg [--display] [--color HEX]\n");
    stderr.write("  or:  mathjax-daemon.mjs --daemon  (stdin/stdout JSON protocol)\n");
    exit(2);
  }
  MJ = await bootMathJax();
  const raw = await fs.readFile(opts.input, "utf8");
  const SPLIT = /^%%% SNACKS-MATHJAX-SPLIT %%%\s*$/m;
  // Strip the leading "%% latex-preview: ..." (or "%% snacks-mathjax: ...")
  // metadata header if present. The plugin doesn't use one-shot mode, but
  // we accept either prefix so users who installed manually with old
  // intermediate files still get correct behavior.
  const noMeta = raw.replace(/^%%\s*(latex-preview|snacks-mathjax):[^\n]*\n/, "");
  const m = noMeta.split(SPLIT);
  const preamble = (m[0] || "").trim();
  const equation = (m[1] || m[0] || "").trim();
  const svg = renderOne({
    preamble, equation,
    display: opts.display, color: opts.color, ex: opts.ex,
  });
  await fs.writeFile(opts.output, svg, "utf8");
}

async function main() {
  const opts = parseArgs(argv);
  if (opts.daemon) return runDaemon();
  return runOneShot(opts);
}

main().catch((e) => {
  stderr.write("mathjax-daemon fatal: " + (e && e.stack ? e.stack : String(e)) + "\n");
  exit(1);
});
