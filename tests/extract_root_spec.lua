local uv = vim.uv or vim.loop

local function fail(msg)
  error(msg, 2)
end

local function assert_contains(haystack, needle, msg)
  if not haystack:find(needle, 1, true) then
    fail((msg or "missing expected text") .. "\nexpected to find: " .. needle .. "\nin:\n" .. haystack)
  end
end

local function write_file(path, body)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(body)
  fd:close()
end

local root = vim.env.LATEX_PREVIEW_TEST_ROOT or vim.fn.tempname()
vim.fn.delete(root, "rf")
vim.fn.mkdir(root, "p")

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local config = require("latex-preview.config")
config.setup({
  extract = {
    scan_sty = true,
    sty_search_depth = 4,
    rewrite_providecommand = true,
    rewrite_edef = true,
  },
})

local extract = require("latex-preview.extract")

local paper = root .. "/paper.tex"
local chapter = root .. "/chapters/intro.tex"
write_file(root .. "/macros.sty", [[
\newcommand{\stylemacro}{S}
]])
write_file(paper, [[
\documentclass{article}
\usepackage{macros}
\newcommand{\rootmacro}{R}
\begin{document}
\input{chapters/intro}
\end{document}
]])
write_file(chapter, [[
% !TEX root = ../paper.tex
\newcommand{\chaptermacro}{C}
\section{Intro}
$\rootmacro + \stylemacro + \chaptermacro$
]])

vim.cmd("edit " .. vim.fn.fnameescape(chapter))
local preamble = extract.get_preamble(vim.api.nvim_get_current_buf())
assert_contains(preamble, [[\newcommand{\rootmacro}{R}]], "chapter should use non-main root preamble")
assert_contains(preamble, [[\newcommand{\stylemacro}{S}]], "chapter should scan root-local package files")
assert_contains(preamble, [[\newcommand{\chaptermacro}{C}]], "chapter-local definitions should still be included")

local thesis = root .. "/thesis.tex"
local body = root .. "/sections/body.tex"
write_file(thesis, [[
\documentclass{book}
\newcommand{\thesismacro}{T}
\begin{document}
\include{sections/body}
\end{document}
]])
write_file(body, [[
\chapter{Body}
$\thesismacro$
]])

vim.cmd("edit " .. vim.fn.fnameescape(body))
preamble = extract.get_preamble(vim.api.nvim_get_current_buf())
assert_contains(preamble, [[\newcommand{\thesismacro}{T}]], "parent search should find a non-main root file")

local book = root .. "/book.tex"
local part = root .. "/parts/part1.tex"
local nested = root .. "/parts/chapters/nested.tex"
write_file(book, [[
\documentclass{book}
\newcommand{\bookmacro}{B}
\begin{document}
\input{parts/part1}
\end{document}
]])
write_file(part, [[
\input{chapters/nested}
]])
write_file(nested, [[
\section{Nested}
$\bookmacro$
]])

vim.cmd("edit " .. vim.fn.fnameescape(nested))
preamble = extract.get_preamble(vim.api.nvim_get_current_buf())
assert_contains(preamble, [[\newcommand{\bookmacro}{B}]], "parent search should follow nested inputs without a magic root")

local subroot = root .. "/article.tex"
local subfile = root .. "/sections/subfile-section.tex"
write_file(subroot, [[
\documentclass{article}
\newcommand{\subfilemacro}{SF}
\begin{document}
\subfile{sections/subfile-section}
\end{document}
]])
write_file(subfile, [[
\section{Subfile}
$\subfilemacro$
]])

vim.cmd("edit " .. vim.fn.fnameescape(subfile))
preamble = extract.get_preamble(vim.api.nvim_get_current_buf())
assert_contains(preamble, [[\newcommand{\subfilemacro}{SF}]], "parent search should understand subfile includes")

vim.fn.delete(root, "rf")
vim.cmd("qa")
