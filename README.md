# latex-preview.nvim

## Vibe code project: I used Claude to make initial code and ChatGPT 5.5 to optimize.

Inspired by Overleaf's functionality.

This is a hover-style LaTeX math preview for Neovim that can **live update while typing**.
Press a key inside a math expression and a small floating window pops up with the rendered equation —
the way Overleaf shows preview tooltips on hover.


It renders via MathJax in a long-running Node daemon. Pulls custom macros
from your buffer and any local `.sty` files automatically. 

**WARNING**: This plugin only works with terminal that support graphics such as Kitty or iTerm2, WezTerm, Ghostty.
Personally, I've only tested with Kitty, however. 


## What it looks like

Demo:

[![Watch Demo](demo/demo.mov)]

## Why this design

Inline preview ("show the rendered image right where the source is") is
beautiful when it works but operationally hard: it has to fight Neovim's
redraws, scrolling, visual selection, undo, and split windows.

Hover preview is much simpler. The popup only exists while you're
deliberately looking at it, closes the moment you move the cursor, and
the rest of the time your buffer behaves like any other text file. It
also works great for the actual use case: "wait, what does this
equation look like?" — answer the question, get back to typing.

## Why the snacks.nvim dependency?

Putting an image in a Neovim floating window via the Kitty graphics
protocol — handling the Unicode-placeholder layout, the diacritic
encoding, the chunked transmission, the auto-resize on window changes,
and the cleanup on close — is intricate code that snacks.nvim already
solves correctly and maintains. Rather than ship a parallel
implementation that subtly diverges, this plugin uses snacks's
`image.placement` directly. It produces the rendered PNG via the
MathJax daemon and hands the path to snacks.

If you'd prefer no snacks dependency, use snacks-image's own math
preview. The trade-off is that snacks renders math via `pdflatex`
(~500-2000 ms per equation) rather than MathJax (~10-50 ms), which is
fine for occasional preview but too slow for live editing.

## Requirements

