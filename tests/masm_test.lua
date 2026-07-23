-- Test suite for miden-masm.nvim, run against the fixture project in
-- tests/fixtures/. Run with:
--   nvim --headless -u NONE -l tests/masm_test.lua
-- or `make test`.

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fs.dirname(vim.fn.fnamemodify(script, ":p"))
local plugin_root = vim.fs.dirname(here)
vim.opt.rtp:prepend(plugin_root)

local goto_mod = require("masm.goto")
local root = here .. "/fixtures/"

local failed = 0

-- ------------------------------------------------------------------------
-- Go-to-definition: place the cursor on `find` (+ `off` bytes) and check the
-- tagfunc result lands on `expect_file` / a line matching `expect_line`.
-- ------------------------------------------------------------------------

local cases = {
  {
    desc = "local proc: exec.local_helper -> proc in same file",
    file = "app/main.masm",
    find = "exec.local_helper",
    off = 6,
    expect_file = "app/main.masm",
    expect_line = "^proc local_helper",
  },
  {
    desc = "aliased module: exec.m::mul_checked",
    file = "app/main.masm",
    find = "exec.m::mul_checked",
    off = 9,
    expect_file = "core_lib/math.masm",
    expect_line = "proc mul_checked",
  },
  {
    desc = "cursor on qualifier segment -> module file",
    file = "app/main.masm",
    find = "exec.math::add_checked",
    off = 6,
    expect_file = "core_lib/math.masm",
  },
  {
    desc = "qualified proc: exec.math::add_checked",
    file = "app/main.masm",
    find = "exec.math::add_checked",
    off = 12,
    expect_file = "core_lib/math.masm",
    expect_line = "proc add_checked",
  },
  {
    desc = "selective const import: push.MAX_VALUE",
    file = "app/main.masm",
    find = "push.MAX_VALUE",
    off = 5,
    expect_file = "core_lib/math.masm",
    expect_line = "const MAX_VALUE",
  },
  {
    desc = "syscall -> kernel api",
    file = "app/main.masm",
    find = "syscall.exec_kernel_proc",
    off = 9,
    expect_file = "kernel/lib/api.masm",
    expect_line = "proc exec_kernel_proc",
  },
  {
    desc = "single-file component: exec.gadget::run",
    file = "app/main.masm",
    find = "exec.gadget::run",
    off = 14,
    expect_file = "gadget/gadget.masm",
    expect_line = "proc run",
  },
  {
    desc = "pub mod line -> submodule file",
    file = "core_lib/mod.masm",
    find = "pub mod math",
    off = 8,
    expect_file = "core_lib/math.masm",
  },
  {
    desc = "use line, cursor on last segment -> module file",
    file = "app/main.masm",
    find = "use fix::core::math",
    off = 16,
    expect_file = "core_lib/math.masm",
  },
  {
    desc = "use line, cursor on middle segment -> that module's root",
    file = "app/main.masm",
    find = "use fix::core::math",
    off = 10,
    expect_file = "core_lib/mod.masm",
  },
  {
    desc = "multi-line use braces: PAIR_SIZE inside the block",
    file = "app/main.masm",
    find = "PAIR_SIZE,",
    off = 0,
    expect_file = "core_lib/types.masm",
    expect_line = "const PAIR_SIZE",
  },
  {
    desc = "usage imported through a multi-line use block",
    file = "app/main.masm",
    find = "push.PAIR_SIZE",
    off = 5,
    expect_file = "core_lib/types.masm",
    expect_line = "const PAIR_SIZE",
  },
  {
    desc = "type through braces rename: Pair as PairAlias",
    file = "app/main.masm",
    find = "Pair as PairAlias",
    off = 0,
    expect_file = "core_lib/types.masm",
    expect_line = "type Pair",
  },
  {
    desc = "renamed selective import: push.ALIASED_MAX",
    file = "app/aliased.masm",
    find = "push.ALIASED_MAX",
    off = 5,
    expect_file = "core_lib/math.masm",
    expect_line = "const MAX_VALUE",
  },
  {
    desc = "renamed re-export chain: wrappers::LIMIT",
    file = "app/main.masm",
    find = "wrappers::LIMIT",
    off = 11,
    expect_file = "core_lib/math.masm",
    expect_line = "const MAX_VALUE",
  },
  {
    desc = "re-exported proc: exec.wrappers::double body resolves",
    file = "app/main.masm",
    find = "exec.wrappers::double",
    off = 16,
    expect_file = "std_lib/wrappers.masm",
    expect_line = "proc double",
  },
  {
    desc = "unresolvable module fails gracefully",
    file = "app/aliased.masm",
    find = "use fix::nowhere::gone",
    off = 19,
    expect_fail = true,
  },
}

