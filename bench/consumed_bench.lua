-- bench/consumed_bench.lua
--
-- Compares bytemark vs interval for tracking consumed byte ranges in
-- regex_extract. Mirrors the actual code structure:
--
--   Phase 1: named patterns ($$, \[, \begin{equation} etc.)
--            Each match calls not_consumed(s,e) then mark(s,e).
--
--   Phase 2: inline $ scan — iterates every byte in the source.
--            Per-byte check:  bytemark uses `consumed[i]` directly (no fn call)
--                             interval uses not_consumed(i, i)  (binary search)
--            Range check:     not_consumed(i, close) called only for found pairs.
--
-- Run with:  luajit bench/consumed_bench.lua

-- ---------------------------------------------------------------------------
-- Implementations
-- ---------------------------------------------------------------------------

local function make_bytemark()
  local consumed = {}
  local function not_consumed(s, e)
    for i = s, e do if consumed[i] then return false end end
    return true
  end
  local function mark(s, e)
    for i = s, e do consumed[i] = true end
  end
  -- Direct table access for the per-byte inline scan (no function overhead).
  return consumed, not_consumed, mark
end

local function make_interval()
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
  return consumed, not_consumed, mark
end

-- ---------------------------------------------------------------------------
-- Scenario generator
-- ---------------------------------------------------------------------------

-- Build a fake source string and the positions of unescaped $ chars.
-- display_ivs: list of {s,e} for named-pattern matches ($$, \[, etc.).
-- dollar_pairs: list of {open, close} for inline $ pairs, placed in gaps.
local function gen_scenario(source_size, n_display, display_width,
                             dollar_spacing, inline_width)
  -- Display intervals, evenly spaced.
  local display_ivs = {}
  local gap = math.floor((source_size - n_display * display_width) / (n_display + 1))
  if gap < 1 then gap = 1 end
  local pos = gap
  for _ = 1, n_display do
    display_ivs[#display_ivs + 1] = { pos, pos + display_width - 1 }
    pos = pos + display_width + gap
  end

  -- Mark display ranges so inline $ pairs don't land inside them.
  local covered = {}
  for _, iv in ipairs(display_ivs) do
    for i = iv[1], iv[2] do covered[i] = true end
  end

  -- Inline $ pairs in uncovered gaps.
  local dollar_pairs = {}
  local p = dollar_spacing
  while p + inline_width < source_size do
    if not covered[p] and not covered[p + inline_width] then
      dollar_pairs[#dollar_pairs + 1] = { p, p + inline_width }
    end
    p = p + dollar_spacing
  end

  -- Build a source string: spaces everywhere, '$' at pair positions.
  local chars = {}
  for i = 1, source_size do chars[i] = " " end
  for _, d in ipairs(dollar_pairs) do
    chars[d[1]] = "$"
    chars[d[2]] = "$"
  end
  local source = table.concat(chars)

  return source, display_ivs, dollar_pairs
end

-- ---------------------------------------------------------------------------
-- Simulate regex_extract's consume logic for one implementation.
-- `consumed_tbl` is the raw table (for direct [i] access in bytemark);
-- for interval it's unused in the per-byte path (not_consumed is called).
-- ---------------------------------------------------------------------------

local function simulate_bytemark(source, display_ivs, dollar_pairs, not_consumed, mark, consumed_tbl)
  -- Phase 1: named patterns
  for _, iv in ipairs(display_ivs) do
    if not_consumed(iv[1], iv[2]) then mark(iv[1], iv[2]) end
  end
  -- Phase 2: inline $ scan — walk every byte, direct table check per byte.
  local n = #source
  local di = 1
  local nd = #dollar_pairs
  local i = 1
  while i <= n do
    -- Mirrors: if unescaped_at(i) and not consumed[i] then
    if source:sub(i, i) == "$" and not consumed_tbl[i] then
      local d = dollar_pairs[di]
      if d and d[1] == i then
        local closed = d[2]
        if not_consumed(i, closed) then mark(i, closed) end
        di = di + 1
        i = closed + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
end

local function simulate_interval(source, display_ivs, dollar_pairs, not_consumed, mark)
  -- Phase 1: named patterns
  for _, iv in ipairs(display_ivs) do
    if not_consumed(iv[1], iv[2]) then mark(iv[1], iv[2]) end
  end
  -- Phase 2: inline $ scan — binary search per byte check.
  local n = #source
  local di = 1
  local nd = #dollar_pairs
  local i = 1
  while i <= n do
    if source:sub(i, i) == "$" and not_consumed(i, i) then
      local d = dollar_pairs[di]
      if d and d[1] == i then
        local closed = d[2]
        if not_consumed(i, closed) then mark(i, closed) end
        di = di + 1
        i = closed + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
end

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------

local function bench(label, fn, iters)
  fn()
  local t0 = os.clock()
  for _ = 1, iters do fn() end
  local elapsed = os.clock() - t0
  print(string.format("  %-14s %5d iters  %7.2f ms total  %6.2f us/iter",
    label, iters, elapsed * 1000, elapsed * 1e6 / iters))
end

local function run_scenario(desc, source_size, n_display, display_width,
                             dollar_spacing, inline_width, iters)
  local source, display_ivs, dollar_pairs =
    gen_scenario(source_size, n_display, display_width, dollar_spacing, inline_width)
  print(string.format(
    "\n%s  (source=%d B, display=%d, inline=%d, $-spacing=%d)",
    desc, source_size, n_display, #dollar_pairs, dollar_spacing))

  bench("bytemark", function()
    local ct, nc, mk = make_bytemark()
    simulate_bytemark(source, display_ivs, dollar_pairs, nc, mk, ct)
  end, iters)

  bench("interval", function()
    local _, nc, mk = make_interval()
    simulate_interval(source, display_ivs, dollar_pairs, nc, mk)
  end, iters)
end

-- Scenarios: (source_size, display eqs, display_width, $-spacing, inline_width, iters)
local scenarios = {
  { "small    ",  10000,  3, 100, 200, 40,  2000 },
  { "typical  ",  40000, 10, 150, 150, 50,   500 },
  { "large    ", 150000, 25, 300, 120, 60,   200 },
  { "patholog.", 500000, 40, 600,  80, 80,    50 },
}

local n = #scenarios
for idx, s in ipairs(scenarios) do
  run_scenario(s[1], s[2], s[3], s[4], s[5], s[6], s[7])
  if idx < n then
    io.write("\n[enter] for next scenario, [q] to quit: ")
    io.flush()
    local input = io.read("*l")
    if input and input:lower() == "q" then break end
  end
end
