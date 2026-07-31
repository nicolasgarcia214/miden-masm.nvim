-- Tests for the stack-effect analyzer: notation parsing (masm.stacknotation),
-- arity-table coverage (masm.arity), the simulation engine (masm.stack) and
-- the UI layer (masm.stackview). Run with:
--   nvim --headless --clean -l tests/stack_test.lua
-- or `make test`.

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fs.dirname(vim.fn.fnamemodify(script, ":p"))
local plugin_root = vim.fs.dirname(here)
vim.opt.rtp:prepend(plugin_root)

local notation = require("masm.stacknotation")

local failed = 0

local function check(desc, ok, detail)
  if ok then
    print("PASS: " .. desc)
  else
    print("FAIL: " .. desc .. (detail and (" -- " .. detail) or ""))
    failed = failed + 1
  end
end

---------------------------------------------------------------------------
-- stacknotation: element sizing
---------------------------------------------------------------------------

local function width_of(list)
  local parsed, reason = notation.parse_list(list)
  return parsed and parsed.width or nil, reason
end

local sizing = {
  { "[]", 0 },
  { "[amount]", 1 },
  { "[ASSET]", 4 },
  { "[ASSET_VALUE_0]", 4 },
  { "[X]", 4 },
  { "[pad(16)]", 16 },
  { "[min_burn_amount, pad(15)]", 16 },
  { "[slot_id_suffix, slot_id_prefix]", 2 },
  { "[account_id_{suffix,prefix}]", 2 },
  { "[slot_id_{suffix, prefix}, VALUE]", 6 },
  { "[LEAF_VALUE[8], GER_LOWER[4]]", 12 },
  { "[dest_address(5), tag]", 6 },
  { "[[RESULT_U256_LO, RESULT_U256_HI]]", 8 },
  { "[current_index + 1, num_notes]", 2 },
  { "[i-1, new_num_of_approvers]", 2 },
  { "[write_ptr']", 1 },
  { "[is_active_note = 0, note_index]", 2 },
  { "[0, 0, 0, amount]", 4 },
  { "[EMPTY_WORD, pad(12)]", 16 },
}
for _, case in ipairs(sizing) do
  local w, reason = width_of(case[1])
  check(
    ("notation: %s -> %d"):format(case[1], case[2]),
    w == case[2],
    ("got %s (%s)"):format(tostring(w), tostring(reason))
  )
end

-- Lower bounds and refusals.
local lb = notation.parse_list("[block_height_delta, ...]")
check("notation: trailing ellipsis is a lower bound", lb and lb.lower_bound and lb.width == 1)
check("notation: ellipsis-only list refused", (notation.parse_list("[...]")) == nil)
check("notation: prose refused", (notation.parse_list("[<values returned>]")) == nil)
check("notation: unbalanced refused", (notation.parse_list("[a, b")) == nil)

