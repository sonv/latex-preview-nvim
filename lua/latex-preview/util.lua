-- lua/latex-preview/util.lua
--
-- Shared helpers used by multiple modules.

local M = {}

---Return true if the given treesitter language parser is available.
---`parsers` is the result of `require("nvim-treesitter.parsers")`.
---@param parsers table
---@param lang string
---@return boolean
function M.has_ts_parser(parsers, lang)
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

return M
