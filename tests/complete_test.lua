-- Tests for omnifunc completion (masm.complete) against the fixture
-- project. Run with:
--   nvim --headless --clean -l tests/complete_test.lua
-- or `make test`.

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fs.dirname(vim.fn.fnamemodify(script, ":p"))
local plugin_root = vim.fs.dirname(here)
vim.opt.rtp:prepend(plugin_root)

local complete = require("masm.complete")
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

-- Appends `line_text` to the fixture buffer, puts the cursor at its end (as
-- insert-mode completion would) and runs the omnifunc protocol: findstart,
-- then matches for the base it identified. The scratch line is discarded.
local function complete_at(line_text)
  vim.cmd("edit! " .. root .. "app/main.masm")
  vim.wo.virtualedit = "onemore" -- cursor past the last char, like insert mode
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { line_text })
  local lnum = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { lnum, #line_text })
  local start = complete.omnifunc(1, "")
  local base = line_text:sub(start + 1)
  local items = complete.omnifunc(0, base)
  vim.cmd("edit!")
  return items, base, start
end

local function words(items)
  local out = {}
  for _, it in ipairs(items) do
    out[it.word] = it
  end
  return out
end

-- exec. with no qualifier: local procs, module qualifiers; consts excluded.
local items = words(complete_at("    exec."))
check(
  "exec.: local proc offered",
  items["local_helper"] ~= nil and items["local_helper"].kind == "f"
)
check("exec.: module qualifiers offered", items["math::"] ~= nil and items["m::"] ~= nil)
check(
  "exec.: alias menu shows the module path",
  items["m::"] and items["m::"].menu == "fix::core::math"
)
check("exec.: imported const excluded", items["MAX_VALUE"] == nil)
check("exec.: imported type excluded", items["PairAlias"] == nil)

-- exec. with a qualifier: that module's procs, with contract menus.
items = words(complete_at("    exec.math::"))
check("exec.math::: procs offered", items["add_checked"] ~= nil and items["mul_checked"] ~= nil)
check(
  "exec.math::: contract shown in menu",
  items["mul_checked"] and items["mul_checked"].menu == "[b, a, ...] -> [(a * b) / 4, ...]",
  items["mul_checked"] and tostring(items["mul_checked"].menu)
)
check("exec.math::: consts excluded", items["MAX_VALUE"] == nil)

-- Re-exports complete under the re-exporting module, renamed included.
items = words(complete_at("    exec.wrappers::"))
check("exec.wrappers::: own proc offered", items["double"] ~= nil)
check("exec.wrappers::: re-export offered", items["add_checked"] ~= nil)
check("exec.wrappers::: renamed re-export offered", items["mul"] ~= nil)
check("exec.wrappers::: re-exported const excluded", items["LIMIT"] == nil)

-- Aliased qualifier expands before resolving.
items = words(complete_at("    exec.m::"))
check("exec.m::: alias expands to the module", items["add_checked"] ~= nil)

-- call. and procref. share the exec. candidate set (procs and qualifiers,
-- no consts).
items = words(complete_at("    call."))
check("call.: local proc offered", items["local_helper"] ~= nil)
check("call.: const excluded", items["MAX_VALUE"] == nil)
items = words(complete_at("    procref.math::"))
check("procref.math::: procs offered", items["add_checked"] ~= nil)
check("procref.math::: consts excluded", items["MAX_VALUE"] == nil)

-- syscall.: kernel library procs only.
items = words(complete_at("    syscall."))
check("syscall.: kernel proc offered", items["exec_kernel_proc"] ~= nil)
check("syscall.: local proc excluded", items["local_helper"] == nil)

-- push.: constants (local, imported, qualified); procs and types excluded.
items = words(complete_at("    push."))
check(
  "push.: local const offered",
  items["LOCAL_LIMIT"] ~= nil and items["LOCAL_LIMIT"].kind == "v"
)
check("push.: imported consts offered", items["MAX_VALUE"] ~= nil and items["PAIR_SIZE"] ~= nil)
check("push.: proc excluded", items["local_helper"] == nil)
check("push.: type excluded", items["PairAlias"] == nil)
items = words(complete_at("    push.math::"))
check(
  "push.math::: module consts offered",
  items["MAX_VALUE"] ~= nil and items["ERR_OVERFLOW"] ~= nil
)
check("push.math::: procs excluded", items["add_checked"] == nil)

-- Bare instruction position: opcodes with stack effects, filtered by base.
local list
list, _ = complete_at("    ad")
items = words(list)
check("opcode: add offered with stack effect", items["add"] ~= nil and items["add"].menu ~= nil)
check("opcode: description in info", items["add"] ~= nil and items["add"].info ~= nil)
check("opcode: base filters", items["push."] == nil and items["drop"] == nil)
local sorted = true
for i = 2, #list do
  if list[i - 1].word > list[i].word then
    sorted = false
  end
end
check("opcode: matches sorted", sorted)

-- Immediate-only templates surface with a trailing dot; families whose bare
-- mnemonic is documented are not duplicated.
items = words(complete_at("    loc"))
check("opcode: immediate-only template as loc_load.", items["loc_load."] ~= nil)
items = words(complete_at("    lte"))
check(
  "opcode: no dotted duplicate of a bare mnemonic",
  items["lte"] ~= nil and items["lte."] == nil
)

-- Templates whose placeholder does not follow a dot keep their typeable
-- prefix (regression: `exp.u{n}` was silently dropped from the list).
items = words(complete_at("    exp"))
check("opcode: exp.u{n} offered as exp.u", items["exp.u"] ~= nil, vim.inspect(vim.tbl_keys(items)))
check("opcode: exp.{n} still offered as exp.", items["exp."] ~= nil)

-- Control-flow keywords the reference does not carry.
items = words(complete_at("    if"))
check("keyword: if.true / if.false offered", items["if.true"] ~= nil and items["if.false"] ~= nil)

-- Mid-identifier positions that are not completion contexts return nothing.
list = complete_at("    u32overflowing_add.")
check("no context: no candidates after a non-invoke dot", #list == 0, tostring(#list))

-- findstart identifies the base correctly.
local _, base, start = complete_at("    exec.local")
check("findstart: base is the trailing word", base == "local", base)
check("findstart: start at base start", start == #"    exec.", tostring(start))

print(failed == 0 and "ALL PASS" or (failed .. " FAILURES"))
if failed > 0 then
  os.exit(1)
end
