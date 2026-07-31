-- Test suite for miden-masm.nvim, run against the fixture project in
-- tests/fixtures/. Run with:
--   nvim --headless --clean -l tests/masm_test.lua
-- or `make test`.

local helpers = dofile(
  vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")) .. "/helpers.lua"
)
local here = helpers.here
local check = helpers.check

local goto_mod = require("masm.goto")
local uv = vim.uv or vim.loop

-- The whole suite runs against a TEMP COPY of tests/fixtures/, never the
-- tracked tree: several blocks below mutate fixtures on disk (stale-cache
-- padding, chain retargeting, created-then-removed files) and restore them
-- afterwards -- but a hard crash (kill -9, OOM) would defeat any in-process
-- restore and leave the checkout dirty. Copying once up front removes that
-- hazard for every block at once; the copy is deleted in teardown, and a
-- crash can at worst leak a temp directory. Expectations only ever match on
-- fixture-relative suffixes, so the relocated root is invisible to them.
local function copy_tree(src, dst)
  vim.fn.mkdir(dst, "p")
  for name, kind in vim.fs.dir(src) do
    local s, d = src .. "/" .. name, dst .. "/" .. name
    if kind == "directory" then
      copy_tree(s, d)
    else
      assert(uv.fs_copyfile(s, d), "fixture copy failed: " .. s)
    end
  end
end

