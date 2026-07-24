-- Tests for masm.hover's content (the floating window itself is not
-- exercised headlessly). Run with:
--   nvim --headless --clean -l tests/hover_test.lua
-- or `make test`.

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fs.dirname(vim.fn.fnamemodify(script, ":p"))
local plugin_root = vim.fs.dirname(here)
vim.opt.rtp:prepend(plugin_root)

local hover = require("masm.hover")
local root = here .. "/fixtures/"

local failed = 0

local function check(desc, ok, detail)
  if ok then
    print("PASS: " .. desc)
  else
    print("FAIL: " .. desc .. (detail and (" -- " .. detail) or ""))
    failed = failed + 1
  end
end

local function place(file, find, off)
  vim.cmd("edit! " .. root .. file)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, l in ipairs(lines) do
    local s = l:find(find, 1, true)
    if s then
      vim.api.nvim_win_set_cursor(0, { i, s - 1 + (off or 0) })
      return true
    end
  end
  error("locator not found: " .. find .. " in " .. file)
end

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

print(failed == 0 and "ALL PASS" or (failed .. " FAILURES"))
if failed > 0 then
  os.exit(1)
end
