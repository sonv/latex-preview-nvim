-- lua/latex-preview/extract.lua
--
-- Definition extractor. Walks a LaTeX buffer (and any local .sty files
-- referenced via \usepackage{name}) for "definition-shaped" commands and
-- emits a single concatenated preamble string ready to send to MathJax.
--
-- Supports: \newcommand, \renewcommand, \providecommand, \DeclareMathOperator,
-- \DeclarePairedDelimiter, \NewDocumentCommand, \RenewDocumentCommand,
-- \newenvironment, \renewenvironment, \def, \gdef, \edef, \let, \newcounter.
--
-- This is the same approach Overleaf's editor uses — a syntax-aware
-- text scan, not a full TeX parser. Failure modes:
--   * Multi-line definitions inside \makeatletter…\makeatother blocks may
--     parse incorrectly because @ becomes a letter
--   * Conditional definitions (\@ifundefined, \ifthenelse) are taken as-is
--     and will fail in MathJax
--   * \ProvidesPackage / \RequirePackage / \DeclareOption are extracted
--     too, but MathJax silently ignores them via the daemon's per-line retry

local M = {}

local uv = vim.uv or vim.loop
local config = require("latex-preview.config")

-- Patterns that mark a line as carrying a macro/environment definition.
local DEF_PATTERNS = {
  "\\newcommand%s*[%*]?%s*[{\\]",
  "\\renewcommand%s*[%*]?%s*[{\\]",
  "\\providecommand%s*[%*]?%s*[{\\]",
  "\\DeclareRobustCommand%s*[%*]?%s*[{\\]",
  "\\DeclareMathOperator%s*[%*]?%s*{",
  "\\DeclarePairedDelimiter%s*{",
  "\\DeclarePairedDelimiterX%s*{",
  "\\newdelim%s*[{\\]",
  "\\newdelimX%s*\\",
  "\\NewDocumentCommand%s*[{\\]",
  "\\RenewDocumentCommand%s*[{\\]",
  "\\ProvideDocumentCommand%s*[{\\]",
  "\\newenvironment%s*[%*]?%s*{",
  "\\renewenvironment%s*[%*]?%s*{",
  "\\def%s*\\",
  "\\gdef%s*\\",
  "\\edef%s*\\",
  "\\let%s*\\",
  "\\newcounter%s*{",
}

local function is_def_line(line)
  for _, p in ipairs(DEF_PATTERNS) do
    if line:find(p) then return true end
  end
  return false
end

---Strip line comments. Respects `\%` as a literal percent.
local function strip_comment(line)
  local i = 1
  while true do
    local p = line:find("%", i, true)
    if not p then return line end
    if p == 1 or line:sub(p - 1, p - 1) ~= "\\" then
      return line:sub(1, p - 1)
    end
    i = p + 1
  end
end