- **Neovim 0.10+**
- **[snacks.nvim](https://github.com/folke/snacks.nvim)** with `image.enabled = true` (the renderer + placement engine)
- **Node.js 18+**
- **A graphics-capable terminal**: Kitty, iTerm2, WezTerm, or Ghostty
- **`mathjax-full`** (npm): `npm install -g mathjax-full`
- **An SVG rasterizer**: ImageMagick + librsvg2 (recommended), or rsvg-convert alone

### Linux

```sh
sudo apt install nodejs imagemagick librsvg2-bin
sudo npm install -g mathjax-full
```

### macOS

```sh
brew install node imagemagick librsvg
npm install -g mathjax-full
```

Run `:checkhealth latex-preview` after install to verify.

## Install

### lazy.nvim

```lua
{
  "your-username/latex-preview.nvim",
  dependencies = { "folke/snacks.nvim" },
  ft = { "tex", "latex", "markdown", "rmd", "quarto" },
  opts = {
    setup_keymap = true,   -- bind <leader>ih in supported filetypes
    cache = true,          -- persist renders to disk
    cache_dir = "aux",     -- default: <texfile-dir>/aux/latex-preview-cache/
  },
}
```

That's the recommended LaTeX-project setup: `<leader>ih` toggles the
popup, and rendered images are cached alongside your build artifacts in
`aux/latex-preview-cache/` rather than a global directory.

Make sure your snacks.nvim setup has `image.enabled = true`. If you're
already using snacks, you probably do.

To make the popup stay on automatically as you move through math, use
Snacks' document float option:

```lua
require("snacks").setup({
  image = {
    enabled = true,
    doc = {
      inline = false,
      float = true,
    },
  },
})
```

### packer.nvim

```lua
use {
  "your-username/latex-preview.nvim",
  config = function() require("latex-preview").setup({}) end,
}
```

### Manual

```sh
git clone https://github.com/your-username/latex-preview.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/latex-preview.nvim
```

## Usage

| Command | Action |
|---|---|
| `:LatexPreview` (or `:LatexPreview toggle`) | Show or close the popup |
| `:LatexPreview show` | Show the popup |
| `:LatexPreview close` | Close it |
| `:LatexPreview auto` | Toggle automatic hover on/off |
| `:LatexPreview auto-on` | Enable automatic hover |
| `:LatexPreview auto-off` | Disable automatic hover |
| `:LatexPreview clear` | Delete cached SVG/PNG files |
| `:LatexPreview stop` | Stop the daemon (auto-respawns next render) |
| `:LatexPreview status` | Print daemon and popup state |
| `:LatexPreview debug` | Open a scratch buffer dumping what would be sent to the daemon for the equation under the cursor — useful for figuring out why a custom macro isn't being picked up |

The popup is a **toggle**: pressing the keymap (or running `:LatexPreview`)
opens the preview if you're inside an equation, and closes it if it's
already open.

Once open, the popup **stays put while your cursor is inside the
equation**. You can edit, move within the equation, scan around — the
preview keeps tracking. As soon as your cursor moves *outside* the
equation, the popup auto-closes. Pressing the toggle key again works
the same as moving out and re-entering.

### Keymapping

The default keymap is `<leader>ih` (mnemonic: "inspect here"), bound in
normal mode in supported filetypes when `setup_keymap = true`. If you'd
rather use a different key (or several), set the `keymap` option:

```lua
require("latex-preview").setup({
  setup_keymap = true,
  keymap = "<leader>ih",            -- single key
  -- keymap = { "<leader>ih", "K" },  -- or multiple
})
```

If you want to wire it up yourself instead, the public API is:

```lua
require("latex-preview").toggle()  -- show or close
require("latex-preview").hover()   -- show only (returns false if no math under cursor)
require("latex-preview").close()   -- close only

vim.keymap.set("n", "<leader>m", function()
  require("latex-preview").toggle()
end)
```

## Configuration

```lua
require("latex-preview").setup({
  enabled = true,
  filetypes = { "tex", "latex", "markdown", "rmd", "quarto" },
  setup_keymap = false,        -- install the toggle key automatically
  keymap = "<leader>ih",       -- the toggle key (or list of keys)

  -- Disk cache is off by default; live hover always uses temp files.
  -- Set cache = true to persist renders across sessions.
  cache = false,
  -- Where to write cached SVG/PNG files. Three forms:
  --   "aux" (default) — <texfile-dir>/aux/latex-preview-cache/
  --                     (falls back to stdpath cache for unsaved buffers)
  --   "/some/path"    — a fixed global directory for all buffers
  --   function(buf)   — called per buffer, return an absolute path
  cache_dir = "aux",

  daemon = {
    cmd = nil,                 -- override daemon command if needed
    max_restarts = 3,
    ready_timeout_ms = 8000,
  },

  extract = {
    scan_sty = true,           -- find macros in local .sty files
    sty_search_depth = 4,      -- walk up this many parent directories
    rewrite_providecommand = true,  -- MathJax compat
    rewrite_edef = true,       -- MathJax compat
  },

  render = {
    fg = function()            -- defaults to current Normal hl fg
      local hl = vim.api.nvim_get_hl(0, { name = "Normal" })
      if hl and hl.fg then return string.format("#%06x", hl.fg) end
      return "#000000"
    end,
    font_size = 12,            -- inline MathJax font size in pixels
    display_font_size = 12,    -- display MathJax font size in pixels
    display_math_style = "text", -- "text" for compact previews, "display" for LaTeX display style
    pad_to_cells = true,       -- prevent terminal-cell rounding from enlarging short equations
    density = 300,             -- DPI for SVG -> PNG
    svg_to_png = "auto",       -- "auto", "rsvg", or "magick"
  },

  popup = {
    -- Defaults to almost the full editor size. Lower these if you want
    -- long equations scaled down instead of opening a larger popup.
    max_width = nil,
    max_height = nil,
    live_update_delay_ms = 300,
  },

  hover = {
    auto_open = nil,        -- nil = follow Snacks image.doc.float
    toggle_keymap = "<leader>iH", -- runtime auto-hover toggle when setup_keymap=true
  },

  snacks = {
    -- Keep snacks.image available for the explicit popup, but disable
    -- Snacks' own document renderer that auto-renders every equation inline.
    disable_document_images = true,
  },

  -- Note: popup sizing, border, padding, and similar visual options still
  -- come from your snacks.nvim image.doc config.
})
```

## How macro detection works

Same approach Overleaf's editor uses:

1. **Scan the buffer** for definition-shaped commands: `\newcommand`,
   `\renewcommand`, `\providecommand`, `\DeclareMathOperator`,
   `\NewDocumentCommand`, `\def`, `\let`, etc. Anything before
   `\begin{document}` is included.

2. **Scan local `.sty` files** referenced via `\usepackage{name}` when
   `name.sty` exists in the buffer's directory or any ancestor.

3. **Normalize for MathJax**: `\providecommand` → `\newcommand` (because
   MathJax's `\providecommand` no-ops on built-in name collisions),
   `\edef` → `\def` (MathJax doesn't do expand-at-definition).

4. **Send to the daemon** as a preamble. MathJax registers the macros
   into its macro table, then renders the equation.

This means custom notation packages "just work" without any per-project
setup.

## What renders

Anything MathJax supports:

- AMS math (`amsmath`, `amssymb`, `mathtools` features)
- Custom macros from buffer or `.sty`
- `\begin{equation}`, `\begin{align}`, `\begin{gather}`, `\begin{multline}`,
  `\begin{cases}`, `\begin{matrix}` and friends
- `\boldsymbol`, `\mathbb`, `\mathcal`, `\mathfrak`, etc.
- `\color`, `\mathcolor`
- `tikz-cd` (commutative diagrams)

Doesn't render: TikZ in math, runtime-evaluated macros (`\ifthenelse`,
counters, lengths), and exotic packages that do more than define macros.
For those, your `pdflatex` compile remains the source of truth.

## Performance (done by Claude)

| | First render | Subsequent |
|---|---|---|
| Daemon boot | ~300–500 ms | 0 |
| MathJax render | ~10–30 ms | ~10–30 ms |
| SVG → PNG | ~20–30 ms | ~20–30 ms |
| Cache hit | n/a | ~1 ms |

Measured on Apple Silicon / Node v25 with rsvg-convert. Older hardware
or Node versions may be slower (daemon boot up to ~1 s on Node v18).

The daemon stays warm for the whole Neovim session. After the first
render, hover popups feel instant — the typical case is a cache hit on
something you've already seen, which returns in ~1 ms.

### Equation scanning (regex fallback)

When treesitter parsers are not available, the plugin falls back to a
regex scan. Consumed byte ranges are tracked as sorted intervals with
binary-search overlap detection rather than marking every byte:

| File size | Equations | Scan time |
|---|---|---|
| ~10 KB | ~50 inline | ~65 µs |
| ~40 KB | ~260 inline | ~250 µs |
| ~150 KB | ~1200 inline | ~900 µs |
| ~500 KB | ~6000 inline | ~4500 µs |

Sub-millisecond for typical files. The treesitter path has no regex
overhead at all.

## Troubleshooting

**Custom `\newcommand` not picked up.** Run `:LatexPreview debug` with
the cursor on the affected equation and inspect the output. If the
preamble section is empty or missing the macro you defined, the issue
is in the extractor — likely your definition uses a form the regex
doesn't recognize, or it appears after `\begin{document}`. If the
preamble looks correct but the equation still renders without the macro
applied, the cache may be holding a stale render from before the macro
existed; run `:LatexPreview clear` and try again.

**`:checkhealth latex-preview` shows errors.** First stop for any install issue.

**The popup doesn't appear.** Check `:LatexPreview status` — does
"terminal supports graphics" say `true`? If not, you're on a terminal
without Kitty graphics protocol support. The plugin needs Kitty,
iTerm2, WezTerm, or Ghostty.

**Specific equation gives "render failed".** Run `:messages` for the
specific error. MathJax doesn't support every TeX command; switch to
your normal compile for those.

**Popup is too big or too small.** Adjust `render.density` (higher =
larger). HiDPI users typically want 600.

**Daemon respawns repeatedly.** `mathjax-full` not in the search path.
Set `LATEX_PREVIEW_MATHJAX_PATH` env var to its install directory, or
`npm install -g mathjax-full` again.

**It's slow on the very first equation.** That's the daemon boot
(~300–500 ms on modern hardware). Every later equation is fast.

## License

MIT
