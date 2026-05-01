-- lua/latex-preview/init.lua
--
-- Public API for hover-based math preview.

local M = {}

local config = require("latex-preview.config")

local function is_supported_filetype(ft)
  return vim.tbl_contains(config.options.filetypes or {}, ft)
end

local function snacks_image_config()
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.image or not snacks.image.config then return nil end
  return snacks, snacks.image.config
end

-- When hover.auto_open is nil (the default), auto-hover follows Snacks'
-- image.doc.float setting. This lets users control both snacks image hover
-- and this plugin's auto-hover with a single toggle. Set hover.auto_open
-- explicitly to true/false to decouple from Snacks' preference.
local function snacks_doc_float_enabled()
  local _, image_config = snacks_image_config()
  local doc = image_config and image_config.doc or {}
  return doc.float == true
end

local function auto_hover_enabled()
  local hover = config.options.hover or {}
  if hover.auto_open ~= nil then return hover.auto_open == true end
  return snacks_doc_float_enabled()
end

local function ensure_auto_hover_autocmd()
  local group = vim.api.nvim_create_augroup("latex_preview_auto_attach", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = config.options.filetypes,
    callback = function(args)
      if M.auto_hover_enabled() then
        require("latex-preview.hover").attach(args.buf)
      end
    end,
  })
end

local function attach_auto_hover_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and is_supported_filetype(vim.bo[buf].filetype) then
      require("latex-preview.hover").attach(buf)
    end
  end
end

local function install_auto_hover_toggle()
  local hover_opts = config.options.hover or {}
  if not config.options.setup_keymap or not hover_opts.toggle_keymap then return end

  local snacks = snacks_image_config()
  if snacks and snacks.toggle then
    snacks.toggle({
      id = "latex_preview_auto_hover",
      name = "LaTeX Preview Auto Hover",
      get = function() return M.auto_hover_enabled() end,
      set = function(state) M.set_auto_hover(state) end,
    }):map(hover_opts.toggle_keymap)
    return
  end

  vim.keymap.set("n", hover_opts.toggle_keymap, function()
    M.toggle_auto_hover()
  end, {
    desc = "Toggle LaTeX preview auto hover",
  })
end

local function install_feature_toggle(id, name, opts, get, set)
  if not config.options.setup_keymap or not opts or not opts.toggle_keymap then return end

  local snacks = snacks_image_config()
  if snacks and snacks.toggle then
    snacks.toggle({
      id = id,
      name = name,
      get = get,
      set = set,
    }):map(opts.toggle_keymap)
    return
  end

  vim.keymap.set("n", opts.toggle_keymap, function()
    set(not get())
  end, {
    desc = "Toggle " .. name,
  })
end

local function disable_snacks_document_images()
  local snacks, image_config = snacks_image_config()
  if not image_config then return end

  image_config.doc = image_config.doc or {}
  image_config.doc.enabled = false
  image_config.doc.inline = false

  -- If snacks.image.setup() already ran, it may already have installed a
  -- FileType autocmd that attaches its document renderer. Remove only that
  -- autocmd; keep Snacks' image-buffer and cleanup autocmds intact.
  local ok_autocmds, autocmds = pcall(vim.api.nvim_get_autocmds, {
    group = "snacks.image",
    event = "FileType",
  })
  if ok_autocmds then
    for _, autocmd in ipairs(autocmds) do
      -- Snacks' document renderer installs one broad FileType autocmd. Keep
      -- any future filetype-specific handlers in the same group intact.
      if autocmd.pattern == nil or autocmd.pattern == "*" then
        pcall(vim.api.nvim_del_autocmd, autocmd.id)
      end
    end
  end

  -- Detach any inline placements that were already created before
  -- latex-preview.nvim was configured.
  if snacks.image.placement and snacks.image.placement.clean then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[buf].snacks_image_attached then
        vim.b[buf].snacks_image_attached = false
        pcall(snacks.image.placement.clean, buf)
      end
    end
  end
end

