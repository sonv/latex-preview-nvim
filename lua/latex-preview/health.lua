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

local function check_mathjax_full()
  -- The daemon script searches several locations; we replicate the search
  -- here to give the user a precise error instead of a vague one.
  local candidates, seen = {}, {}
  local function add_candidate(p)
    if not p or p == "" or seen[p] then return end
    seen[p] = true
    table.insert(candidates, p)
  end

  add_candidate(vim.env.LATEX_PREVIEW_MATHJAX_PATH)
  add_candidate(vim.env.SNACKS_MATHJAX_PATH) -- legacy, supported for migration users
  add_candidate(vim.fn.getcwd() .. "/node_modules/mathjax-full")
  add_candidate("/usr/lib/node_modules/mathjax-full")
  add_candidate("/usr/local/lib/node_modules/mathjax-full")
  add_candidate("/opt/homebrew/lib/node_modules/mathjax-full")
  add_candidate("/opt/local/lib/node_modules/mathjax-full")
  add_candidate((vim.env.HOME or "") .. "/.npm-global/lib/node_modules/mathjax-full")
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    add_candidate(rtp .. "/scripts/node_modules/mathjax-full")
    add_candidate(rtp .. "/node_modules/mathjax-full")
  end
  if vim.fn.executable("npm") == 1 then
    local npm_root = vim.fn.systemlist({ "npm", "root", "-g" })[1]
    if vim.v.shell_error == 0 and npm_root and npm_root ~= "" then
      add_candidate(npm_root .. "/mathjax-full")
    end
  end
  for _, p in ipairs(candidates) do
    if p and vim.fn.filereadable(p .. "/package.json") == 1 then
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
    if p and p ~= "" then table.insert(advice, "  " .. p) end
  end
  report_err("mathjax-full not found", advice)
  return false
end

local function check_daemon_script()
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    local p = rtp .. "/scripts/mathjax-daemon.mjs"
    if vim.fn.filereadable(p) == 1 then
      report_ok("daemon script found at " .. p)
      return true
    end
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
end

local function check_treesitter()
  local ok_, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok_ then
    report_warn("nvim-treesitter not installed",
      { "Optional but recommended: improves equation detection accuracy.",
        "Without it, latex-preview falls back to a regex-based scan." })
    return
  end
  local function has_parser(lang)
    if type(parsers.has_parser) == "function" then
      local ok, found = pcall(parsers.has_parser, lang)
      if ok then return found == true end
    end
    local ts_lang = vim.treesitter and vim.treesitter.language
    if ts_lang and type(ts_lang.has_parser) == "function" then
      local ok, found = pcall(ts_lang.has_parser, lang)
      if ok then return found == true end
    end
    if ts_lang and type(ts_lang.inspect) == "function" then
      local ok, info = pcall(ts_lang.inspect, lang)
      return ok and type(info) == "table"
    end
    if ts_lang and type(ts_lang.add) == "function" then
      local ok, found = pcall(ts_lang.add, lang)
      return ok and found == true
    end
    return false
  end
  for _, lang in ipairs({ "latex", "markdown_inline" }) do
    if has_parser(lang) then
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
  check_mathjax_full()
  check_daemon_script()

  vim.health.start("latex-preview: rendering")
  check_rasterizer()

  vim.health.start("latex-preview: optional")
  check_treesitter()
end

return M
