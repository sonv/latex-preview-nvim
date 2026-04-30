-- lua/latex-preview/parse.lua
--
-- Find math expressions in a buffer. Returns a list of {start_row,
-- end_row, text, display} entries.
--
-- Strategy:
--   * If treesitter has the `latex` parser installed (or `markdown_inline`
--     for markdown buffers), use treesitter queries — robust against `$`
--     in comments, verbatim, etc.
--   * Otherwise fall back to a regex pass that's good enough for typical
--     content. The regex path correctly handles \$, line-spanning $$...$$
--     blocks, \[ ... \] blocks, and \begin{equation} ... \end{equation}.
--
-- Coordinates are 0-indexed rows in the buffer (matches extmark API).

local M = {}

---@class LatexPreview.Equation
---@field start_row integer 0-indexed inclusive
---@field start_col integer 0-indexed inclusive
---@field end_row integer 0-indexed inclusive
---@field end_col integer 0-indexed exclusive
---@field text string The math content WITHOUT outer delimiters.
---@field display boolean True for display-mode (\[, $$, \begin{equation*}, ...).

-- Treesitter path -----------------------------------------------------------

local TS_QUERIES = {
  latex = [[
    (inline_formula) @inline
    (displayed_equation) @display
    (math_environment) @display
  ]],
  markdown_inline = [[
    (latex_block) @any
  ]],
}

---@param parsers table
---@param lang string
---@return boolean
local function has_ts_parser(parsers, lang)
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

---@param buf integer
---@param lang string
---@return LatexPreview.Equation[]?
local function ts_extract(buf, lang)
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok or not has_ts_parser(parsers, lang) then return nil end

  local parser = vim.treesitter.get_parser(buf, lang)
  if not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end

  local query_str = TS_QUERIES[lang]
  if not query_str then return nil end

  local query = vim.treesitter.query.parse(lang, query_str)
  local results = {}
  for id, node in query:iter_captures(tree:root(), buf) do
    local cap = query.captures[id]
    local sr, sc, er, ec = node:range()
    local text = vim.treesitter.get_node_text(node, buf) or ""
    local display = cap == "display"
    if cap == "any" then
      -- markdown_inline produces a `latex_block` for both inline and display.
      -- Differentiate by leading delimiter.
      display = text:match("^%$%$") or text:match("^\\%[") or text:match("^\\begin")
    end
    -- Strip the outer delimiters so we can pass clean math to MathJax.
    local stripped = text
      :gsub("^%$%$", ""):gsub("%$%$$", "")
      :gsub("^%$", ""):gsub("%$$", "")
      :gsub("^\\%[", ""):gsub("\\%]$", "")
      :gsub("^\\%(", ""):gsub("\\%)$", "")
    stripped = vim.trim(stripped)
    if stripped ~= "" then
      results[#results + 1] = {
        start_row = sr, start_col = sc,
        end_row = er, end_col = ec,
        text = stripped,
        display = display and true or false,
      }
    end
  end
  return results
end

-- Regex fallback ------------------------------------------------------------

---@param buf integer
---@return LatexPreview.Equation[]
local function regex_extract(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local source = table.concat(lines, "\n")
  local results = {}

  -- For each match, we need to convert byte offsets back to (row, col).
  -- Build a row-start table.
  local row_starts = { 0 }
  local pos = 1
  while true do
    local nl = source:find("\n", pos, true)
    if not nl then break end
    row_starts[#row_starts + 1] = nl
    pos = nl + 1
  end
  local function byte_to_rc(byte)
    -- binary search would be faster but row_starts is at most a few thousand
    local lo, hi = 1, #row_starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if row_starts[mid] <= byte then lo = mid else hi = mid - 1 end
    end
    return lo - 1, byte - row_starts[lo]
  end

  -- Patterns ordered by specificity. Track consumed byte ranges as a
  -- sorted list of {lo, hi} intervals; overlap checks are O(log n) via
  -- binary search instead of O(range_size) via byte iteration.
  local consumed = {}
  local function not_consumed(s, e)
    local lo, hi = 1, #consumed
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local iv = consumed[mid]
      if iv[2] < s then lo = mid + 1
      elseif iv[1] > e then hi = mid - 1
      else return false end
    end
    return true
  end
  local function mark(s, e)
    consumed[#consumed + 1] = { s, e }
    local n = #consumed
    while n > 1 and consumed[n - 1][1] > s do
      consumed[n - 1], consumed[n] = consumed[n], consumed[n - 1]
      n = n - 1
    end
  end

  -- Each entry: {pattern, display, kind}
  -- kind:
  --   "delim_match"  the capture is the math text directly
  --   "env"          extract body via a separate match (env name varies)
  local patterns = {
    -- $$...$$ display, line-spanning. The capture is the body.
    { pat = "%$%$(.-)%$%$",          display = true,  kind = "delim_match" },
    -- \[...\] display
    { pat = "\\%[(.-)\\%]",          display = true,  kind = "delim_match" },
    -- \(...\) inline
    { pat = "\\%((.-)\\%)",          display = false, kind = "delim_match" },
    -- Math environments. We match a generic \begin{name}...\end{name} where
    -- name is one of equation/align/gather/multline (with optional star).
    { pat = "\\begin{equation%*?}(.-)\\end{equation%*?}", display = true, kind = "delim_match" },
    { pat = "\\begin{align%*?}(.-)\\end{align%*?}",       display = true, kind = "delim_match" },
    { pat = "\\begin{gather%*?}(.-)\\end{gather%*?}",     display = true, kind = "delim_match" },
    { pat = "\\begin{multline%*?}(.-)\\end{multline%*?}", display = true, kind = "delim_match" },
  }

  for _, p in ipairs(patterns) do
    local pos2 = 1
    while pos2 <= #source do
      local s, e, body = source:find(p.pat, pos2)
      if not s then break end
      if not_consumed(s, e) then
        local text = vim.trim(body or "")
        if text ~= "" then
          local sr, sc = byte_to_rc(s - 1)
          local er, ec = byte_to_rc(e)
          results[#results + 1] = {
            start_row = sr, start_col = sc,
            end_row = er, end_col = ec,
            text = text,
            display = p.display,
          }
          mark(s, e)
        end
      end
      pos2 = e + 1
    end
  end

  -- Inline $...$. Done last because $$..$$ and \begin{...} contain $ chars
  -- that would otherwise be treated as inline math. We also need to skip
  -- escaped dollars (\$). Strategy: walk byte-by-byte, find an unescaped
  -- $, look for a matching unescaped $ on the same line, and confirm the
  -- range doesn't overlap with anything already consumed.
  local function unescaped_at(idx)
    if idx == 1 then return source:sub(idx, idx) == "$" end
    return source:sub(idx, idx) == "$" and source:sub(idx - 1, idx - 1) ~= "\\"
  end

  local i = 1
  while i <= #source do
    if unescaped_at(i) and not consumed[i] then
      -- Find closing $ on the same line
      local j = i + 1
      local closed = nil
      while j <= #source do
        local c = source:sub(j, j)
        if c == "\n" then break end
        if c == "$" and source:sub(j - 1, j - 1) ~= "\\" then
          closed = j
          break
        end
        j = j + 1
      end
      if closed and not_consumed(i, closed) then
        local body = source:sub(i + 1, closed - 1)
        body = vim.trim(body)
        if body ~= "" then
          local sr, sc = byte_to_rc(i - 1)
          local er, ec = byte_to_rc(closed)
          results[#results + 1] = {
            start_row = sr, start_col = sc,
            end_row = er, end_col = ec,
            text = body,
            display = false,
          }
          mark(i, closed)
        end
        i = closed + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  -- Sort by start position so the manager can render them in document order.
  table.sort(results, function(a, b)
    if a.start_row ~= b.start_row then return a.start_row < b.start_row end
    return a.start_col < b.start_col
  end)
  return results
end

-- Public API ----------------------------------------------------------------

---@param buf integer
---@return LatexPreview.Equation[]
function M.find_equations(buf)
  local ft = vim.bo[buf].filetype
  -- Prefer treesitter for the fileytpes where we have a query.
  if ft == "tex" or ft == "latex" or ft == "plaintex" then
    local r = ts_extract(buf, "latex")
    if r then return r end
  elseif ft == "markdown" or ft == "rmd" or ft == "quarto" then
    local r = ts_extract(buf, "markdown_inline")
    if r then return r end
  end
  return regex_extract(buf)
end

return M
