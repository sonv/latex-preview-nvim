-- lua/latex-preview/hover.lua
--
-- Hover preview, snacks.image-backed.
--
-- The MathJax daemon (via render.lua) produces a PNG. We then hand that
-- PNG to snacks.image's placement machinery, which owns:
--   * Kitty graphics protocol transmission
--   * Unicode-placeholder layout inside a floating window
--   * Auto-close on cursor move / mode change / buffer leave
--   * Reactive resize and redraw
--
-- The implementation here is essentially a port of snacks.image.doc's
-- M.hover() (lua/snacks/image/doc.lua, ~line 369), specialized for the
-- case where we already have a rendered PNG path instead of a TeX source
-- that snacks needs to compile.

local M = {}

local config = require("latex-preview.config")
local parse = require("latex-preview.parse")
local extract = require("latex-preview.extract")
local render = require("latex-preview.render")

---@class LatexPreview.HoverState
---@field win snacks.win
---@field img snacks.image.Placement
---@field buf integer  -- the source buffer (where the cursor was)
---@field source_win integer
---@field eq LatexPreview.Equation  -- the equation that triggered the popup,
---                                 -- so we can detect when the cursor leaves it
---@field render_id integer
---@field signature string
---@field live_svg string?
---@field live_png string?
local current = nil ---@type LatexPreview.HoverState?
local next_render_id = 0
local autocmd_buf = nil
local refresh_timer = nil
local source_keymaps = {} ---@type table<integer, boolean>
local auto_buffers = {} ---@type table<integer, boolean>

local CLOSE_KEYS = { "q", "<Esc>" }

local function auto_group_name(buf)
  return "latex_preview_auto_hover." .. tostring(buf)
end

local function stop_refresh_timer()
  if not refresh_timer then return end
  refresh_timer:stop()
  refresh_timer:close()
  refresh_timer = nil
end

local function close_current()
  if not current then return end
  stop_refresh_timer()
  pcall(function() current.win:close() end)
  pcall(function() current.img:close() end)
  if current.live_svg then pcall(os.remove, current.live_svg) end
  if current.live_png then pcall(os.remove, current.live_png) end
  for buf in pairs(source_keymaps) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, lhs in ipairs(CLOSE_KEYS) do
        pcall(vim.keymap.del, "n", lhs, { buffer = buf })
      end
    end
    source_keymaps[buf] = nil
  end
  autocmd_buf = nil
  current = nil
end

local function map_close_keys(win, source_buf)
  if not win or not win.buf or not vim.api.nvim_buf_is_valid(win.buf) then return end
  for _, lhs in ipairs(CLOSE_KEYS) do
    vim.keymap.set("n", lhs, function()
      close_current()
    end, {
      buffer = win.buf,
      nowait = true,
      silent = true,
      desc = "Close LaTeX preview",
    })
  end
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) and not source_keymaps[source_buf] then
    source_keymaps[source_buf] = true
    for _, lhs in ipairs(CLOSE_KEYS) do
      vim.keymap.set("n", lhs, function()
        close_current()
      end, {
        buffer = source_buf,
        nowait = true,
        silent = true,
        desc = "Close LaTeX preview",
      })
    end
  end
end

---True iff the cursor in the *current* window is inside `eq`'s byte range.
---Used both to find the equation under the cursor at trigger time and to
---decide whether to keep the popup open as the cursor moves.
---@param eq LatexPreview.Equation
local function cursor_in_equation(eq)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local crow, ccol = cursor[1] - 1, cursor[2]
  local after_start = (crow > eq.start_row)
    or (crow == eq.start_row and ccol >= eq.start_col)
  local before_end = (crow < eq.end_row)
    or (crow == eq.end_row and ccol < eq.end_col)
  return after_start and before_end
end

---Return the equation under the cursor (1-based win cursor → 0-based buffer
---coordinates), or nil if none.
---@param buf integer
---@return LatexPreview.Equation?
local function equation_under_cursor(buf)
  local equations = parse.find_equations(buf)
  for _, eq in ipairs(equations) do
    if cursor_in_equation(eq) then return eq end
  end
  return nil
end