---@param opts? LatexPreview.Config
function M.setup(opts)
  config.setup(opts)
  if not config.options.enabled then return end
  if config.options.snacks and config.options.snacks.disable_document_images then
    disable_snacks_document_images()
  end

  ensure_auto_hover_autocmd()
  if auto_hover_enabled() then attach_auto_hover_buffers() end
  install_auto_hover_toggle()
  install_feature_toggle(
    "latex_preview_references",
    "LaTeX Preview References",
    config.options.references,
    function() return M.references_enabled() end,
    function(state) M.set_references(state) end
  )
  install_feature_toggle(
    "latex_preview_citations",
    "LaTeX Preview Citations",
    config.options.citations,
    function() return M.citations_enabled() end,
    function(state) M.set_citations(state) end
  )

  -- Optional: install a default keymap on entering a supported filetype.
  -- The mapping is `ih` (mnemonic: "inspect here"). It's not a normal-
  -- mode default like `K` because we don't want to fight LSP hover or
  -- the user's existing `K` binding — `ih` is unused by core Vim and by
  -- most plugins.
  --
  -- The mapping is a *toggle*: pressing it inside a math expression
  -- shows the popup; pressing it again closes the popup (or shows a
  -- different equation if the cursor moved).
  if config.options.setup_keymap then
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("latex_preview_keymap", { clear = true }),
      pattern = config.options.filetypes,
      callback = function(args)
        local keys = config.options.keymap
        if type(keys) == "string" then keys = { keys } end
        for _, key in ipairs(keys) do
          vim.keymap.set("n", key, function() M.toggle() end, {
            buffer = args.buf,
            desc = "Toggle LaTeX math preview popup",
          })
        end
      end,
    })
  end
end

---Whether automatic hover preview is currently enabled.
---@return boolean
function M.auto_hover_enabled()
  return auto_hover_enabled()
end

---Enable or disable automatic hover preview at runtime.
---@param state boolean
function M.set_auto_hover(state)
  local _, image_config = snacks_image_config()
  if image_config then
    image_config.doc = image_config.doc or {}
    image_config.doc.float = state
    image_config.doc.inline = false
    image_config.doc.enabled = false
    config.options.hover = config.options.hover or {}
    config.options.hover.auto_open = nil
  else
    config.options.hover = config.options.hover or {}
    config.options.hover.auto_open = state
  end

  if state then
    ensure_auto_hover_autocmd()
    attach_auto_hover_buffers()
  else
    pcall(vim.api.nvim_del_augroup_by_name, "latex_preview_auto_attach")
    require("latex-preview.hover").detach_all()
  end
end

---Toggle automatic hover preview at runtime.
---@return boolean
function M.toggle_auto_hover()
  local state = not M.auto_hover_enabled()
  M.set_auto_hover(state)
  return state
end

---Whether reference hover previews are currently enabled.
---@return boolean
function M.references_enabled()
  return config.options.references and config.options.references.enabled == true
end

---Enable or disable reference hover previews at runtime.
---@param state boolean
function M.set_references(state)
  config.options.references = config.options.references or {}
  config.options.references.enabled = state == true
  if not state then require("latex-preview.hover").close() end
end

---Toggle reference hover previews at runtime.
---@return boolean
function M.toggle_references()
  local state = not M.references_enabled()
  M.set_references(state)
  return state
end

---Whether citation hover previews are currently enabled.
---@return boolean
function M.citations_enabled()
  return config.options.citations and config.options.citations.enabled == true
end

---Enable or disable citation hover previews at runtime.
---@param state boolean
function M.set_citations(state)
  config.options.citations = config.options.citations or {}
  config.options.citations.enabled = state == true
  if not state then require("latex-preview.hover").close() end
end

---Toggle citation hover previews at runtime.
---@return boolean
function M.toggle_citations()
  local state = not M.citations_enabled()
  M.set_citations(state)
  return state
end

---Show a hover preview for the equation under the cursor.
---Returns true if a preview was triggered, false if there's no equation
---under the cursor (so the caller can fall through to LSP hover).
---@return boolean
function M.hover()
  return require("latex-preview.hover").open()
end

---Toggle the hover popup: open if not visible (and the cursor is in a
---math expression), close if visible. Returns true if the popup is
---visible *after* the toggle.
---@return boolean
function M.toggle()
  local hover = require("latex-preview.hover")
  if hover.is_open() then
    hover.close()
    return false
  end
  return hover.open()
end

---Close the current hover popup, if any.
function M.close()
  require("latex-preview.hover").close()
end

---Is the hover popup currently visible?
function M.is_open()
  return require("latex-preview.hover").is_open()
end

---Clear the on-disk render cache. Returns the number of files removed.
function M.clear_cache()
  return require("latex-preview.render").clear_cache()
end

---Stop the daemon. The next render re-spawns it.
function M.stop_daemon()
  require("latex-preview.daemon").shutdown()
end

return M
