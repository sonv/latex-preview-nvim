-- lua/latex-preview/render.lua
--
-- Render an equation to a PNG file on disk. Pipeline:
--   (preamble, equation, display, color) hashed → cache hit?
--     yes → return cached PNG path
--     no  → daemon.render → SVG → magick/rsvg-convert → PNG → cache
--
-- The cache key is a content hash of all inputs that affect the output.
-- That means editing a \newcommand in your buffer correctly invalidates,
-- and changing the foreground color (e.g. via colorscheme switch) does too.

local M = {}

local uv = vim.uv or vim.loop
local config = require("latex-preview.config")
local daemon = require("latex-preview.daemon")
local pad_warning_shown = false
local temp_cleanup_registered = false

local function temp_base_dir()
  return vim.fn.stdpath("run") .. "/latex-preview"
end

local function temp_dir()
  return temp_base_dir() .. "/" .. tostring(uv.os_getpid())
end

local function process_alive(pid)
  local ok, ret = pcall(uv.kill, pid, 0)
  return ok and (ret == 0 or ret == true)
end

local function cleanup_stale_temp_dirs()
  local base = temp_base_dir()
  if not uv.fs_stat(base) then return end
  local handle = uv.fs_scandir(base)
  local current_pid = uv.os_getpid()
  while handle do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then break end
    local pid = tonumber(name)
    if typ == "directory" and pid and pid ~= current_pid and not process_alive(pid) then
      vim.fn.delete(base .. "/" .. name, "rf")
    end
  end
end

local function ensure_temp_cleanup()
  if temp_cleanup_registered then return end
  temp_cleanup_registered = true
  cleanup_stale_temp_dirs()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("latex_preview_temp_cleanup", { clear = true }),
    callback = function()
      vim.fn.delete(temp_dir(), "rf")
    end,
  })
end

local function effective_font_size(req)
  if req.font_size then return req.font_size end
  if req.display then
    return config.options.render.display_font_size or config.options.render.font_size or 10
  end
  return config.options.render.font_size or 11
end

local function should_pad_to_cells(req)
  if req.pad_to_cells ~= nil then return req.pad_to_cells == true end
  return config.options.render.pad_to_cells == true
end

---@param req { preamble: string, equation: string, display: boolean, pad_to_cells: boolean? }
---@return string  cache key suitable for use as a filename stem
local function cache_key(req)
  local renderer_version = "raster-v8"
  local fg = config.get_fg()
  local font_size = effective_font_size(req)
  local density = config.options.render.density
  -- Avoid \0 separators because vim.fn.sha256 treats embedded NULs as a
  -- Blob signal and refuses string input. Newlines are safe and the
  -- collision risk is negligible for our use.
  local raw = table.concat({
    req.preamble or "",
    req.equation or "",
    req.display and "1" or "0",
    fg,
    tostring(font_size),
    tostring(config.options.render.display_math_style),
    tostring(should_pad_to_cells(req)),
    tostring(density),
    renderer_version,
  }, "\n--latex-preview--\n")
  return vim.fn.sha256(raw):sub(1, 16)
end

---Ensure the cache directory exists for this buffer.
---@param buf integer
---@return string
local function ensure_cache_dir(buf)
  local dir = config.get_cache_dir(buf)
  if not uv.fs_stat(dir) then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

---@param buf integer
---@param id integer?
---@return string
local function temp_stem(buf, id)
  ensure_temp_cleanup()
  local dir = temp_dir()
  if not uv.fs_stat(dir) then
    vim.fn.mkdir(dir, "p")
  end
  return dir .. "/" .. tostring(buf) .. "-" .. tostring(id or 0)
end

---Run an external process, async. Returns via cb(err, stdout).
---@param cmd string
---@param args string[]
---@param cb fun(err: string?, code: integer)
local function spawn(cmd, args, cb)
  if vim.fn.executable(cmd) == 0 then
    return cb("`" .. cmd .. "` not found in PATH", -1)
  end
  local stderr = uv.new_pipe()
  local stderr_buf = {}
  local handle
  handle = uv.spawn(cmd, {
    args = args,
    stdio = { nil, nil, stderr },
    hide = true,
  }, function(code)
    stderr:read_stop()
    stderr:close()
    if handle then handle:close() end
    vim.schedule(function()
      if code ~= 0 then
        cb(table.concat(stderr_buf, ""), code)
      else
        cb(nil, code)
      end
    end)
  end)
  if not handle then
    stderr:close()
    return cb("spawn failed: " .. cmd, -1)
  end
  stderr:read_start(function(_, data)
    if data then table.insert(stderr_buf, data) end
  end)
end

---Convert SVG file to PNG file via the configured tool.
---@param svg_path string
---@param png_path string
---@param cb fun(err: string?)
local function svg_to_png(svg_path, png_path, cb)
  local tool = config.options.render.svg_to_png
  local density = config.options.render.density
  if tool == "auto" then
    tool = vim.fn.executable("rsvg-convert") == 1 and "rsvg" or "magick"
  end
  if tool == "rsvg" then
    -- rsvg-convert handles MathJax's SVG/currentColor output reliably.
    local zoom = density / 96
    spawn("rsvg-convert", {
      "-d", tostring(density),
      "-p", tostring(density),
      "-z", tostring(zoom),
      "-b", "transparent",
      "-o", png_path,
      svg_path,
    }, function(err) cb(err) end)
  else
    -- ImageMagick. Either `magick` (v7) or `convert` (v6) exists.
    local bin = vim.fn.executable("magick") == 1 and "magick" or "convert"
    spawn(bin, {
      "-density", tostring(density),
      "-background", "none",
      svg_path,
      "-trim",
      png_path,
    }, function(err) cb(err) end)
  end