local function place_under_cursor(win, source_win)
  if vim.fn.pumvisible() == 1 then return false end
  if not win then return false end
  source_win = source_win or (current and current.source_win) or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(source_win) then return false end
  local cursor = vim.api.nvim_win_get_cursor(source_win)
  local ok, screenpos = pcall(vim.fn.screenpos, source_win, cursor[1], cursor[2] + 1)
  if not ok or not screenpos or screenpos.row == 0 then return false end
  win.opts.relative = "editor"
  win.opts.row = math.min(vim.o.lines - 2, screenpos.row)
  win.opts.col = math.max(0, math.min(vim.o.columns - 2, screenpos.col - 1))
  if win.win and vim.api.nvim_win_is_valid(win.win) then
    pcall(function() win:update() end)
  end
  return true
end

local function show_under_cursor(win, source_win)
  if not place_under_cursor(win, source_win) then return false end
  pcall(function() win:show() end)
  return true
end

local function schedule_open(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.api.nvim_get_current_buf() ~= buf then return end
  if vim.fn.pumvisible() == 1 then return end
  if refresh_timer then
    refresh_timer:stop()
  else
    refresh_timer = assert((vim.uv or vim.loop).new_timer())
  end
  local delay = (config.options.popup or {}).live_update_delay_ms or 300
  refresh_timer:start(delay, 0, function()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
        M.open()
      end
    end)
  end)
end

local function schedule_current_open(buf)
  if not current then return true end
  schedule_open(buf)
end

local function register_autocmds(buf)
  if autocmd_buf == buf then return end
  autocmd_buf = buf
  local group = vim.api.nvim_create_augroup("latex_preview_hover", { clear = true })
  vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
    group = group,
    buffer = buf,
    callback = function()
      if current and current.buf == buf then close_current() end
      return true
    end,
  })
  -- When the buffer already has auto-hover attached, its CursorMoved/
  -- TextChanged/CompleteDone handlers already call M.open(). Registering
  -- them here too would fire M.open() twice per event.
  if auto_buffers[buf] then return end
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      if not current then
        autocmd_buf = nil
        return true
      end
      if not equation_under_cursor(buf) then
        close_current()
        return true
      end
      if vim.fn.pumvisible() == 1 then return end
      M.open()
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      if vim.fn.pumvisible() == 1 then return end
      if schedule_current_open(buf) then
        autocmd_buf = nil
        return true
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteDone", "CompleteDonePre" }, {
    group = group,
    buffer = buf,
    callback = function()
      if not current then return true end
      vim.schedule(function()
        if current then M.open() end
      end)
    end,
  })
end

---Automatically open/update the preview in this buffer when the cursor is
---inside a math expression.
---@param buf integer
function M.attach(buf)
  if auto_buffers[buf] then return end
  auto_buffers[buf] = true
  local group = vim.api.nvim_create_augroup(auto_group_name(buf), { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      if vim.fn.pumvisible() == 1 then return end
      M.open()
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      schedule_open(buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "CompleteDone", "CompleteDonePre" }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
          M.open()
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = buf,
    callback = function()
      if current and current.buf == buf then close_current() end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      auto_buffers[buf] = nil
      if current and current.buf == buf then close_current() end
      return true
    end,
  })

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
      M.open()
    end
  end)
end

---Stop automatically opening/updating previews in this buffer.
---@param buf integer
function M.detach(buf)
  if not auto_buffers[buf] then return end
  auto_buffers[buf] = nil
  pcall(vim.api.nvim_del_augroup_by_name, auto_group_name(buf))
  if current and current.buf == buf then close_current() end
end

---Stop automatically opening/updating previews in every attached buffer.
function M.detach_all()
  local bufs = vim.tbl_keys(auto_buffers)
  for _, buf in ipairs(bufs) do
    M.detach(buf)
  end
end

---True when snacks.image is loaded and its terminal supports placeholder-
---based image placement (Kitty / WezTerm / Ghostty with the right env).
function M.is_supported()
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.image then return false end
  if not snacks.image.terminal or not snacks.image.terminal.env then return false end
  local env = snacks.image.terminal.env()
  return env and env.placeholders == true
end

