-- lua/latex-preview/config.lua
--
-- Default configuration. The defaults assume "press K inside a math
-- expression, see a popup with the rendered equation." Override anything
-- via require("latex-preview").setup({...}).

local M = {}

---@class LatexPreview.Config
---@field enabled boolean Whether setup() does anything (a kill switch).
---@field filetypes string[] Filetypes the keymap and command apply to.
---@field setup_keymap boolean Auto-install the toggle keymap on supported filetypes.
---@field keymap string|string[] The key(s) used for toggle. Default: "ih".
---@field cache boolean Write stable renders to cache_dir. Live hover updates always use temporary files.
---@field cache_dir string|fun(buf: integer): string|"aux" Where to store rendered SVG/PNG files.
---@field daemon LatexPreview.DaemonConfig
---@field extract LatexPreview.ExtractConfig
---@field render LatexPreview.RenderConfig
---@field popup LatexPreview.PopupConfig
---@field hover LatexPreview.HoverConfig
---@field snacks LatexPreview.SnacksConfig

---@class LatexPreview.DaemonConfig
---@field cmd string[]? Override the daemon command. Default: {"node", "<plugin>/scripts/mathjax-daemon.mjs"}.
---@field max_restarts integer How many times to auto-respawn on crash.
---@field ready_timeout_ms integer How long to wait for the daemon's ready signal at boot.

---@class LatexPreview.ExtractConfig
---@field scan_sty boolean Pull macros from local .sty files referenced via \usepackage.
---@field sty_search_depth integer How many parent directories to walk looking for .sty files.
---@field rewrite_providecommand boolean Rewrite \providecommand to \newcommand for MathJax compatibility.
---@field rewrite_edef boolean Rewrite \edef to \def (MathJax doesn't expand at definition).

---@class LatexPreview.RenderConfig
---@field fg string|fun(): string Foreground color as #RRGGBB. Default: current Normal hl fg.
---@field font_size integer MathJax font size in pixels.
---@field display_font_size integer MathJax font size in pixels for display equations.
---@field display_math_style "text"|"display" TeX style used inside display equations.
---@field pad_to_cells boolean Pad PNGs to terminal-cell multiples to prevent terminal upscaling.
---@field density integer ImageMagick density (DPI) for SVG -> PNG.
---@field svg_to_png "auto"|"magick"|"rsvg" Tool used to rasterize.

---@class LatexPreview.PopupConfig
---@field max_width integer? Maximum popup image width in terminal cells. Default: editor width minus padding.
---@field max_height integer? Maximum popup image height in terminal cells. Default: editor height minus padding.
---@field live_update_delay_ms integer Debounce delay for rerendering while typing.

---@class LatexPreview.HoverConfig
---@field auto_open boolean? Override Snacks image.doc.float for auto hover.
---@field toggle_keymap string|false Key mapped through Snacks.toggle when setup_keymap=true.

---@class LatexPreview.SnacksConfig
---@field disable_document_images boolean Disable snacks.image's document inline/auto previewer.

---@type LatexPreview.Config
M.defaults = {
  enabled = true,
  filetypes = { "tex", "latex", "markdown", "rmd", "quarto" },
  -- The default toggle key. `<leader>ih` is mnemonic for "inspect here"
  -- and is namespaced under <leader> to avoid colliding with anything
  -- in the default Vim or LSP keymaps. Pass a list of strings to bind
  -- multiple keys to the same toggle.
  keymap = "<leader>ih",
  -- Off by default: enabling this auto-installs the keymap above on
  -- supported filetypes. Most users want this on; set to false if you'd
  -- rather wire the keymap yourself.
  setup_keymap = false,
  cache = false,
  cache_dir = "aux",
  -- cache_dir can be:
  --   * the magic string "aux" (default) — places files in
  --     `<texfile-dir>/aux/latex-preview-cache/`. For unsaved buffers,
  --     falls back to the global stdpath cache.
  --   * a string path, used globally for all files
  --   * a function `fun(buf: integer): string` returning a path per buffer

  daemon = {
    cmd = nil, -- nil = auto-resolve to <plugin>/scripts/mathjax-daemon.mjs
    max_restarts = 3,
    ready_timeout_ms = 8000,
  },

  extract = {
    -- Pull macro definitions from local .sty files referenced via
    -- \usepackage{name} when name.sty exists in the buffer's directory or
    -- any ancestor up to `sty_search_depth` levels. Same trick Overleaf
    -- uses to make custom notation packages "just work."
    scan_sty = true,
    sty_search_depth = 4,
    rewrite_providecommand = true,
    rewrite_edef = true,
  },

  render = {
    fg = function()
      local hl = vim.api.nvim_get_hl(0, { name = "Normal" })
      if hl and hl.fg then return string.format("#%06x", hl.fg) end
      return "#000000"
    end,
    font_size = 11,
    display_font_size = 11,
    display_math_style = "text",
    pad_to_cells = true,
    density = 300,
    svg_to_png = "auto",
  },

  popup = {
    -- Keep one-line and multi-line equations at the same rendered font
    -- size whenever the terminal can fit them. If nil, use nearly the
    -- full editor dimensions instead of snacks.image.doc's small defaults.
    max_width = nil,
    max_height = nil,
    live_update_delay_ms = 300,
  },

  hover = {
    -- nil means: follow Snacks' image.doc.float option. Set true/false only
    -- if you want latex-preview to ignore Snacks' float preference.
    auto_open = nil,
    -- Runtime toggle for auto hover. This uses Snacks.toggle when available,
    -- so which-key can show the enabled/disabled state.
    toggle_keymap = "<leader>iH",
  },

  snacks = {
    -- latex-preview.nvim only wants snacks.image's placement backend for
    -- the explicit popup. Snacks' own document renderer scans buffers and
    -- renders every math expression/image inline by default, which is a
    -- different feature and conflicts with this plugin's toggle-only UX.
    disable_document_images = true,
  },
}

---@type LatexPreview.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  return M.options
end

---Resolve the foreground color, calling the function form if needed.
function M.get_fg()
  local fg = M.options.render.fg
  if type(fg) == "function" then fg = fg() end
  return fg or "#000000"
end

---Resolve cache_dir to an absolute path for this buffer. Honors the three
---supported forms (string path / function / "aux" magic value). Always
---returns a string; the caller is responsible for `mkdir -p`.
---@param buf integer
---@return string
function M.get_cache_dir(buf)
  local c = M.options.cache_dir
  if type(c) == "function" then return c(buf) end
  if c == "aux" then
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then
      return vim.fn.stdpath("cache") .. "/latex-preview-cache"
    end
    return vim.fs.dirname(vim.fn.fnamemodify(name, ":p")) .. "/aux/latex-preview-cache"
  end
  return c
end

return M