end

---@param png_path string
---@return integer?, integer?
local function png_size(png_path)
  local fd = io.open(png_path, "rb")
  if not fd then return nil, nil end
  local header = fd:read(24)
  fd:close()
  if not header or header:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil, nil
  end
  local width = header:byte(17) * 16777216 + header:byte(18) * 65536
    + header:byte(19) * 256 + header:byte(20)
  local height = header:byte(21) * 16777216 + header:byte(22) * 65536
    + header:byte(23) * 256 + header:byte(24)
  return width, height
end

---@param png_path string
---@param cb fun(err: string?)
local function pad_to_cells(png_path, cb)
  if not config.options.render.pad_to_cells then return cb(nil) end
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.image or not snacks.image.terminal then return cb(nil) end
  local term = snacks.image.terminal.size()
  if not term or not term.cell_width or not term.cell_height then return cb(nil) end

  local width, height = png_size(png_path)
  if not width or not height then return cb(nil) end
  local target_width = math.max(1, math.ceil(width / term.cell_width) * term.cell_width)
  local target_height = math.max(1, math.ceil(height / term.cell_height) * term.cell_height)
  if target_width == width and target_height == height then return cb(nil) end

  local bin = vim.fn.executable("magick") == 1 and "magick"
    or (vim.fn.executable("convert") == 1 and "convert" or nil)
  if not bin then
    if not pad_warning_shown then
      pad_warning_shown = true
      vim.notify(
        "[latex-preview] render.pad_to_cells=true but ImageMagick is not available; "
          .. "equation images may be scaled by the terminal",
        vim.log.levels.WARN
      )
    end
    return cb(nil)
  end
  -- Write to a sibling temp file first so a mid-write crash can't corrupt
  -- the cached PNG. Same directory → same filesystem → rename is atomic.
  local tmp = png_path .. ".tmp"
  spawn(bin, {
    png_path,
    "-background", "none",
    "-gravity", "center",
    "-extent", ("%dx%d"):format(target_width, target_height),
    tmp,
  }, function(err)
    if err then
      pcall(os.remove, tmp)
      return cb(err)
    end
    if not os.rename(tmp, png_path) then
      pcall(os.remove, tmp)
      return cb("pad_to_cells: rename failed")
    end
    cb(nil)
  end)
end

-- Public API ----------------------------------------------------------------

---Render an equation to a PNG. If already cached, calls cb synchronously
---with the cached path on the next tick. Otherwise dispatches to the
---daemon → rasterizer pipeline.
---
---@param req { preamble: string, equation: string, display: boolean, buf: integer?, live: boolean?, live_id: integer?, font_size: integer?, pad_to_cells: boolean? }
---@param cb fun(err: string?, png_path: string?)
function M.render(req, cb)
  -- buf is optional for backward compatibility and for tests that don't
  -- need per-buffer cache_dir resolution. When omitted we use buf 0
  -- (current), which the resolver will treat as either the active buffer
  -- (when called from the editor) or fall through to the global cache.
  local buf = req.buf or 0
  local buf_modified = (buf ~= 0 and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified)
    or (buf == 0 and vim.bo.modified)
  local use_cache = config.options.cache and not req.live and not buf_modified
  local key = cache_key(req)
  local svg_path
  local png_path
  if use_cache then
    local dir = ensure_cache_dir(buf)
    svg_path = dir .. "/" .. key .. ".svg"
    png_path = dir .. "/" .. key .. ".png"
  else
    local stem = temp_stem(buf, req.live_id)
    svg_path = stem .. ".svg"
    png_path = stem .. ".png"
  end

  -- Cache hit? Check the PNG specifically — if the SVG is there but the
  -- PNG isn't, the rasterizer crashed mid-step and we want to retry.
  if use_cache and uv.fs_stat(png_path) then
    return vim.schedule(function() cb(nil, png_path) end)
  end

  local fg_hex = config.get_fg():gsub("^#", "")
  daemon.render({
    preamble = req.preamble or "",
    equation = req.equation,
    display = req.display,
    color = fg_hex,
    font_size = effective_font_size(req),
    display_math_style = config.options.render.display_math_style,
  }, function(err, svg)
    if err then return cb(err, nil) end
    if not svg then return cb("daemon returned no svg", nil) end
    -- Write SVG.
    local fd = io.open(svg_path, "w")
    if not fd then return cb("cannot open " .. svg_path .. " for write", nil) end
    fd:write(svg)
    fd:close()
    -- Rasterize.
    svg_to_png(svg_path, png_path, function(rerr)
      if rerr then return cb(rerr, nil) end
      if not should_pad_to_cells(req) then return cb(nil, png_path) end
      pad_to_cells(png_path, function(perr)
        if perr then return cb(perr, nil) end
        cb(nil, png_path)
      end)
    end)
  end)
end

---Clear the cache directory for a given buffer (defaults to current).
---Returns count of files removed. Note: with cache_dir = "aux", different
---buffers in different directories have different caches; this only
---clears the one for `buf`.
---@param buf integer? defaults to current buffer
function M.clear_cache(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local dir = config.get_cache_dir(buf)
  if not uv.fs_stat(dir) then return 0 end
  local handle = uv.fs_scandir(dir)
  local removed = 0
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    if name:match("%.svg$")
        or name:match("%.png$")
        or name:match("%.tex$")
        or name:match("%.pdf$")
        or name:match("%.log$")
        or name:match("%.aux$") then
      os.remove(dir .. "/" .. name)
      removed = removed + 1
    end
  end
  return removed
end

return M