---Show a hover preview for the math expression under the cursor.
---Returns true if a preview was triggered, false if no equation was found.
---@return boolean
function M.open()
  if vim.fn.pumvisible() == 1 then
    if current then return true end
  end
  local buf = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local eq = equation_under_cursor(buf)
  if not eq then
    -- Closing here lets a caller bind hover() to a key like K and not
    -- have to remember to close on the way out — moving the cursor out
    -- of an equation auto-dismisses.
    close_current()
    return false
  end

  local snacks = require("snacks")
  if config.options.snacks
      and config.options.snacks.disable_document_images
      and snacks.image
      and snacks.image.config then
    snacks.image.config.doc = snacks.image.config.doc or {}
    snacks.image.config.doc.enabled = false
    snacks.image.config.doc.inline = false
  end
  -- Build the request and render. The result is a PNG path (from disk
  -- cache on a hit, ~10-50 ms via the daemon on a miss).
  local preamble = extract.get_preamble(buf)
  local req = {
    preamble = preamble,
    equation = eq.text,
    display = eq.display,
    buf = buf,  -- so render.lua resolves cache_dir per-buffer
    live = true,
  }
  local signature = table.concat({
    preamble or "",
    eq.text or "",
    eq.display and "1" or "0",
    tostring(config.options.render.font_size),
    tostring(config.options.render.display_font_size),
    tostring(config.options.render.display_math_style),
  }, "\n--latex-preview--\n")
  if current and current.signature == signature then
    current.eq = eq
    show_under_cursor(current.win, source_win)
    pcall(function() current.img:update() end)
    return true
  end
  next_render_id = next_render_id + 1
  local render_id = next_render_id
  req.live_id = render_id
  if current then
    current.render_id = render_id
    current.eq = eq
    current.source_win = source_win
    show_under_cursor(current.win, source_win)
  end

  render.render(req, function(err, png_path)
    if current and current.render_id ~= render_id then return end
    if err or not png_path then
      vim.notify("[latex-preview] " .. (err or "render failed"), vim.log.levels.WARN)
      return
    end

    -- If a hover for the same image is already showing, just refresh it.
    -- Otherwise close any previous and open a new one.
    if current and current.img and current.img.img and current.img.img.src == png_path then
      current.eq = eq
      current.source_win = source_win
      show_under_cursor(current.win, source_win)
      pcall(function() current.img:update() end)
      return
    end
    local old_svg = current and current.live_svg
    local old_png = current and current.live_png
    close_current()
    if old_svg then pcall(os.remove, old_svg) end
    if old_png then pcall(os.remove, old_png) end

    -- Open a floating Snacks.win. We piggy-back on snacks's "snacks_image"
    -- style so it shares config (border, winblend, padding) with snacks's
    -- own image hover. The width/height fields are filled in via the
    -- placement's on_update_pre callback once we know the rendered size.
    local win = snacks.win(snacks.win.resolve(snacks.image.config.doc, "snacks_image", {
      show = false,
      enter = false,
      relative = "editor",
      row = 0,
      col = 0,
      wo = { winblend = snacks.image.terminal.env().placeholders and 0 or nil },
    }))
    win:open_buf()
    map_close_keys(win, buf)

    local updated = false
    local popup = config.options.popup or {}
    local max_width = popup.max_width or math.max(1, vim.o.columns - 4)
    local max_height = popup.max_height or math.max(1, vim.o.lines - 4)
    local placement_opts = snacks.config.merge({}, snacks.image.config.doc, {
      inline = false,
      max_width = max_width,
      max_height = max_height,
      -- Use our cache_dir for the placement's working files. Not strictly
      -- necessary (snacks would use its own), but keeps things tidy.
      cache = config.get_cache_dir(buf),
      on_update_pre = function(placement)
        -- Snacks normally prefers ImageMagick's identify metadata, applying
        -- DPI and terminal scale math. For generated equation PNGs we already
        -- control the exact pixel size, so use the PNG header dimensions
        -- directly; otherwise identical font-size renders can look different
        -- depending on rasterizer DPI metadata.
        placement.img.info = nil
        if not updated then
          local loc = placement:state().loc
          win.opts.width = loc.width
          win.opts.height = loc.height
          updated = show_under_cursor(win, source_win)
        end
      end,
    })

    current = {
      win = win,
      buf = buf,
      source_win = source_win,
      eq = eq,
      render_id = render_id,
      signature = signature,
      live_svg = png_path:gsub("%.png$", ".svg"),
      live_png = png_path,
      img = snacks.image.placement.new(win.buf, png_path, placement_opts),
    }
    register_autocmds(buf)
  end)

  return true
end

---Close the current hover, if any.
function M.close()
  close_current()
end

---True when a hover popup is visible.
function M.is_open()
  return current ~= nil
end

return M
