-- lua/latex-preview/health.lua
--
-- :checkhealth latex-preview
--
-- Verifies all the pieces a working setup needs:
--   * Node + mathjax-full
--   * a rasterizer (magick or rsvg-convert)
--   * a graphics-capable terminal
--   * the bundled daemon script is on the runtimepath
--   * (optional) treesitter parsers for the configured filetypes

local M = {}

local util = require("latex-preview.util")
local config = require("latex-preview.config")

-- Renamed from `ok`/`warn`/`err` to `report_*` because `local ok` is an
-- extremely common idiom for `pcall` results, and shadowing the helper
-- with a boolean inside any check function is silent until that check
-- tries to call it. See: bug report from 2026-04-29 where `check_snacks`
-- did `local ok, snacks = pcall(require, "snacks")` and the next call to
-- `ok(...)` errored with "attempt to call local 'ok' (a boolean value)".
local function report_ok(msg) vim.health.ok(msg) end
local function report_warn(msg, advice) vim.health.warn(msg, advice) end
local function report_err(msg, advice) vim.health.error(msg, advice) end

local function check_snacks()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    report_err("snacks.nvim is not installed",
      { "latex-preview.nvim renders previews via snacks.image's Kitty",
        "graphics machinery. Install snacks.nvim:",
        "  https://github.com/folke/snacks.nvim" })
    return false
  end
  if not snacks.image then
    report_err("snacks.image module not available",
      { "Your snacks.nvim install may be incomplete or out-of-date." })
    return false
  end
  if not snacks.image.terminal or not snacks.image.terminal.env then
    report_warn("snacks.image.terminal API not as expected",
      { "snacks.nvim version may be incompatible. Update to latest." })
    return true
  end
  local env = snacks.image.terminal.env()
  if env.placeholders then
    report_ok("snacks.image is loaded; terminal supports unicode placeholders")
  else
    report_warn("snacks.image is loaded but terminal doesn't advertise unicode placeholder support",
      { "Confirmed-working terminals: kitty, wezterm, ghostty.",
        "Snacks reports: " .. vim.inspect(env) })
  end
  return true
end

local function check_executable(name, advice)
  if vim.fn.executable(name) == 1 then
    report_ok(name .. " is available")
    return true
  else
    report_err(name .. " not found in PATH", advice)
    return false
  end
end

local function find_daemon_script()
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    local p = rtp .. "/scripts/mathjax-daemon.mjs"
    if vim.fn.filereadable(p) == 1 then return p end
  end
  return nil
end

-- The daemon script owns the canonical mathjax-full candidate list; we ask
-- it to enumerate via `--list-paths` so the Lua side never drifts. Returns
-- a string[] of candidate paths, or nil if we can't run the script.
local function list_mathjax_candidates(script_path)
  if not script_path or vim.fn.executable("node") == 0 then return nil end
  local out = vim.fn.systemlist({ "node", script_path, "--list-paths" })
  if vim.v.shell_error ~= 0 or type(out) ~= "table" then return nil end
  local clean = {}
  for _, p in ipairs(out) do
    if type(p) == "string" and p ~= "" then table.insert(clean, p) end
  end
  return clean
end

local function check_mathjax_full(script_path)
  local candidates = list_mathjax_candidates(script_path)
  if not candidates then
    report_warn("could not enumerate mathjax-full candidate paths",
      { "Need both `node` and the bundled scripts/mathjax-daemon.mjs.",
        "If you haven't yet, install with: npm install -g mathjax-full@3" })
    return false
  end
  for _, p in ipairs(candidates) do
    if vim.fn.filereadable(p .. "/package.json") == 1 then
      report_ok("mathjax-full found at " .. p)
      return true
    end
  end
  local advice = {
    "Install with: npm install -g mathjax-full@3",
    "Or set the environment variable LATEX_PREVIEW_MATHJAX_PATH to its install dir.",
    "Checked paths:",
  }
  for _, p in ipairs(candidates) do
    table.insert(advice, "  " .. p)
  end
  report_err("mathjax-full not found", advice)
  return false
end

local function check_daemon_script(script_path)
  if script_path then
    report_ok("daemon script found at " .. script_path)
    return true
  end
  report_err("scripts/mathjax-daemon.mjs not found on runtimepath", {
    "If you installed via a plugin manager, this should be automatic.",
    "If you cloned manually, add the plugin's root directory to runtimepath.",
  })
  return false
end

-- Terminal support is checked by check_snacks() via
-- Snacks.image.terminal.env().placeholders — once the dependency
-- arrangement was simplified to "snacks owns image transport", a
-- separate terminal probe in this file became redundant.

local function check_rasterizer()
  local magick = vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1
  local rsvg = vim.fn.executable("rsvg-convert") == 1
  if magick and rsvg then
    report_ok("rasterizer: rsvg-convert + ImageMagick available")
  elseif magick then
    -- magick-without-rsvg often fails on SVG. Warn rather than ok.
    report_warn("ImageMagick is available but librsvg is not",
      { "Some MathJax SVGs need librsvg to render correctly.",
        "Install librsvg2-bin (Linux) or librsvg (macOS)." })
  elseif rsvg then
    report_ok("rasterizer: rsvg-convert")
  else
    report_err("no SVG rasterizer found",
      { "Install one of:",
        "  apt install imagemagick librsvg2-bin   (Debian/Ubuntu)",
        "  brew install imagemagick librsvg       (macOS)" })
  end
  if config.options.render.pad_to_cells and not magick then
    report_warn("render.pad_to_cells is enabled but ImageMagick is not available",
      { "Install ImageMagick (`magick` or `convert`) to pad generated PNGs to terminal-cell boundaries.",
        "Without padding, some terminals may scale short equations slightly." })
  end
end

local function check_treesitter()
  local ok_, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok_ then
    report_warn("nvim-treesitter not installed",
      { "Optional but recommended: improves equation detection accuracy.",
        "Without it, latex-preview falls back to a regex-based scan." })
    return
  end
  for _, lang in ipairs({ "latex", "markdown_inline" }) do
    if util.has_ts_parser(parsers, lang) then
      report_ok("treesitter parser: " .. lang)
    else
      report_warn("treesitter parser missing: " .. lang,
        { "Install with: :TSInstall " .. lang })
    end
  end
end

function M.check()
  vim.health.start("latex-preview: dependencies")
  check_snacks()
  check_executable("node",
    { "Install Node.js 18+ — https://nodejs.org/" })
  -- check_mathjax_full needs the daemon script path (it shells out to it
  -- with --list-paths), so resolve once and pass to both checks.
  local script_path = find_daemon_script()
  check_mathjax_full(script_path)
  check_daemon_script(script_path)

  vim.health.start("latex-preview: rendering")
  check_rasterizer()

  vim.health.start("latex-preview: optional")
  check_treesitter()
end

return M