for _, c in ipairs(cases) do
  vim.cmd("edit! " .. root .. c.file)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local lnum, col
  for i, l in ipairs(lines) do
    local s = l:find(c.find, 1, true)
    if s then
      lnum, col = i, s - 1 + (c.off or 0)
      break
    end
  end
  if not lnum then
    print("FAIL (locator): " .. c.desc)
    failed = failed + 1
  else
    vim.api.nvim_win_set_cursor(0, { lnum, col })
    local ok, res = pcall(goto_mod.tagfunc, "", "c", {})
    if not ok then
      print("FAIL (error): " .. c.desc .. ": " .. tostring(res))
      failed = failed + 1
    elseif c.expect_fail then
      if res == vim.NIL or #res == 0 then
        print("PASS: " .. c.desc)
      else
        print("FAIL (should not resolve): " .. c.desc .. " -> " .. res[1].filename)
        failed = failed + 1
      end
    elseif res == vim.NIL or #res == 0 then
      print("FAIL (no result): " .. c.desc)
      failed = failed + 1
    else
      local item = res[1]
      local fileok = not c.expect_file or item.filename:sub(-#c.expect_file) == c.expect_file
      local lineok = true
      if c.expect_line then
        local fh = assert(io.open(item.filename), "cannot open " .. item.filename)
        local target = {}
        for l in fh:lines() do
          table.insert(target, l)
        end
        fh:close()
        local tl = target[tonumber(item.cmd)] or ""
        lineok = tl:find(c.expect_line) ~= nil
      end
      if fileok and lineok then
        print("PASS: " .. c.desc)
      else
        print("FAIL: " .. c.desc .. " -> " .. item.filename .. ":" .. item.cmd)
        failed = failed + 1
      end
    end
  end
end

-- ------------------------------------------------------------------------
-- References and document symbols
-- ------------------------------------------------------------------------

local function check(desc, ok, detail)
  if ok then
    print("PASS: " .. desc)
  else
    print("FAIL: " .. desc .. (detail and (" -- " .. detail) or ""))
    failed = failed + 1
  end
end

-- references()/document_symbols() focus the quickfix/location window; close
-- it so the next case operates on the source buffer again.
local function close_lists()
  vim.cmd("cclose | lclose")
end

local function has_ref(items, file_suffix, text_frag)
  for _, it in ipairs(items) do
    if
      it.filename:sub(-#file_suffix) == file_suffix
      and (not text_frag or it.text:find(text_frag, 1, true))
    then
      return true
    end
  end
  return false
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
  return false
end

-- Const references, including through renames in both directions.
place("app/main.masm", "push.MAX_VALUE", 5)
local refs = goto_mod.references() or {}
close_lists()
check(
  "refs: definition listed first",
  refs[1] and refs[1].text:find("const MAX_VALUE", 1, true) ~= nil,
  refs[1] and (refs[1].filename .. ": " .. refs[1].text)
)
check("refs: plain usage found", has_ref(refs, "app/main.masm", "push.MAX_VALUE"))
check(
  "refs: renamed selective import found (ALIASED_MAX)",
  has_ref(refs, "app/aliased.masm", "ALIASED_MAX")
)
check(
  "refs: renamed re-export found (wrappers::LIMIT)",
  has_ref(refs, "app/main.masm", "wrappers::LIMIT")
)
check(
  "refs: re-export site itself found",
  has_ref(refs, "std_lib/wrappers.masm", "MAX_VALUE as LIMIT")
)
check("refs: def-file internal usage found", has_ref(refs, "core_lib/math.masm", "push.MAX_VALUE"))
check("refs: comment mentions excluded", not has_ref(refs, "core_lib/math.masm", "must not count"))
check(
  "refs: string-literal mentions excluded",
  not has_ref(refs, "core_lib/math.masm", "sum exceeded")
)

-- Proc references: bare calls through `pub use` imports count.
place("app/main.masm", "exec.math::add_checked", 12)
refs = goto_mod.references() or {}
close_lists()
check(
  "refs: proc def first",
  refs[1] and refs[1].text:find("proc add_checked", 1, true) ~= nil,
  refs[1] and refs[1].text
)
check("refs: qualified call site found", has_ref(refs, "app/main.masm", "exec.math::add_checked"))
check(
  "refs: bare call through pub use found",
  has_ref(refs, "std_lib/wrappers.masm", "exec.add_checked")
)

-- Module references: cursor on the qualifier lists use-lines project-wide.
-- Exactly six statements import fix::core::math: three in main.masm, one in
-- aliased.masm, two pub-use re-exports in wrappers.masm.
place("app/main.masm", "exec.math::add_checked", 6)
refs = goto_mod.references() or {}
close_lists()
check("refs: exactly the six use-sites found", #refs == 6, "got " .. #refs)
local all_use = #refs > 0
for _, r in ipairs(refs) do
  if not r.text:find("use", 1, true) then
    all_use = false
  end
end
check("refs: module refs are all use-statements", all_use)

-- The non-cursor tagfunc path (`:tag`, tag completion): pattern parsed as a
-- path against the current buffer's imports.
vim.cmd("edit! " .. root .. "app/main.masm")
local tag_res = goto_mod.tagfunc("math::add_checked", "", {})
check(
  "tagfunc: :tag path resolves qualified names",
  tag_res ~= vim.NIL
    and tag_res[1]
    and tag_res[1].filename:find("core_lib/math.masm", 1, true) ~= nil,
  vim.inspect(tag_res)
)

-- Malformed module paths (`use ::`) in indexed files: resolving the broken
-- import fails with a reason instead of an error, local definitions in the
-- same file still resolve, and references scans survive the hostile file
-- (every scan above already walked it).
place("app/hostile.masm", "broken", 0)
local hostile_ok, hostile_res = pcall(goto_mod.tagfunc, "", "c", {})
check(
  "hostile: broken import fails gracefully",
  hostile_ok and hostile_res ~= vim.NIL and #hostile_res == 0,
  tostring(hostile_res)
)
place("app/hostile.masm", "push.1", 0)
local unrel = goto_mod.tagfunc("unrelated", "", {})
check(
  "hostile: local defs still resolve",
  unrel ~= vim.NIL and unrel[1] ~= nil and unrel[1].filename:find("hostile", 1, true) ~= nil
)

-- Stale-cache regression: after an on-disk edit shifts a definition, the
-- next jump must land on the new line, without :MasmRebuildIndex. The tracked
-- fixture is mutated on disk, so EVERYTHING between the write and the restore
-- runs under pcall: an error mid-test must never leave the fixture padded.
local math_path = root .. "core_lib/math.masm"
local fh = assert(io.open(math_path, "r"))
local orig_math = fh:read("*a")
fh:close()
place("app/main.masm", "push.MAX_VALUE", 5)
local before = goto_mod.tagfunc("", "c", {})
local run_ok, after = pcall(function()
  local w = assert(io.open(math_path, "w"))
  w:write("# pad\n# pad\n# pad\n" .. orig_math)
  w:close()
  return goto_mod.tagfunc("", "c", {})
end)
local restore = assert(io.open(math_path, "w"))
restore:write(orig_math)
restore:close()
after = run_ok and after or {}
check(
  "stale cache: jump tracks on-disk edits",
  run_ok and before[1] and after[1] and tonumber(after[1].cmd) == tonumber(before[1].cmd) + 3,
  (before[1] and before[1].cmd or "?")
    .. " -> "
    .. (run_ok and after[1] and after[1].cmd or tostring(after))
)

-- Document symbols.
vim.cmd("edit! " .. root .. "core_lib/math.masm")
local syms = goto_mod.document_symbols() or {}
close_lists()
check("symbols: math.masm defs found", #syms == 5, "got " .. #syms)
vim.cmd("edit! " .. root .. "app/main.masm")
syms = goto_mod.document_symbols() or {}
close_lists()
local has_begin = false
for _, s in ipairs(syms) do
  if s.text:find("^begin") then
    has_begin = true
  end
end
check("symbols: entrypoint listed", has_begin)

print(failed == 0 and "ALL PASS" or (failed .. " FAILURES"))
if failed > 0 then
  os.exit(1)
end
