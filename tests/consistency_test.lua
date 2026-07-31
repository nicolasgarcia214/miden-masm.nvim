-- Consistency of the three instruction datasets: the hand-audited arity
-- table (arity.lua, ground truth for what the simulator understands), the
-- instruction reference (instructions.lua + instructions_extra.lua, what
-- hover/completion know) and the highlight query's keyword list. They are
-- maintained separately, and skew between them is exactly the kind of drift
-- a user notices before a test does -- unless this file exists.
-- Run with: nvim --headless --clean -l tests/consistency_test.lua (or make test)

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fs.dirname(vim.fn.fnamemodify(script, ":p"))
local plugin_root = vim.fs.dirname(here)
vim.opt.rtp:prepend(plugin_root)

local failed = 0
local function check(desc, ok, detail)
  if ok then
    print("PASS: " .. desc)
  else
    print("FAIL: " .. desc .. (detail and (" -- " .. detail) or ""))
    failed = failed + 1
  end
end

local arity = require("masm.arity")
local instructions = require("masm.instructions")

-- Every mnemonic the simulator understands, sorted for stable output.
local mnemonics = {}
for k in pairs(arity.ops) do
  mnemonics[#mnemonics + 1] = k
end
for k in pairs(arity.special) do
  mnemonics[#mnemonics + 1] = k
end
table.sort(mnemonics)

-- Reference bases: `mem_loadw_be.{n}` and `loc_load.{n}` both count as
-- documenting their mnemonic (hover's family lookup works the same way).
local documented = {}
for _, e in ipairs(instructions) do
  documented[e[1]:match("^[^.{]+"):gsub("%.$", "")] = true
end

-- 1. Everything simulated is documented: an arity entry without a reference
--    entry means hover and completion silently know nothing about an
--    instruction the analyzer simulates. Fill gaps in instructions_extra.lua.
for _, m in ipairs(mnemonics) do
  check("documented: " .. m, documented[m])
end

-- 2. Everything simulated is highlighted as a keyword -- EXCEPT mnemonics
--    the pinned grammar does not tokenize (they parse as identifiers, and a
--    query naming an unknown token is itself invalid). Shrink this allowlist
--    when the grammar pin moves forward.
local GRAMMAR_LACKS_TOKEN = { eqz = true, adv_pushw = true, breakpoint = true }
local hl = assert(io.open(plugin_root .. "/queries/masm/highlights.scm", "r"))
local hl_text = hl:read("*a")
hl:close()
local highlighted = {}
for s in hl_text:gmatch('"([^"]+)"') do
  highlighted[s] = true
end
for _, m in ipairs(mnemonics) do
  if not GRAMMAR_LACKS_TOKEN[m] then
    check("highlighted: " .. m, highlighted[m])
  end
end
for m in pairs(GRAMMAR_LACKS_TOKEN) do
  check(
    "allowlist still needed: " .. m,
    not highlighted[m],
    "the grammar pin grew this token; highlight it and shrink the allowlist"
  )
end

-- 3. No duplicate names across generated + extra reference entries: a
--    duplicate means upstream metadata gained a mnemonic that
--    instructions_extra.lua still carries -- delete it there.
local seen_names, dup = {}, nil
for _, e in ipairs(instructions) do
  if seen_names[e[1]] then
    dup = e[1]
  end
  seen_names[e[1]] = true
end
check("no duplicate reference entries", dup == nil, tostring(dup))

print(failed == 0 and "ALL PASS" or (failed .. " FAILURES"))
if failed > 0 then
  os.exit(1)
end