---Walk lines and extract complete definitions. Multi-line definitions are
---tracked by brace depth.
---@param lines string[]
---@return string
function M.extract_definitions(lines)
  local out = {}
  local i, n = 1, #lines
  while i <= n do
    local raw = lines[i]
    local line = strip_comment(raw)
    -- Stop at \begin{document}; everything after is body, not preamble.
    if line:find("\\begin{document}", 1, true) then break end

    if is_def_line(line) then
      local block = { raw }
      local depth, started = 0, false
      local function update(s)
        local k = 1
        while k <= #s do
          local c = s:sub(k, k)
          if c == "\\" and k < #s then k = k + 2
          else
            if c == "{" then depth = depth + 1; started = true
            elseif c == "}" then depth = depth - 1 end
            k = k + 1
          end
        end
      end
      update(line)
      -- Single-line forms: \def\foo{...}, \let\a\b, \edef\foo{...}.
      -- These either have one brace pair on the same line (caught by the
      -- depth check below) or no braces at all (\let). For \let we bail
      -- immediately after the first line; the multi-line continuation is
      -- only for the brace-balanced forms.
      local is_brace_free_form = line:find("\\let%s*\\") and not line:find("{")
      if is_brace_free_form then
        out[#out + 1] = block[1]
        i = i + 1
        goto continue_outer
      end
      while (not started or depth > 0) and i < n do
        i = i + 1
        local more = lines[i]
        block[#block + 1] = more
        update(strip_comment(more))
      end
      out[#out + 1] = table.concat(block, "\n")
    end
    i = i + 1
    ::continue_outer::
  end
  return table.concat(out, "\n")
end

---@param line string
---@param cmd string
---@return string[]
local function braced_args_after_command(line, cmd)
  local args = {}
  local i = 1
  while true do
    local s, e = line:find("\\" .. cmd .. "%f[%A]", i)
    if not s then break end
    local p = e + 1
    while line:sub(p, p):match("%s") do p = p + 1 end
    if line:sub(p, p) == "[" then
      local close = line:find("]", p + 1, true)
      if close then p = close + 1 end
      while line:sub(p, p):match("%s") do p = p + 1 end
    end
    if line:sub(p, p) == "{" then
      local depth = 0
      local j = p
      while j <= #line do
        local c = line:sub(j, j)
        if c == "\\" then
          j = j + 1
        elseif c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
          if depth == 0 then
            args[#args + 1] = line:sub(p + 1, j - 1)
            i = j + 1
            break
          end
        end
        j = j + 1
      end
    else
      i = e + 1
    end
  end
  return args
end

---@param line string
---@return string[]
local function package_names_from_line(line)
  local names = {}
  for _, cmd in ipairs({ "usepackage", "RequirePackage" }) do
    for _, arg in ipairs(braced_args_after_command(line, cmd)) do
      for name in arg:gmatch("[^,%s]+") do
        names[#names + 1] = name
      end
    end
  end
  return names
end

---@param line string
---@return string[]
local function input_names_from_line(line)
  local names = {}
  for _, cmd in ipairs({ "input", "include" }) do
    for _, arg in ipairs(braced_args_after_command(line, cmd)) do
      if arg ~= "" then names[#names + 1] = arg end
    end
  end
  return names
end

---Read a file as a list of lines.
local function read_lines(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local lines = {}
  for line in fd:lines() do lines[#lines + 1] = line end
  fd:close()
  return lines
end

---@param name string
---@return string[]
local function candidate_file_names(name)
  if name:match("%.sty$") or name:match("%.tex$") then return { name } end
  return { name .. ".sty", name .. ".tex" }
end

---@param start_dir string
---@param name string
---@param depth_cap integer
---@return string?
local function find_local_tex_file(start_dir, name, depth_cap)
  local dir, depth = start_dir, 0
  while dir and dir ~= "" and dir ~= "/" and depth < depth_cap do
    for _, fname in ipairs(candidate_file_names(name)) do
      local cand = dir .. "/" .. fname
      if uv.fs_stat(cand) then return cand end
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then break end
    dir, depth = parent, depth + 1
  end
  return nil
end

---Find local .sty files reachable from this buffer's directory and extract
---their definitions. The "reachability" rule: for each \usepackage{name},
---\RequirePackage{name}, or \input{name} in the buffer's preamble, look for
---matching local .sty/.tex files in the buffer's directory and parents.
---@param buf integer
---@return string
function M.scan_sty_files(buf)
  local self_path = vim.api.nvim_buf_get_name(buf)
  if self_path == "" then return "" end
  local start_dir = vim.fs.dirname(vim.fn.fnamemodify(self_path, ":p"))

  local queue = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    line = strip_comment(line)
    if line:find("\\begin{document}", 1, true) then break end
    vim.list_extend(queue, package_names_from_line(line))
    vim.list_extend(queue, input_names_from_line(line))
  end
  if #queue == 0 then return "" end

  local seen_name, seen_file, found = {}, {}, {}
  local depth_cap = config.options.extract.sty_search_depth
  local qi = 1
  while qi <= #queue do
    local name = queue[qi]
    qi = qi + 1
    if not seen_name[name] then
      seen_name[name] = true
      local path = find_local_tex_file(start_dir, name, depth_cap)
      if path and not seen_file[path] then
        seen_file[path] = true
        found[#found + 1] = path
        local lines = read_lines(path)
        if lines then
          for _, line in ipairs(lines) do
            line = strip_comment(line)
            vim.list_extend(queue, package_names_from_line(line))
            vim.list_extend(queue, input_names_from_line(line))
          end
        end
      end
    end
  end
  if #found == 0 then return "" end

  local parts = {}
  for _, sty in ipairs(found) do
    local lines = read_lines(sty)
    if lines then
      local defs = M.extract_definitions(lines)
      if defs ~= "" then
        parts[#parts + 1] = "% from " .. vim.fn.fnamemodify(sty, ":t")
        parts[#parts + 1] = defs
      end
    end
  end
  return table.concat(parts, "\n")
end

---@param preamble string
---@return string
local function normalize_for_mathjax(preamble)
  -- MathJax supports \newcommand well, but common LaTeX declaration helpers
  -- such as \DeclareMathOperator are not themselves macro definitions in
  -- MathJax's TeX input. Convert the simple forms we can recognize.
  preamble = preamble:gsub(
    "\\DeclareMathOperator%s*%*?%s*{%s*(\\[%a@]+)%s*}%s*{([^{}\n]*)}",
    function(cmd, body)
      return "\\newcommand{" .. cmd .. "}{\\operatorname{" .. body .. "}}"
    end
  )
  preamble = preamble:gsub(
    "\\DeclarePairedDelimiter%s*{%s*(\\[%a@]+)%s*}%s*{([^{}\n]*)}%s*{([^{}\n]*)}",
    function(cmd, left, right)
      local open = left == "." and "" or "\\left" .. left
      local close = right == "." and "" or "\\right" .. right
      return "\\newcommand{" .. cmd .. "}[1]{" .. open .. " #1 " .. close .. "}"
    end
  )
  preamble = preamble:gsub(
    "\\newdelim%s*{%s*(\\[%a@]+)%s*}%s*{([^{}\n]*)}%s*{([^{}\n]*)}",
    function(cmd, left, right)
      local open = left == "." and "" or "\\left" .. left
      local close = right == "." and "" or "\\right" .. right
      return "\\newcommand{" .. cmd .. "}[1]{" .. open .. " #1 " .. close .. "}"
    end
  )
  preamble = preamble:gsub(
    "\\DeclarePairedDelimiterX%s*{%s*(\\[%a@]+)%s*}%s*%[(%d+)%]%s*{([^{}\n]*)}%s*{([^{}\n]*)}%s*{([^{}\n]*)}",
    function(cmd, argc, left, right, body)
      local open = left == "." and "" or "\\left" .. left
      local close = right == "." and "" or "\\right" .. right
      return "\\newcommand{" .. cmd .. "}[" .. argc .. "]{" .. open .. " " .. body .. " " .. close .. "}"
    end
  )
  preamble = preamble:gsub(
    "\\newdelimX%s*(\\[%a@]+)%s*%[(%d+)%]%s*{([^{}\n]*)}%s*{([^{}\n]*)}%s*{([^{}\n]*)}",
    function(cmd, argc, left, right, body)
      local open = left == "." and "" or "\\left" .. left
      local close = right == "." and "" or "\\right" .. right
      return "\\newcommand{" .. cmd .. "}[" .. argc .. "]{" .. open .. " " .. body .. " " .. close .. "}"
    end
  )
  preamble = preamble:gsub("\\DeclareRobustCommand", "\\newcommand")
  preamble = preamble:gsub("\\ProvideDocumentCommand", "\\NewDocumentCommand")
  return preamble
end

---Cached per-buffer extraction. The cache key includes the buffer's
---changedtick so the preamble invalidates as soon as the user edits a
---\newcommand. .sty files aren't tracked for changes — the cache lives
---only as long as the buffer hasn't changed, so re-scanning is cheap
---when it does happen.
local cache = setmetatable({}, { __mode = "k" }) -- weak by buf

---@param buf integer
---@return string preamble  Concatenated definitions, MathJax-normalized.
function M.get_preamble(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local entry = cache[buf]
  if entry and entry.tick == tick then return entry.value end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local buf_defs = M.extract_definitions(lines)
  local sty_defs = ""
  if config.options.extract.scan_sty then
    sty_defs = M.scan_sty_files(buf)
  end

  local combined
  if buf_defs == "" and sty_defs == "" then combined = ""
  elseif sty_defs == "" then combined = buf_defs
  elseif buf_defs == "" then combined = sty_defs
  else combined = sty_defs .. "\n" .. buf_defs end

  -- MathJax compatibility rewrites.
  if config.options.extract.rewrite_providecommand then
    combined = combined:gsub("\\providecommand", "\\newcommand")
  end
  if config.options.extract.rewrite_edef then
    combined = combined:gsub("\\edef", "\\def")
  end
  combined = normalize_for_mathjax(combined)

  cache[buf] = { tick = tick, value = combined }
  return combined
end

return M
