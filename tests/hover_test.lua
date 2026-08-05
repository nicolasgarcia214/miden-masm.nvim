-- Tests for masm.hover's content (the floating window itself is not
-- exercised headlessly). Run with:
--   nvim --headless --clean -l tests/hover_test.lua
-- or `make test`.

local helpers = dofile(
  vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")) .. "/helpers.lua"
)
local here = helpers.here
local check = helpers.check

local hover = require("masm.hover")
local root = here .. "/fixtures/"
local place = helpers.placer(root)

local function has_line(res, frag)
  for _, l in ipairs(res and res.lines or {}) do
    if l:find(frag, 1, true) then
      return true
    end
  end
  return false
end

-- Cross-file definition: doc comment, signature, and the source path.
place("app/main.masm", "exec.math::add_checked", 12)
local res = hover.content()
check("proc hover: doc comment shown", has_line(res, "#! Adds two values"))
check("proc hover: signature shown", has_line(res, "pub proc add_checked"))
check("proc hover: source path shown", has_line(res, "core_lib/math.masm"))
check("proc hover: highlighted as masm", res and res.masm == true)
check("proc hover: body not shown", not has_line(res, "assert.err"))

-- Multi-line doc block and @attributes belong to the definition block.
place("app/main.masm", "exec.m::mul_checked", 9)
res = hover.content()
check("proc hover: multi-line docs shown", has_line(res, "Inputs:  [b, a, ...]"))
check("proc hover: attribute shown", has_line(res, "@locals(2)"))

-- Same-buffer definition: no path line.
place("app/main.masm", "exec.local_helper", 6)
res = hover.content()
check("local hover: signature shown", has_line(res, "proc local_helper"))
check("local hover: no path line", not has_line(res, "main.masm"))

-- Constants resolve like gd does.
place("app/main.masm", "push.MAX_VALUE", 5)
res = hover.content()
check("const hover: definition shown", has_line(res, "pub const MAX_VALUE"))

-- Module qualifier: path plus the module file's leading doc block.
place("app/main.masm", "exec.math::add_checked", 6)
res = hover.content()
check("module hover: path shown", has_line(res, "core_lib/math.masm"))
check("module hover: module docs shown", has_line(res, "#! Fixture math module."))

-- Bare instruction: description and stack effect from the reference.
place("core_lib/math.masm", "    add", 4)
res = hover.content()
check("instruction hover: entry found", res ~= nil and res.lines[1] == "add", vim.inspect(res))
check("instruction hover: stack effect shown", has_line(res, "stack: "))
check("instruction hover: plain text", res and res.masm == false)

-- Immediate variant: cursor on the mnemonic of `push.MAX_VALUE` shows the
-- push.{n} template, not a failed const resolution.
place("app/main.masm", "push.MAX_VALUE", 0)
res = hover.content()
check("instruction hover: template variant found", has_line(res, "push.{n}"))

-- Dotted sub-op resolves exactly wherever the cursor sits in the word.
-- Appended to the buffer only (no place(): that reloads from disk).
vim.cmd("edit! " .. root .. "app/main.masm")
vim.api.nvim_buf_set_lines(0, -1, -1, false, { "    adv.insert_mem" })
vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 12 })
res = hover.content()
check("instruction hover: dotted sub-op found", res ~= nil and res.lines[1] == "adv.insert_mem")
vim.cmd("edit!") -- drop the scratch line

-- Bare invocation instructions with no dotted target (regression: dyncall
-- and dynexec were neither resolvable names nor reference entries, so K
-- reported "no documentation found").
for _, mnem in ipairs({ "dyncall", "dynexec" }) do
  vim.cmd("edit! " .. root .. "app/main.masm")
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "    " .. mnem })
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 6 })
  res = hover.content()
  check(
    "instruction hover: " .. mnem .. " found",
    res ~= nil and res.lines[1] == mnem,
    vim.inspect(res)
  )
  check("instruction hover: " .. mnem .. " stack effect shown", has_line(res, "stack: "))
  vim.cmd("edit!")