local tmp_root = vim.fn.tempname()
copy_tree(here .. "/fixtures", tmp_root .. "/fixtures")
local root = tmp_root .. "/fixtures/"

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
    -- Cursor on the `exec` keyword itself targets the whole invocation,
    -- exactly like the unqualified `exec.local_helper` case -- not the
    -- first qualifier segment.
    desc = "cursor on exec keyword of a qualified call -> the target proc",
    file = "app/main.masm",
    find = "exec.math::add_checked",
    off = 0,
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
  {
    -- Lua's %w excludes `_`; a `%f[%W]` frontier once let `add` match the
    -- definition of `add_checked`.
    desc = "bare instruction is not a prefix-match of a proc name",
    file = "core_lib/math.masm",
    find = "    add",
    off = 4,
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
    helpers.failed = helpers.failed + 1
  else
    vim.api.nvim_win_set_cursor(0, { lnum, col })
    local ok, res = pcall(goto_mod.tagfunc, "", "c", {})
    if not ok then
      print("FAIL (error): " .. c.desc .. ": " .. tostring(res))
      helpers.failed = helpers.failed + 1
    elseif c.expect_fail then
      if res == vim.NIL or #res == 0 then
        print("PASS: " .. c.desc)
      else
        print("FAIL (should not resolve): " .. c.desc .. " -> " .. res[1].filename)
        helpers.failed = helpers.failed + 1
      end
    elseif res == vim.NIL or #res == 0 then
      print("FAIL (no result): " .. c.desc)
      helpers.failed = helpers.failed + 1
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
        helpers.failed = helpers.failed + 1
      end
    end
  end
end

-- ------------------------------------------------------------------------
-- References and document symbols
-- ------------------------------------------------------------------------

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

local place = helpers.placer(root)

-- Const references, including through renames in both directions.
place("app/main.masm", "push.MAX_VALUE", 5)
local refs = goto_mod.references({ sync = true }) or {}
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
refs = goto_mod.references({ sync = true }) or {}
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
-- Exactly seven statements import fix::core::math: three in main.masm, one
-- in aliased.masm, two pub-use re-exports in wrappers.masm, one in
-- stack.masm (the stack-analyzer fixture).
place("app/main.masm", "exec.math::add_checked", 6)
refs = goto_mod.references({ sync = true }) or {}
close_lists()
check("refs: exactly the seven use-sites found", #refs == 7, "got " .. #refs)
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

-- A single `:` is not a MASM path separator; resolving `math:add_checked`
-- as if it were `::` would navigate code the assembler rejects.
local colon_res = goto_mod.tagfunc("math:add_checked", "", {})
check(
  "tagfunc: single-colon paths are rejected",
  colon_res ~= vim.NIL and #colon_res == 0,
  vim.inspect(colon_res)
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
-- next jump must land on the new line, without :MasmRebuildIndex. The fixture
-- copy is mutated on disk, so EVERYTHING between the write and the restore
-- runs under pcall: an error mid-test must never leave the copy padded for
-- the blocks below (the tracked tree is out of reach either way).
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

-- ------------------------------------------------------------------------
-- Buffer-vs-disk freshness matrix: {clean, modified} x {disk unchanged,
-- disk changed} on the resolve path. Pins file_interface's contract
-- directly -- a MODIFIED loaded buffer wins over disk (changedtick key), a
-- clean or absent buffer tracks disk (stat key) -- so the fast-path
-- revalidation (remembered bufnr, bufexists for "none") cannot drift from
-- the full-walk semantics without a test going red. Each cell lands the
-- jump at a distinct line offset, so a wrong source is visible as a wrong
-- line, never as a vacuous pass. Disk is mutated, so the whole block runs
-- under pcall with an unconditional restore after it.
-- ------------------------------------------------------------------------

-- Prepends `n` `# pad` lines to the math buffer's CURRENT content.
local function pad_buffer(bufnr, n)
  local pads = {}
  for _ = 1, n do
    pads[#pads + 1] = "# pad"
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, pads)
end

local function write_math(text)
  local w = assert(io.open(math_path, "w"))
  w:write(text)
  w:close()
end

-- The jump target's line number, as a number (nil when unresolved).
local function jump_lnum()
  place("app/main.masm", "push.MAX_VALUE", 5)
  local res = goto_mod.tagfunc("", "c", {})
  return res ~= vim.NIL and res[1] and tonumber(res[1].cmd) or nil
end

vim.cmd("edit! " .. root .. "core_lib/math.masm") -- loaded and clean
local math_buf = vim.fn.bufnr()
local base_lnum = jump_lnum()
local matrix_ok, matrix_err = pcall(function()
  -- Clean buffer + disk unchanged: the cache hit serves the same line.
  check("buffer/disk matrix: clean + disk unchanged (cache hit)", jump_lnum() == base_lnum)

  -- Clean buffer + disk changed: the clean buffer's content is stale by
  -- definition of "clean" (it matches what was READ, not what IS); disk is
  -- the truth and the stat key must notice the write.
  write_math("# pad\n# pad\n" .. orig_math)
  check(
    "buffer/disk matrix: clean + disk changed tracks disk",
    jump_lnum() == base_lnum + 2,
    "got " .. tostring(jump_lnum())
  )

  -- Modified buffer + disk unchanged: unsaved edits win over the file.
  write_math(orig_math)
  pad_buffer(math_buf, 5)
  check(
    "buffer/disk matrix: modified + disk unchanged, buffer wins",
    jump_lnum() == base_lnum + 5,
    "got " .. tostring(jump_lnum())
  )

  -- Modified buffer + disk changed: the buffer STILL wins -- a concurrent
  -- on-disk change must not clobber unsaved edits mid-review.
  write_math("# pad\n# pad\n" .. orig_math)
  check(
    "buffer/disk matrix: modified + disk changed, buffer still wins",
    jump_lnum() == base_lnum + 5,
    "got " .. tostring(jump_lnum())
  )

  -- A further buffer edit moves the changedtick: the b:<bufnr>:<tick> key
  -- must re-parse (a stale hit would keep serving the +5 line).
  pad_buffer(math_buf, 2)
  check(
    "buffer/disk matrix: second buffer edit re-parses via changedtick",
    jump_lnum() == base_lnum + 7,
    "got " .. tostring(jump_lnum())
  )

  -- Reverted (:edit!): the buffer is clean again and reloaded from disk,
  -- so resolution falls back to the disk state (still padded by 2 here).
  vim.api.nvim_buf_call(math_buf, function()
    vim.cmd("edit!")
  end)
  check(
    "buffer/disk matrix: reverted buffer falls back to disk",
    jump_lnum() == base_lnum + 2,
    "got " .. tostring(jump_lnum())
  )
  write_math(orig_math)
  check("buffer/disk matrix: disk restore lands on the original line", jump_lnum() == base_lnum)

  -- No buffer at all, then a buffer APPEARS and is modified: the cached
  -- "no buffer" answer (revalidated via bufexists) must notice the new
  -- buffer's unsaved edits, not keep serving disk.
  vim.cmd("bwipeout! " .. math_buf)
  check("buffer/disk matrix: no buffer reads disk", jump_lnum() == base_lnum)
  local reopened = vim.fn.bufadd(math_path)
  vim.fn.bufload(reopened)
  pad_buffer(reopened, 3)
  check(
    "buffer/disk matrix: buffer appearing modified wins over disk",
    jump_lnum() == base_lnum + 3,
    "got " .. tostring(jump_lnum())
  )
end)
-- Unconditional restore: disk back to the original, any modified math
-- buffer reverted, so later blocks (and the tracked expectations) see the
-- pristine fixture whatever happened above.
write_math(orig_math)
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == math_path then
    vim.api.nvim_buf_call(b, function()
      vim.cmd("edit!")
    end)
  end
end
check("buffer/disk matrix: block completed", matrix_ok, tostring(matrix_err))

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
vim.cmd("edit! " .. root .. "app/hostile.masm")
syms = goto_mod.document_symbols() or {}
close_lists()
local impostor = false
for _, s in ipairs(syms) do
  if s.text:find("begin_impostor", 1, true) then
    impostor = true
  end
end
check("symbols: begin_impostor is not an entrypoint", not impostor)

-- ------------------------------------------------------------------------
-- Async references: same results as sync, delivered via the event loop
-- ------------------------------------------------------------------------

place("app/main.masm", "push.MAX_VALUE", 5)
local sync_refs = goto_mod.references({ sync = true }) or {}
close_lists()
vim.fn.setqflist({}, " ", { title = "sentinel", items = {} })
place("app/main.masm", "push.MAX_VALUE", 5)
local async_ret = goto_mod.references()
check("async refs: no immediate return", async_ret == nil)
local done = vim.wait(5000, function()
  return vim.fn.getqflist({ title = 1 }).title ~= "sentinel"
end, 10)
close_lists()
local async_list = vim.fn.getqflist()
check("async refs: quickfix populated from the event loop", done and #async_list > 0)
check(
  "async refs: same result count as sync",
  #async_list == #sync_refs,
  ("async %d vs sync %d"):format(#async_list, #sync_refs)
)

-- ------------------------------------------------------------------------
-- Rename: definition, spelled references and import-item originals change;
-- alias spellings survive
-- ------------------------------------------------------------------------

local function buffer_text_of(rel)
  local bufnr = vim.fn.bufadd(root .. rel)
  vim.fn.bufload(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

place("app/main.masm", "push.MAX_VALUE", 5)
local res, why = goto_mod.rename("RENAMED_MAX")
check("rename: succeeds", res ~= nil, tostring(why))
check(
  "rename: 6 occurrences in 4 files",
  res ~= nil and res.applied == 6 and res.files == 4 and res.skipped == 0,
  res ~= nil and vim.inspect(res) or "no result"
)
local math_text = buffer_text_of("core_lib/math.masm")
check("rename: definition renamed", math_text:find("pub const RENAMED_MAX", 1, true) ~= nil)
check("rename: def-file usage renamed", math_text:find("push.RENAMED_MAX", 1, true) ~= nil)
check(
  "rename: comment mentions untouched",
  math_text:find("Mentions of MAX_VALUE in comments", 1, true) ~= nil
)
check(
  "rename: string-literal mentions untouched",
  math_text:find("sum exceeded MAX_VALUE", 1, true) ~= nil
)
local main_text = buffer_text_of("app/main.masm")
check("rename: selective import renamed", main_text:find("{RENAMED_MAX}", 1, true) ~= nil)
check("rename: plain usage renamed", main_text:find("push.RENAMED_MAX", 1, true) ~= nil)
local aliased_text = buffer_text_of("app/aliased.masm")
check(
  "rename: import original renamed, alias kept",
  aliased_text:find("{RENAMED_MAX as ALIASED_MAX}", 1, true) ~= nil
)
check("rename: alias usage untouched", aliased_text:find("push.ALIASED_MAX", 1, true) ~= nil)
local wrappers_text = buffer_text_of("std_lib/wrappers.masm")
check(
  "rename: re-export original renamed, rename kept",
  wrappers_text:find("{RENAMED_MAX as LIMIT}", 1, true) ~= nil
)
check(
  "rename: aliased re-export usage untouched",
  main_text:find("wrappers::LIMIT", 1, true) ~= nil
)

-- Buffers were left modified, not written: fixtures on disk are untouched.
local disk_math = io.open(root .. "core_lib/math.masm", "r"):read("*a")
check("rename: nothing written to disk", disk_math:find("MAX_VALUE", 1, true) ~= nil)

-- Renamed-state navigation still works (buffers are the source of truth),
-- then discard every unsaved buffer so later suites see the fixtures.
-- The cursor is placed WITHOUT place(): its `edit!` reloads from disk,
-- which would discard the unsaved rename this assertion is about (and
-- did -- the pre-helpers place() returned false silently here, leaving
-- the cursor on the pre-rename spot and the check passing vacuously).
do
  local target = root .. "app/main.masm"
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == target then
      vim.api.nvim_set_current_buf(b)
      break
    end
  end
  local placed = false
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local s = l:find("push.RENAMED_MAX", 1, true)
    if s then
      vim.api.nvim_win_set_cursor(0, { i, s - 1 + 5 })
      placed = true
      break
    end
  end
  check("rename: renamed usage present in the live buffer", placed)
end
local renamed_jump = goto_mod.tagfunc("", "c", {})
check(
  "rename: navigation follows the new name",
  renamed_jump ~= vim.NIL
    and renamed_jump[1] ~= nil
    and renamed_jump[1].filename:find("core_lib/math.masm", 1, true) ~= nil
)
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
    vim.api.nvim_buf_call(b, function()
      vim.cmd("edit!")
    end)
  end
end
check(
  "rename: fixtures restored for later suites",
  buffer_text_of("core_lib/math.masm"):find("pub const MAX_VALUE", 1, true) ~= nil
)

-- Guard rails: modules and invalid names are refused.
place("app/main.masm", "exec.math::add_checked", 6)
local mod_res, mod_why = goto_mod.rename("whatever")
check("rename: refuses modules", mod_res == nil and mod_why == "not a symbol", tostring(mod_why))
place("app/main.masm", "push.MAX_VALUE", 5)
local bad_res, bad_why = goto_mod.rename("123bad")
check(
  "rename: refuses invalid names",
  bad_res == nil and bad_why == "invalid name",
  tostring(bad_why)
)

-- ------------------------------------------------------------------------
-- Opcode-named procs: bare instruction tokens are not references
-- ------------------------------------------------------------------------

local function restore_modified_buffers()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      vim.api.nvim_buf_call(b, function()
        vim.cmd("edit!")
      end)
    end
  end
end

place("app/opcodes.masm", "proc add", 5)
refs = goto_mod.references({ sync = true }) or {}
close_lists()
check("opcode-named: exactly def + exec site, no bare opcodes", #refs == 2, "got " .. #refs)
check("opcode-named: definition found", has_ref(refs, "app/opcodes.masm", "proc add"))
check("opcode-named: exec.add found", has_ref(refs, "app/opcodes.masm", "exec.add"))

place("app/opcodes.masm", "proc add", 5)
res, why = goto_mod.rename("checked_sum")
check(
  "opcode-named rename: exactly 2 edits",
  res ~= nil and res.applied == 2 and res.skipped == 0,
  res ~= nil and vim.inspect(res) or tostring(why)
)
local opcodes_text = buffer_text_of("app/opcodes.masm")
check(
  "opcode-named rename: instruction tokens untouched",
  opcodes_text:find("push.1 add", 1, true) ~= nil
    and opcodes_text:find("push.2 add drop", 1, true) ~= nil
)
check(
  "opcode-named rename: definition and call renamed",
  opcodes_text:find("proc checked_sum", 1, true) ~= nil
    and opcodes_text:find("exec.checked_sum", 1, true) ~= nil
)
restore_modified_buffers()

-- Renaming onto an existing sibling definition would silently merge the two
-- names; it must refuse instead.
place("app/main.masm", "push.MAX_VALUE", 5)
local col_res, col_why = goto_mod.rename("ERR_OVERFLOW")
check(
  "rename: refuses collision with an existing definition",
  col_res == nil and col_why == "name collision",
  tostring(col_why)
)

-- Async-prompt capture: with a vim.ui.input that moves the cursor before
-- submitting (what an async dressing/snacks prompt amounts to), the symbol
-- captured at prompt time is renamed -- not whatever the cursor lands on.
local saved_input = vim.ui.input
-- Replacing the typed built-in is the point of the stub; restored below.
---@diagnostic disable-next-line: duplicate-set-field
vim.ui.input = function(_, cb)
  place("app/main.masm", "push.MAX_VALUE", 5)
  cb("PROMPTED_LIMIT")
end
place("app/main.masm", "push.LOCAL_LIMIT", 5)
goto_mod.rename()
vim.ui.input = saved_input
main_text = buffer_text_of("app/main.masm")
check(
  "rename prompt: captured target renamed, cursor-at-callback ignored",
  main_text:find("const PROMPTED_LIMIT", 1, true) ~= nil
    and main_text:find("push.PROMPTED_LIMIT", 1, true) ~= nil
    and main_text:find("push.MAX_VALUE", 1, true) ~= nil
)
restore_modified_buffers()

-- ------------------------------------------------------------------------
-- Re-export chain invalidation: editing a MIDDLE hop re-resolves
-- ------------------------------------------------------------------------

-- wrappers::LIMIT resolves main.masm -> wrappers.masm (pub use) ->
-- math.masm MAX_VALUE. Retargeting the middle hop on disk must serve the
-- new destination on the very next jump, without :MasmRebuildIndex. The
-- fixture copy is mutated on disk, so everything between the write and
-- the restore runs under pcall (for the blocks below; the tracked tree is
-- out of reach either way).
local wr_path = root .. "std_lib/wrappers.masm"
local wfh = assert(io.open(wr_path, "r"))
local orig_wr = wfh:read("*a")
wfh:close()
place("app/main.masm", "wrappers::LIMIT", 11)
local chain_before = goto_mod.tagfunc("", "c", {})
local chain_ok, chain_after = pcall(function()
  local w = assert(io.open(wr_path, "w"))
  w:write((orig_wr:gsub("MAX_VALUE as LIMIT", "ERR_OVERFLOW as LIMIT")))
  w:close()
  return goto_mod.tagfunc("", "c", {})
end)
local wrestore = assert(io.open(wr_path, "w"))
wrestore:write(orig_wr)
wrestore:close()
chain_after = chain_ok and chain_after or {}
local retargeted_line = ""
if chain_after[1] then
  local mfh = assert(io.open(chain_after[1].filename, "r"))
  local mlines = {}
  for l in mfh:lines() do
    table.insert(mlines, l)
  end
  mfh:close()
  retargeted_line = mlines[tonumber(chain_after[1].cmd)] or ""
end
check(
  "chain retarget: middle-hop edit re-resolves without :MasmRebuildIndex",
  chain_ok and chain_before[1] ~= nil and retargeted_line:find("ERR_OVERFLOW", 1, true) ~= nil,
  "landed on: " .. retargeted_line
)

-- ------------------------------------------------------------------------
-- Index auto-refresh: files created after the first jump become visible
-- once the BufWritePost hook reports them
-- ------------------------------------------------------------------------

local new_path = root .. "app/created_later.masm"
place("app/main.masm", "push.MAX_VALUE", 5)
local before_refs = goto_mod.references({ sync = true }) or {}
close_lists()
local refresh_ok, refresh_err = pcall(function()
  local w = assert(io.open(new_path, "w"))
  w:write("use {MAX_VALUE} from fix::core::math\n\nproc late\n    push.MAX_VALUE drop\nend\n")
  w:close()
  place("app/main.masm", "push.MAX_VALUE", 5)
  local stale_refs = goto_mod.references({ sync = true }) or {}
  close_lists()
  check(
    "index refresh: new file invisible before the write hook",
    #stale_refs == #before_refs,
    ("stale %d vs before %d"):format(#stale_refs, #before_refs)
  )
  goto_mod._file_written(new_path)
  place("app/main.masm", "push.MAX_VALUE", 5)
  local fresh_refs = goto_mod.references({ sync = true }) or {}
  close_lists()
  check(
    "index refresh: new file's references appear after the hook",
    #fresh_refs == #before_refs + 2,
    ("fresh %d vs before %d"):format(#fresh_refs, #before_refs)
  )
end)
os.remove(new_path)
goto_mod.clear_cache() -- the removed file must not linger in later suites
check("index refresh: block completed", refresh_ok, tostring(refresh_err))

-- ------------------------------------------------------------------------
-- Configuration surface: extra_roots, ignore_dirs, string-as-list
-- ------------------------------------------------------------------------

-- extra_roots: a library OUTSIDE the project tree resolves once listed.
local ext_root = vim.fn.tempname()
vim.fn.mkdir(ext_root .. "/extlib", "p")
local config_ok, config_err = pcall(function()
  local w = assert(io.open(ext_root .. "/extlib/miden-project.toml", "w"))
  w:write('[lib]\nnamespace = "ext::lib"\npath = "extlib.masm"\n')
  w:close()
  w = assert(io.open(ext_root .. "/extlib/extlib.masm", "w"))
  w:write("#! External fixture library.\npub proc ext_proc\n    push.1 drop\nend\n")
  w:close()

  vim.cmd("edit! " .. root .. "app/main.masm")
  goto_mod.clear_cache()
  local miss = goto_mod.tagfunc("ext::lib::ext_proc", "", {})
  check("extra_roots: external lib unknown without config", miss ~= vim.NIL and #miss == 0)

  vim.g.masm_goto = { extra_roots = { ext_root } }
  goto_mod.clear_cache()
  local hit = goto_mod.tagfunc("ext::lib::ext_proc", "", {})
  check(
    "extra_roots: external lib resolves with config",
    hit ~= vim.NIL and hit[1] ~= nil and hit[1].filename:find("extlib.masm", 1, true) ~= nil,
    vim.inspect(hit)
  )

  -- A bare string is accepted as a one-element list, for both options.
  vim.g.masm_goto = { extra_roots = ext_root }
  goto_mod.clear_cache()
  hit = goto_mod.tagfunc("ext::lib::ext_proc", "", {})
  check(
    "extra_roots: string accepted as one-element list",
    hit ~= vim.NIL and hit[1] ~= nil,
    vim.inspect(hit)
  )

  -- ignore_dirs REPLACES the default list; an ignored directory's files
  -- disappear from scans (std_lib holds the re-export fixture).
  vim.g.masm_goto = { ignore_dirs = { "std_lib", "target", "node_modules" } }
  goto_mod.clear_cache()
  place("app/main.masm", "push.MAX_VALUE", 5)
  local ignored_refs = goto_mod.references({ sync = true }) or {}
  close_lists()
  check(
    "ignore_dirs: ignored directory's references vanish",
    not has_ref(ignored_refs, "std_lib/wrappers.masm", nil),
    tostring(#ignored_refs)
  )
end)
vim.g.masm_goto = nil
goto_mod.clear_cache()
vim.fn.delete(ext_root, "rf")
check("config surface: block completed", config_ok, tostring(config_err))

-- ------------------------------------------------------------------------
-- Configuration surface: invalid values degrade loudly to the defaults
-- ------------------------------------------------------------------------

local bad_cfg_ok, bad_cfg_err = pcall(function()
  local notified = {}
  local saved_notify = vim.notify
  -- Replacing the typed built-in is the point of the stub; restored below.
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg)
    notified[#notified + 1] = tostring(msg)
  end
  -- extra_roots is not string-or-list, ignore_dirs has a non-string entry:
  -- both must be refused with a named notification, and resolution must
  -- keep working on the defaults instead of silently degrading.
  vim.g.masm_goto = { extra_roots = 42, ignore_dirs = { "target", 7 } }
  goto_mod.clear_cache()
  vim.cmd("edit! " .. root .. "app/main.masm")
  local hit = goto_mod.tagfunc("math::add_checked", "", {})
  vim.notify = saved_notify
  check(
    "config validation: invalid fields fall back to working defaults",
    hit ~= vim.NIL and hit[1] ~= nil and hit[1].filename:find("math.masm", 1, true) ~= nil,
    vim.inspect(hit)
  )
  local mentions = { extra_roots = false, ignore_dirs = false }
  for _, msg in ipairs(notified) do
    for field in pairs(mentions) do
      if msg:find("masm_goto." .. field, 1, true) then
        mentions[field] = true
      end
    end
  end
  check(
    "config validation: each invalid field notifies by name",
    mentions.extra_roots and mentions.ignore_dirs,
    vim.inspect(notified)
  )
end)
vim.g.masm_goto = nil
goto_mod.clear_cache()
check("config validation: block completed", bad_cfg_ok, tostring(bad_cfg_err))

-- ------------------------------------------------------------------------
-- `$`-sigil identifiers: selective import, navigation and rename all use
-- the one util.IDENT charset (temp fixtures, removed afterwards)
-- ------------------------------------------------------------------------

local dollar_def = root .. "core_lib/dollar.masm"
local dollar_user = root .. "app/dollar_user.masm"
local dollar_ok, dollar_err = pcall(function()
  local w = assert(io.open(dollar_def, "w"))
  w:write("pub proc $special\n    push.1 drop\nend\n")
  w:close()
  w = assert(io.open(dollar_user, "w"))
  w:write("use {$special} from fix::core::dollar\n\nproc caller\n    exec.$special\nend\n")
  w:close()
  goto_mod.clear_cache()

  -- gd through the selective import.
  place("app/dollar_user.masm", "exec.$special", 6)
  local hit = goto_mod.tagfunc("", "c", {})
  check(
    "dollar: selective import resolves to the definition",
    hit ~= vim.NIL
      and hit[1] ~= nil
      and hit[1].filename:find("core_lib/dollar.masm", 1, true) ~= nil,
    vim.inspect(hit)
  )

  -- References reach both sides of the import.
  place("app/dollar_user.masm", "exec.$special", 6)
  local drefs = goto_mod.references({ sync = true }) or {}
  close_lists()
  check("dollar: definition file referenced", has_ref(drefs, "core_lib/dollar.masm", nil))
  check("dollar: importing file referenced", has_ref(drefs, "app/dollar_user.masm", nil))

  -- Rename round-trips the sigil: definition, `use { .. }` item and call
  -- site all rewrite, onto a name that keeps the `$`.
  place("app/dollar_user.masm", "exec.$special", 6)
  local dres, dwhy = goto_mod.rename("$renamed")
  check("dollar: rename succeeds", dres ~= nil, tostring(dwhy))
  local dtext = buffer_text_of("core_lib/dollar.masm")
  check("dollar: definition renamed", dtext:find("pub proc $renamed", 1, true) ~= nil)
  local utext = buffer_text_of("app/dollar_user.masm")
  check("dollar: import item renamed", utext:find("{$renamed}", 1, true) ~= nil)
  check("dollar: call site renamed", utext:find("exec.$renamed", 1, true) ~= nil)
end)
-- Discard the unsaved rename edits, then the temp fixtures themselves.
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
    vim.api.nvim_buf_call(b, function()
      vim.cmd("edit!")
    end)
  end
end
os.remove(dollar_def)
os.remove(dollar_user)
goto_mod.clear_cache()
check("dollar: block completed", dollar_ok, tostring(dollar_err))

-- ------------------------------------------------------------------------
-- Resolver limits: re-export depth cap and cycle detection
-- ------------------------------------------------------------------------

-- Chains resolve through MAX_REEXPORT_DEPTH (5) hops and report "not found"
-- one hop deeper; cycles fail cleanly. Fixture chains are created on disk
-- and removed afterwards, so everything in between runs under pcall.
local chain_files = {}
local function write_chain(name, text)
  local path = root .. "app/" .. name
  chain_files[#chain_files + 1] = path
  local w = assert(io.open(path, "w"))
  w:write(text)
  w:close()
end
local limits_ok, limits_err = pcall(function()
  for i = 1, 5 do
    write_chain(("hop%d.masm"):format(i), ("pub use {deep_ok} from hop%d\n"):format(i + 1))
  end
  write_chain("hop6.masm", "pub proc deep_ok\n    push.1 drop\nend\n")
  for i = 1, 6 do
    write_chain(("far%d.masm"):format(i), ("pub use {deep_bad} from far%d\n"):format(i + 1))
  end
  write_chain("far7.masm", "pub proc deep_bad\n    push.1 drop\nend\n")
  write_chain("cyc1.masm", "pub use {spin} from cyc2\n")
  write_chain("cyc2.masm", "pub use {spin} from cyc1\n")
  goto_mod.clear_cache()
  vim.cmd("edit! " .. root .. "app/main.masm")

  local deep = goto_mod.tagfunc("hop1::deep_ok", "", {})
  check(
    "limits: 5-hop re-export chain resolves",
    deep ~= vim.NIL and deep[1] ~= nil and deep[1].filename:find("hop6.masm", 1, true) ~= nil,
    vim.inspect(deep)
  )
  local far = goto_mod.tagfunc("far1::deep_bad", "", {})
  check("limits: 6-hop chain reports not found", far ~= vim.NIL and #far == 0, vim.inspect(far))
  local cyc_ok, cyc = pcall(goto_mod.tagfunc, "cyc1::spin", "", {})
  check(
    "limits: re-export cycle fails cleanly",
    cyc_ok and cyc ~= vim.NIL and #cyc == 0,
    tostring(cyc)
  )
end)
for _, f in ipairs(chain_files) do
  os.remove(f)
end
goto_mod.clear_cache()
check("resolver limits: block completed", limits_ok, tostring(limits_err))

-- ------------------------------------------------------------------------
-- Dialect-drift canary: unrecognized use-statement forms are reported
-- ------------------------------------------------------------------------

local function read_fixture(rel)
  local f = assert(io.open(root .. rel, "r"))
  local text = f:read("*a")
  f:close()
  return text
end

-- Every fixture file exercises only recognized forms: the canary must be
-- silent on all of them, or it would cry wolf on healthy projects.
for _, rel in ipairs({
  "app/main.masm",
  "app/aliased.masm",
  "app/stack.masm",
  "core_lib/mod.masm",
  "std_lib/wrappers.masm",
}) do
  local drift = goto_mod.unrecognized_imports(read_fixture(rel))
  check("drift canary: silent on " .. rel, #drift == 0, vim.inspect(drift))
end

local drift = goto_mod.unrecognized_imports(table.concat({
  "use miden::core::math", -- plain: recognized
  "use miden::core::math as m", -- as-rename: recognized
  "use miden::core -> legacy", -- legacy arrow: recognized
  "pub use { a, b as c } from miden::core::math", -- selective: recognized
  "use {", -- multi-line selective, opening line: recognized
  "  first,",
  "  second,",
  "} from miden::core::math",
  "# use miden::like::this -- in a comment: ignored",
  "use miden::core::math::{nested, braces}", -- rust-style suffix braces: NOT a MASM form
  "use miden.core.math", -- dotted path: NOT a MASM form
  "begin",
  "  push.1 drop",
  "end",
}, "\n"))
check(
  "drift canary: rust-style braces flagged",
  #drift == 2 and drift[1].lnum == 10,
  vim.inspect(drift)
)
check("drift canary: dotted path flagged", #drift == 2 and drift[2].lnum == 11, vim.inspect(drift))

-- Teardown: drop the fixture copy, whatever happened above (a crash before
-- this line merely leaks a temp directory -- the tracked tree stays clean).
vim.fn.delete(tmp_root, "rf")

helpers.finish()