-- Expansion into per-felt cells.
local cells = notation.expand(notation.parse_list("[VALUE, pad(2), amount]"))
check("notation: expand widths", #cells == 7)
check("notation: expand word lanes", cells[1].name == "VALUE" and cells[1].lane == 0)
check("notation: expand shared word group", cells[1].group == cells[4].group)
check("notation: expand pad cells are zeros", cells[5].name == "0" and cells[6].name == "0")
check("notation: expand felt", cells[7].name == "amount" and cells[7].group == nil)

---------------------------------------------------------------------------
-- stacknotation: comments and trackers
---------------------------------------------------------------------------

local comment, col = notation.comment_part("    push.1 # => [a]")
check("notation: comment extracted", comment == "# => [a]" and col == 12)
check(
  "notation: hash inside string is not a comment",
  (notation.comment_part('const E = "a # b"')) == nil
)

local kind, value = notation.tracker_kind("# => [a, b]")
check("notation: `# =>` is a tracker", kind == "tracker" and value == "[a, b]")
kind = notation.tracker_kind("# OS => [a]")
check("notation: `# OS =>` is a tracker", kind == "tracker")
check("notation: `# AS =>` ignored", notation.tracker_kind("# AS => {K: v}") == "other-stack")
check("notation: `# LM =>` ignored", notation.tracker_kind("# LM => [x]") == "other-stack")
check("notation: plain comment is not a tracker", notation.tracker_kind("# pad the stack") == nil)

-- Multi-line joining.
local joined, last = notation.join_value("[creator_suffix, note_type,", {
  "code line ignored -- join starts at index of the value's line",
  "#   SERIAL_NUM, ...]",
}, 1)
check(
  "notation: multi-line tracker joins",
  joined == "[creator_suffix, note_type, SERIAL_NUM, ...]" and last == 2,
  tostring(joined)
)
local _, join_err = notation.join_value("[a, b", { "# the value's own line", "push.1" }, 1)
check("notation: join interrupted by code refused", join_err == "bracket list interrupted by code")

---------------------------------------------------------------------------
-- stacknotation: doc contracts
---------------------------------------------------------------------------

local contract = notation.contract({
  "#! Gets an item from the active account storage.",
  "#!",
  "#! Inputs:  [slot_id_suffix, slot_id_prefix]",
  "#! Outputs: [VALUE]",
  "#!",
  "#! Invocation: exec",
})
check("contract: inputs width", contract.inputs and contract.inputs.width == 2)
check("contract: outputs width", contract.outputs and contract.outputs.width == 4)
check("contract: invocation", contract.invocation == "exec")

contract = notation.contract({
  "#! Inputs: [creator_suffix, creator_prefix, note_type, SERIAL_NUM,",
  "#!   pad(9)]",
  "#! Outputs: []",
})
check("contract: multi-line inputs join", contract.inputs and contract.inputs.width == 16)
check("contract: empty outputs", contract.outputs and contract.outputs.width == 0)

contract = notation.contract({
  "#! Inputs: [...]",
  "#! Output: [flag]",
})
check(
  "contract: unparseable inputs carry reason",
  contract.inputs == nil and contract.inputs_reason ~= nil
)
check("contract: singular Output typo accepted", contract.outputs and contract.outputs.width == 1)

---------------------------------------------------------------------------
-- arity: corpus coverage and independently transcribed net deltas
---------------------------------------------------------------------------

local arity = require("masm.arity")

-- Every non-invocation, non-control-flow mnemonic observed in the Miden
-- protocol corpus must resolve in the table (or be a declared special).
-- A new dialect instruction should fail HERE, not silently bail everywhere.
local corpus_vocab = {
  "add",
  "adv_loadw",
  "adv_pipe",
  "adv_push",
  "and",
  "assert",
  "assert_eq",
  "assert_eqw",
  "assertz",
  "caller",
  "cdrop",
  "cdropw",
  "clk",
  "cswap",
  "cswapw",
  "div",
  "drop",
  "dropw",
  "dup",
  "dupw",
  "emit",
  "eq",
  "eqw",
  "eqz",
  "exp",
  "gt",
  "gte",
  "hash",
  "hmerge",
  "hperm",
  "ilog2",
  "inv",
  "is_odd",
  "loc_load",
  "loc_loadw_be",
  "loc_loadw_le",
  "loc_store",
  "loc_storew_be",
  "loc_storew_le",
  "locaddr",
  "lt",
  "lte",
  "mem_load",
  "mem_loadw_be",
  "mem_loadw_le",
  "mem_store",
  "mem_storew_be",
  "mem_storew_le",
  "mem_stream",
  "movdn",
  "movdnw",
  "movup",
  "movupw",
  "mtree_get",
  "mtree_merge",
  "mtree_set",
  "mtree_verify",
  "mul",
  "neg",
  "neq",
  "nop",
  "not",
  "or",
  "padw",
  "pow2",
  "reversew",
  "sdepth",
  "sub",
  "swap",
  "swapdw",
  "swapw",
  "u32and",
  "u32assert",
  "u32assert2",
  "u32cast",
  "u32div",
  "u32divmod",
  "u32gt",
  "u32gte",
  "u32lt",
  "u32lte",
  "u32max",
  "u32min",
  "u32mod",
  "u32not",
  "u32or",
  "u32overflowing_add",
  "u32overflowing_sub",
  "u32popcnt",
  "u32rotl",
  "u32rotr",
  "u32shl",
  "u32shr",
  "u32split",
  "u32test",
  "u32wrapping_add",
  "u32wrapping_mul",
  "u32wrapping_sub",
  "u32xor",
}
for _, name in ipairs(corpus_vocab) do
  check(
    "arity: corpus mnemonic covered: " .. name,
    arity.ops[name] ~= nil or arity.special[name] == true
  )
end

-- Net deltas transcribed from the official instruction reference,
-- independently of the table's pops/pushes split.
local net_deltas = {
  { "add", "bare", -1 },
  { "add", "imm", 0 },
  { "eqw", "bare", 1 },
  { "assert_eqw", "bare", -8 },
  { "u32overflowing_add", "bare", 0 },
  { "u32wrapping_add", "bare", -1 },
  { "u32split", "bare", 1 },
  { "u32testw", "bare", 1 },
  { "cswap", "bare", -1 },
  { "cdropw", "bare", -5 },
  { "mem_load", "bare", 0 },
  { "mem_load", "imm", 1 },
  { "mem_storew_be", "bare", -1 },
  { "mem_storew_be", "imm", 0 },
  { "mem_stream", "bare", 0 },
  { "loc_load", "imm", 1 },
  { "locaddr", "imm", 1 },
  { "hmerge", "bare", -4 },
  { "hperm", "bare", 0 },
  { "mtree_get", "bare", 2 },
  { "mtree_set", "bare", -2 },
  { "mtree_merge", "bare", -4 },
  { "mtree_verify", "bare", 0 },
  { "adv_pipe", "bare", 0 },
  { "ext2mul", "bare", -2 },
}
for _, case in ipairs(net_deltas) do
  local entry = arity.ops[case[1]] and arity.ops[case[1]][case[2]]
  local delta = entry and type(entry[2]) == "number" and (entry[2] - entry[1]) or nil
  check(
    ("arity: %s (%s) net %+d"):format(case[1], case[2], case[3]),
    delta == case[3],
    "got " .. tostring(delta)
  )
end

---------------------------------------------------------------------------
-- engine: the fixture program (min_burn_amount regression pair et al.)
---------------------------------------------------------------------------

local stack = require("masm.stack")
local fixture = here .. "/fixtures/app/stack.masm"
vim.cmd("edit! " .. fixture)
local bufnr = vim.api.nvim_get_current_buf()
local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

-- Line lookup by content, never by number (fixture edits must not silently
-- shift assertions). `nth` selects among multiple matches.
local function line_of(frag, nth)
  local seen = 0
  for i, l in ipairs(buf_lines) do
    if l:find(frag, 1, true) then
      seen = seen + 1
      if seen == (nth or 1) then
        return i
      end
    end
  end
  error("fixture locator not found: " .. frag)
end

local result, reason = stack.analyze(bufnr)
check("engine: fixture analyzes", result ~= nil, tostring(reason))

local by_code = {}
local function diag_at(code, lnum)
  for _, d in ipairs(result.diagnostics) do
    if d.code == code and d.lnum == lnum then
      return d
    end
  end
  return nil
end
for _, d in ipairs(result.diagnostics) do
  by_code[d.code] = (by_code[d.code] or 0) + 1
end

-- The regression pair: buggy proc flagged at the stale tracker and at `end`;
-- the corrected twin is silent.
local stale1 = line_of("# => [min_value, 0, 0, 0, pad(12)]")
check("engine: buggy tracker flagged", diag_at("comment-stale", stale1) ~= nil)
local buggy_cleanup = line_of("movdn.3 drop drop drop")
check("engine: buggy final tracker flagged too", diag_at("comment-stale", buggy_cleanup + 1) ~= nil)
local buggy_end = buggy_cleanup + 2 -- tracker line, then `end`
local exit_diag = diag_at("exit-depth", buggy_end)
check("engine: buggy exit flagged as error", exit_diag ~= nil and exit_diag.severity == "error")
check(
  "engine: exit message names the VM error",
  exit_diag ~= nil and exit_diag.message:find("InvalidStackDepthOnReturn", 1, true) ~= nil
)
check("engine: exactly one exit-depth", by_code["exit-depth"] == 1)

-- Doc-contract ABI check on the 12-element call proc.
check("engine: abi-16 on Inputs line", diag_at("abi-16", line_of("Inputs:  [a, pad(11)]")) ~= nil)
check("engine: abi-16 on Outputs line", diag_at("abi-16", line_of("Outputs: [a, pad(11)]")) ~= nil)
check("engine: exactly two abi-16", by_code["abi-16"] == 2)

-- Control flow.
check(
  "engine: branch mismatch flagged",
  diag_at("branch-depth", line_of("push.1 push.2") + 1) ~= nil
)
check("engine: bad while flagged", diag_at("while-net", line_of("push.0 push.0") - 1) ~= nil)
check("engine: exactly one branch-depth", by_code["branch-depth"] == 1)
check("engine: exactly one while-net", by_code["while-net"] == 1)

-- Exec-mode checks.
check("engine: exec net mismatch flagged", by_code["exec-net"] == 1)
check(
  "engine: caller underflow flagged",
  diag_at("caller-underflow", line_of("drop drop", 2)) ~= nil
)
check(
  "engine: unresolved callee is a hint",
  diag_at("callee-unresolved", line_of("exec.math::add_checked")) ~= nil
)

-- No other diagnostics: diverge_ok, loop_ok, floor_drop, const_widths, the
-- corrected twin and the three corpus-rule pins (near_floor_poison,
-- floor_debt_view, caps_felt_const) must all be silent.
check("engine: total diagnostic count", #result.diagnostics == 10, tostring(#result.diagnostics))

-- Bails carry reasons; analyzed procs carry states.
local procs = {}
for _, p in ipairs(result.procs) do
  procs[p.name] = p
end
check(
  "engine: unknown instruction bails with reason",
  procs.unknown_instr.bailed ~= nil
    and procs.unknown_instr.bailed:find("frobnicate", 1, true) ~= nil
)
check(
  "engine: unannotated proc skipped with reason",
  procs.unannotated.bailed ~= nil and procs.unannotated.bailed:find("Invocation", 1, true) ~= nil
)
check("engine: good twin not bailed", procs.get_min_value_good.bailed == nil)
check(
  "engine: good twin exit renders with adopted names",
  stack.render_cells(procs.get_min_value_good.exit) == "[min_value, pad(15)]",
  stack.render_cells(procs.get_min_value_good.exit)
)
check(
  "engine: buggy exit is depth 17",
  procs.get_min_value_buggy.exit and #procs.get_min_value_buggy.exit.cells == 17
)

-- The corpus-tuned semantic rules, pinned as regressions. These were tuned
-- against the full protocol repo (zero false positives across 849 procs);
-- a refactor that breaks any of them must fail HERE, not in the field.

-- 1. An exec whose declared consumption reaches near the 16-floor has an
--    internals-dependent exit depth: poison, then resync at the tracker.
local nf = procs.near_floor_poison
local nf_state = nf.states[line_of("exec.registry::get_item", 3)]
check(
  "engine: near-floor exec poisons",
  nf_state ~= nil
    and nf_state.poisoned ~= nil
    and nf_state.poisoned:find("callee internals", 1, true) ~= nil,
  nf_state and tostring(nf_state.poisoned) or "no state"
)
check(
  "engine: near-floor tracker resynchronizes",
  nf.bailed == nil and nf.exit ~= nil and nf.exit.poisoned == nil and #nf.exit.cells == 16
)

-- 2. A tracker counting the un-pulled view (claim == sim - floor_debt over
--    an all-zero surplus) is a convention, not a stale comment.
local fd = procs.floor_debt_view
check(
  "engine: floor-debt tracker accepted",
  diag_at("comment-stale", line_of("# => [pad(14)]")) == nil
    and fd.exit ~= nil
    and fd.exit.floor_debt == 2,
  fd.exit and tostring(fd.exit.floor_debt) or "no exit"
)

-- 3. An ALL-CAPS tracker element naming a felt constant re-sizes to 1 felt
--    when the sim cell at that position is an ungrouped match.
local caps_lnum = line_of("# => [SUBKEY_HI, pad(16)]")
check("engine: caps felt-const tracker accepted", diag_at("comment-stale", caps_lnum) == nil)
local caps_state = procs.caps_felt_const.states[caps_lnum]
check(
  "engine: caps felt-const adopted at width 1",
  caps_state ~= nil and stack.render_cells(caps_state) == "[SUBKEY_HI, pad(16)]",
  caps_state and stack.render_cells(caps_state) or "no state"
)

---------------------------------------------------------------------------
-- stackview: diagnostics publishing, config gates, overlay extmarks
---------------------------------------------------------------------------

local stackview = require("masm.stackview")
stackview.attach(bufnr)
stackview.refresh(bufnr)

local function published()
  return vim.diagnostic.get(bufnr, { namespace = stackview._diag_ns })
end

-- Default config: hints filtered, 9 non-hint diagnostics published.
check("view: diagnostics published", #published() == 9, tostring(#published()))
local has_error = false
for _, d in ipairs(published()) do
  if d.severity == vim.diagnostic.severity.ERROR and d.code == "exit-depth" then
    has_error = true
  end
end
check("view: exit-depth published as ERROR", has_error)

-- Config gates, re-read on every refresh.
vim.g.masm_stack = { check_comments = false }
stackview.refresh(bufnr)
local stale_seen = false
for _, d in ipairs(published()) do
  if d.code == "comment-stale" then
    stale_seen = true
  end
end
check("view: check_comments=false hides stale warnings", not stale_seen)

vim.g.masm_stack = { bail_hints = true }
stackview.refresh(bufnr)
local hint_seen = false
for _, d in ipairs(published()) do
  if d.code == "callee-unresolved" then
    hint_seen = true
  end
end
check("view: bail_hints=true publishes hints", hint_seen)

vim.g.masm_stack = { diagnostics = false }
stackview.refresh(bufnr)
check("view: diagnostics=false publishes nothing", #published() == 0)
vim.g.masm_stack = nil

-- Overlay: off by default, eol ghost text after toggle.
stackview.refresh(bufnr)
local function marks()
  return vim.api.nvim_buf_get_extmarks(bufnr, stackview._mark_ns, 0, -1, { details = true })
end
check("view: overlay off by default", #marks() == 0)
stackview.toggle(bufnr)
local auto_marks = marks()
check("view: overlay shows ghost text", #auto_marks > 0)
local function mark_on(lnum)
  for _, m in ipairs(marks()) do
    if m[2] == lnum - 1 then
      return m
    end
  end
  return nil
end
-- Auto mode: hand-annotated lines stay clean, unannotated lines get ghosts.
check("view: no ghost on hand-annotated line", mark_on(line_of("push.WORD_CONST")) == nil)
local ghost = mark_on(line_of("push.FELT_CONST"))
check("view: ghost on unannotated line", ghost ~= nil)
check(
  "view: ghost uses the analyzer highlight",
  ghost ~= nil and ghost[4].virt_text[1][2] == "MasmStackVirtualText"
)
local stale_mark = mark_on(stale1)
check(
  "view: stale tracker line gets corrected ghost",
  stale_mark ~= nil and stale_mark[4].virt_text[1][2] == "MasmStackVirtualTextStale"
)
check(
  "view: bailed proc annotated at its declaration",
  mark_on(line_of("pub proc unannotated")) ~= nil
)

-- "all" mode covers annotated lines too.
vim.g.masm_stack = { overlay_mode = "all" }
stackview.refresh(bufnr)
check("view: all mode ghosts annotated lines", mark_on(line_of("push.WORD_CONST")) ~= nil)
vim.g.masm_stack = nil

stackview.toggle(bufnr)
check("view: toggle off clears ghosts", #marks() == 0)

stackview.detach(bufnr)
check("view: detach clears diagnostics", #published() == 0)

-- Dialect-drift canary rides the same pipeline: an unrecognized use form in
-- the buffer is published as a masm-goto WARN alongside stack diagnostics.
vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "use miden::core::math::{rusty}" })
stackview.attach(bufnr)
stackview.refresh(bufnr)
local drift_diag
for _, d in ipairs(vim.diagnostic.get(bufnr, { namespace = stackview._diag_ns })) do
  if d.code == "unrecognized-import" then
    drift_diag = d
  end
end
check(
  "view: drift canary published",
  drift_diag ~= nil and drift_diag.lnum == 0 and drift_diag.source == "masm-goto",
  vim.inspect(drift_diag)
)
stackview.detach(bufnr)
vim.cmd("edit!") -- drop the injected line so later suites see the fixture as on disk

---------------------------------------------------------------------------

if failed > 0 then
  print(("stack tests: %d failure(s)"):format(failed))
  os.exit(1)
end
print("stack tests: all passed")