end

-- Cursor exactly on the DOT of an unresolvable dotted operand: NOT on the
-- mnemonic (regression: an off-by-one counted the dot as the mnemonic's last
-- column and showed push.{n} family docs for the dot of `push.NO_SUCH`).
vim.cmd("edit! " .. root .. "app/main.masm")
vim.api.nvim_buf_set_lines(0, -1, -1, false, { "    push.NO_SUCH_CONST" })
local last = vim.api.nvim_buf_line_count(0)
vim.api.nvim_win_set_cursor(0, { last, 8 }) -- 0-based col 8 = the dot
local dot_res, dot_reason = hover.content()
check(
  "dot boundary: dot is not the mnemonic",
  dot_res == nil and type(dot_reason) == "string",
  dot_res and vim.inspect(dot_res.lines) or dot_reason
)
vim.api.nvim_win_set_cursor(0, { last, 7 }) -- col 7 = `push`'s last char
dot_res = hover.content()
check("dot boundary: mnemonic's last char still is", has_line(dot_res, "push.{n}"))
vim.cmd("edit!")

-- Definitions open MODIFIED in another buffer hover their live text, not the
-- stale disk state (regression: only the current buffer's text was used).
local math_buf = vim.fn.bufadd(root .. "core_lib/math.masm")
vim.fn.bufload(math_buf)
local math_lines = vim.api.nvim_buf_get_lines(math_buf, 0, -1, false)
for i, l in ipairs(math_lines) do
  if l:find("#! Adds two values", 1, true) then
    vim.api.nvim_buf_set_lines(math_buf, i - 1, i, false, { "#! LIVE-EDITED doc line" })
    break
  end
end
place("app/main.masm", "exec.math::add_checked", 12)
res = hover.content()
check("cross-buffer hover: live text wins over disk", has_line(res, "LIVE-EDITED doc line"))
check("cross-buffer hover: stale disk doc absent", not has_line(res, "#! Adds two values"))
vim.api.nvim_buf_call(math_buf, function()
  vim.cmd("edit!") -- discard the live edit for later checks
end)

-- The floating-window layer: open, focus on the second call, close on q.
place("app/main.masm", "exec.math::add_checked", 12)
local wins_before = #vim.api.nvim_list_wins()
hover.hover()
check("float: window opened", #vim.api.nvim_list_wins() == wins_before + 1)
local cur_before = vim.api.nvim_get_current_win()
hover.hover()
local float_win = vim.api.nvim_get_current_win()
check("float: second call focuses it", float_win ~= cur_before)
check(
  "float: q closes it",
  (function()
    vim.api.nvim_feedkeys("q", "x", false)
    return #vim.api.nvim_list_wins() == wins_before
  end)()
)
-- Reopen; cursor movement in the source buffer closes it.
place("app/main.masm", "exec.math::add_checked", 12)
hover.hover()
check("float: reopened", #vim.api.nvim_list_wins() == wins_before + 1)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
check("float: cursor movement closes it", #vim.api.nvim_list_wins() == wins_before)

-- The `...` in a doc-comment stack diagram: no content, but never an error
-- (regression: dots-only tokens crashed the instruction fallback).
place("core_lib/math.masm", "[b, a, ...]", 7)
local dots_ok, dots_res, dots_reason = pcall(hover.content)
check(
  "doc ellipsis: no content, no error",
  dots_ok and dots_res == nil and type(dots_reason) == "string",
  tostring(dots_res or dots_reason)
)

-- Unresolvable name that is no instruction: nil plus a reason.
place("app/aliased.masm", "use fix::nowhere::gone", 19)
local nores, reason = hover.content()
check("unresolvable: no content, reason given", nores == nil and type(reason) == "string", reason)

helpers.finish()
