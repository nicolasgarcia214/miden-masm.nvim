-- Tests for the stack-effect analyzer: notation parsing (masm.stacknotation),
-- arity-table coverage (masm.arity), the simulation engine (masm.stack) and
-- the UI layer (masm.stackview). Run with:
--   nvim --headless --clean -l tests/stack_test.lua
-- or `make test`.

local helpers = dofile(
  vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")) .. "/helpers.lua"
)
local here = helpers.here
local check = helpers.check

local notation = require("masm.stacknotation")

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
local cells = notation.expand(assert(notation.parse_list("[VALUE, pad(2), amount]")))
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
-- The fast-path/segment rewrite's edge cases, pinned (verified against the
-- old per-byte implementation by a corpus + 50k-case differential fuzz).
comment, col = notation.comment_part('const E = "a # b" # real')
check("notation: comment after a string with a hash", comment == "# real" and col == 19)
check(
  "notation: escaped quote cannot close the string",
  (notation.comment_part('const E = "a \\" # not closed')) == nil
)
comment, col = notation.comment_part('const E = "esc\\\\" # yes')
check("notation: escaped backslash still closes", comment == "# yes" and col == 19)
comment, col = notation.comment_part("#! doc line")
check("notation: line-leading `#!` extracted whole", comment == "#! doc line" and col == 1)
check("notation: no comment yields nil", (notation.comment_part("push.1 drop")) == nil)

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
-- Everything below dereferences the result, so a failed analysis is fatal
-- to the whole block anyway; failing here names the reason instead of
-- erroring on the first nil index (and narrows the type for the checker).
result = assert(result, tostring(reason))

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
-- engine: order-aware comment checking (same multiset, different order)
---------------------------------------------------------------------------

-- Virtual file under the fixture app dir so the resolver has a project.
local function analyze_virtual(lines)
  return stack.analyze_lines(lines, here .. "/fixtures/app/virtual.masm")
end

local function reorder_proc(tracker)
  return {
    "#! Invocation: call",
    "#! Inputs:  [b, a, pad(14)]",
    "#! Outputs: [a, b, pad(14)]",
    "proc reorder",
    "    swap",
    "    " .. tracker,
    "end",
  }
end

local vres = analyze_virtual(reorder_proc("# => [b, a, pad(14)]"))
local reorder_diag
for _, d in ipairs(vres and vres.diagnostics or {}) do
  if d.code == "comment-reordered" then
    reorder_diag = d
  end
end
check("order: swapped comment flagged", reorder_diag ~= nil and reorder_diag.lnum == 6)
check(
  "order: message shows the simulated stack",
  reorder_diag ~= nil and reorder_diag.message:find("[a, b, pad(14)]", 1, true) ~= nil,
  reorder_diag and reorder_diag.message
)
check(
  "order: wrong order not adopted, exit stays correct",
  vres ~= nil and #vres.diagnostics == 1,
  vres and tostring(#vres.diagnostics)
)

vres = analyze_virtual(reorder_proc("# => [a, b, pad(14)]"))
check("order: correct comment silent", vres ~= nil and #vres.diagnostics == 0)

-- Synonyms (different name multiset) stay exempt: adoption, no judgment.
vres = analyze_virtual(reorder_proc("# => [x, y, pad(14)]"))
check("order: renamed elements not flagged", vres ~= nil and #vres.diagnostics == 0)

-- Anonymous cells (unknown callee outputs) can never trip the check.
vres = analyze_virtual({
  "#! Invocation: call",
  "#! Inputs:  [b, a, pad(14)]",
  "#! Outputs: [a, b, pad(14)]",
  "proc reorder",
  "    dyncall",
  "    # => [b, a, pad(14)]",
  "end",
})
local anon_flagged = false
for _, d in ipairs(vres and vres.diagnostics or {}) do
  if d.code == "comment-reordered" then
    anon_flagged = true
  end
end
check("order: anonymous cells exempt", not anon_flagged)

---------------------------------------------------------------------------
-- engine: one-line bodies and out-of-range positional immediates
---------------------------------------------------------------------------

-- Body tokens on the declaration line are legal MASM. Events are line-based,
-- so the engine must refuse such a proc with a reason (never silently
-- simulate an empty body) -- and its `end` must not be stolen from the NEXT
-- proc, whose analysis must stay intact.
vres = analyze_virtual({
  "#! Invocation: call",
  "#! Inputs:  [pad(16)]",
  "#! Outputs: [pad(16)]",
  "proc oneliner push.1 drop end",
  "",
  "#! Invocation: call",
  "#! Inputs:  [b, a, pad(14)]",
  "#! Outputs: [a, b, pad(14)]",
  "proc after_oneliner",
  "    swap",
  "end",
})
local oneliner, after_oneliner
for _, p in ipairs(vres and vres.procs or {}) do
  if p.name == "oneliner" then
    oneliner = p
  elseif p.name == "after_oneliner" then
    after_oneliner = p
  end
end
check(
  "one-line proc: bailed with a stated reason",
  oneliner ~= nil and oneliner.bailed ~= nil and oneliner.bailed:find("declaration line") ~= nil,
  oneliner and tostring(oneliner.bailed) or "proc not scanned"
)
check(
  "one-line proc: own end found, not stolen",
  oneliner ~= nil and oneliner.end_lnum == 4,
  oneliner and tostring(oneliner.end_lnum) or "?"
)
check(
  "one-line proc: following proc analyzed cleanly",
  after_oneliner ~= nil
    and after_oneliner.bailed == nil
    and after_oneliner.end_lnum == 11
    and vres ~= nil
    and #vres.diagnostics == 0,
  after_oneliner and (tostring(after_oneliner.bailed) .. "/" .. tostring(after_oneliner.end_lnum))
    or "proc not scanned"
)

-- `movup.99` cannot assemble; simulating it would model impossible code (and
-- in relative mode manufacture a phantom caller draw). Bail like an unknown
-- mnemonic instead.
vres = analyze_virtual({
  "#! Invocation: exec",
  "#! Inputs:  [a]",
  "#! Outputs: [a]",
  "proc bad_index",
  "    movup.99",
  "end",
})
local bad_index = vres and vres.procs[1]
check(
  "positional range: movup.99 bails with a reason",
  bad_index ~= nil and bad_index.bailed ~= nil and bad_index.bailed:find("2..15", 1, true) ~= nil,
  bad_index and tostring(bad_index.bailed) or "no proc"
)
check(
  "positional range: no diagnostics from unassemblable code",
  vres ~= nil and #vres.diagnostics == 0
)

-- In-range indices keep simulating exactly as before.
vres = analyze_virtual({
  "#! Invocation: call",
  "#! Inputs:  [c, b, a, pad(13)]",
  "#! Outputs: [a, c, b, pad(13)]",
  "proc fine_index",
  "    movup.2",
  "end",
})
check(
  "positional range: movup.2 still simulated",
  vres ~= nil and vres.procs[1] ~= nil and vres.procs[1].bailed == nil and #vres.diagnostics == 0,
  vres and vres.procs[1] and tostring(vres.procs[1].bailed) or "no result"
)

-- Bases absent from SPECIAL_RANGE take no index at all (the reference
-- documents swapdw/reversew/reversedw bare only): an immediate must bail
-- exactly like movup.99, never be silently accepted.
for _, bad in ipairs({ "swapdw.3", "reversew.9", "reversedw.1" }) do
  vres = analyze_virtual({
    "#! Invocation: call",
    "#! Inputs:  [pad(16)]",
    "#! Outputs: [pad(16)]",
    "proc no_imm_op",
    "    " .. bad,
    "end",
  })
  local no_imm = vres and vres.procs[1]
  check(
    "positional range: " .. bad .. " bails with a reason",
    no_imm ~= nil
      and no_imm.bailed ~= nil
      and no_imm.bailed:find("no index immediate", 1, true) ~= nil
      and #vres.diagnostics == 0,
    no_imm and tostring(no_imm.bailed) or "no proc"
  )
end

-- ...while the bare forms keep simulating (all net 0 at depth 16).
vres = analyze_virtual({
  "#! Invocation: call",
  "#! Inputs:  [pad(16)]",
  "#! Outputs: [pad(16)]",
  "proc bare_shuffles",
  "    swapdw",
  "    reversew",
  "    reversedw",
  "end",
})
check(
  "positional range: bare swapdw/reversew/reversedw still simulated",
  vres ~= nil and vres.procs[1] ~= nil and vres.procs[1].bailed == nil and #vres.diagnostics == 0,
  vres and vres.procs[1] and tostring(vres.procs[1].bailed) or "no result"
)

-- `emit` flows through arity.ops (not the decorator intercept): both forms
-- are net 0, so a depth-16 proc stays clean.
vres = analyze_virtual({
  "#! Invocation: call",
  "#! Inputs:  [pad(16)]",
  "#! Outputs: [pad(16)]",
  "proc emits",
  "    emit.event::something",
  "    emit",
  "end",
})
check(
  "arity: emit bare and immediate simulate as net 0",
  vres ~= nil and vres.procs[1] ~= nil and vres.procs[1].bailed == nil and #vres.diagnostics == 0,
  vres and vres.procs[1] and tostring(vres.procs[1].bailed) or "no result"
)

---------------------------------------------------------------------------
-- engine: unterminated procedures (missing `end`)
---------------------------------------------------------------------------

-- A proc missing its `end` must not swallow the declarations below it: the
-- next `proc` line ends it as unterminated, it gets a real WARN diagnostic
-- (an end-less proc is a syntax error the assembler rejects, so this can
-- never false-positive on valid code -- the corpus oracle pins that), and
-- every proc below still analyzes with its own diagnostics intact.
vres = analyze_virtual({
  "#! Invocation: call",
  "#! Inputs:  [pad(16)]",
  "#! Outputs: [pad(16)]",
  "proc unterminated_mid",
  "    push.1",
  "",
  "#! Invocation: call",
  "#! Inputs:  [b, a, pad(14)]",
  "#! Outputs: [a, b, pad(14)]",
  "proc below_unterminated",
  "    swap",
  "    # => [a, b, pad(15)]",
  "end",
})
local unterminated, below
for _, p in ipairs(vres and vres.procs or {}) do
  if p.name == "unterminated_mid" then
    unterminated = p
  elseif p.name == "below_unterminated" then
    below = p
  end
end
check(
  "missing end: proc bails with the missing-end reason",
  unterminated ~= nil
    and unterminated.end_lnum == nil
    and unterminated.bailed ~= nil
    and unterminated.bailed:find("missing", 1, true) ~= nil,
  unterminated and tostring(unterminated.bailed) or "proc not scanned"
)
local missing_end_diag
for _, d in ipairs(vres and vres.diagnostics or {}) do
  if d.code == "missing-end" then
    missing_end_diag = d
  end
end
check(
  "missing end: real WARN diagnostic on the declaration line",
  missing_end_diag ~= nil and missing_end_diag.severity == "warn" and missing_end_diag.lnum == 4,
  vim.inspect(missing_end_diag)
)
local below_stale
for _, d in ipairs(vres and vres.diagnostics or {}) do
  if d.code == "comment-stale" and d.lnum == 12 then
    below_stale = d
  end
end
check(
  "missing end: proc below still analyzed, own end, own diagnostics",
  below ~= nil and below.bailed == nil and below.end_lnum == 13 and below_stale ~= nil,
  below and (tostring(below.bailed) .. "/" .. tostring(below.end_lnum)) or "proc not scanned"
)
check(
  "missing end: exactly the two expected diagnostics",
  vres ~= nil and #vres.diagnostics == 2,
  vres and tostring(#vres.diagnostics)
)

-- The in-progress-typing shape: a bare `proc` line (no body, no doc block
-- yet) above existing procs. The new proc warns; everything below is
-- untouched. No invocation annotation is needed for the warn -- the syntax
-- error stands on its own.
vres = analyze_virtual({
  "proc being_typed",
  "",
  "#! Invocation: call",
  "#! Inputs:  [b, a, pad(14)]",
  "#! Outputs: [a, b, pad(14)]",
  "proc existing_below",
  "    swap",
  "end",
})
local typed, existing
for _, p in ipairs(vres and vres.procs or {}) do
  if p.name == "being_typed" then
    typed = p
  elseif p.name == "existing_below" then
    existing = p
  end
end
check(
  "missing end: freshly typed proc line warns without an Invocation tag",
  typed ~= nil
    and typed.bailed ~= nil
    and vres ~= nil
    and #vres.diagnostics == 1
    and vres.diagnostics[1].code == "missing-end"
    and vres.diagnostics[1].lnum == 1,
  vres and vim.inspect(vres.diagnostics) or "no result"
)
check(
  "missing end: existing proc below stays clean",
  existing ~= nil and existing.bailed == nil and existing.end_lnum == 8,
  existing and (tostring(existing.bailed) .. "/" .. tostring(existing.end_lnum)) or "not scanned"
)

-- A trailing proc with neither an `end` nor a following declaration still
-- warns (it runs to end-of-file, as before).
vres = analyze_virtual({
  "#! Invocation: call",
  "#! Inputs:  [pad(16)]",
  "#! Outputs: [pad(16)]",
  "proc trailing_unterminated",
  "    push.1",
})
check(
  "missing end: trailing unterminated proc warns too",
  vres ~= nil
    and #vres.diagnostics == 1
    and vres.diagnostics[1].code == "missing-end"
    and vres.diagnostics[1].lnum == 4,
  vres and vim.inspect(vres.diagnostics) or "no result"
)

---------------------------------------------------------------------------
-- engine: empty input edge cases
---------------------------------------------------------------------------

vres = analyze_virtual({})
check(
  "empty input: zero lines analyze to an empty result",
  vres ~= nil and #vres.procs == 0 and #vres.diagnostics == 0,
  vres and vim.inspect(vres) or "nil result"
)
vres = analyze_virtual({ "" })
check(
  "empty input: a single empty line analyzes to an empty result",
  vres ~= nil and #vres.procs == 0 and #vres.diagnostics == 0,
  vres and vim.inspect(vres) or "nil result"
)

---------------------------------------------------------------------------
-- engine: begin..end entrypoint blocks are analyzed (floored, 16-element)
---------------------------------------------------------------------------

-- A program ending deeper than 16 is rejected by the VM (outputs cap at 16).
vres = analyze_virtual({ "begin", "    push.1", "end" })
local entry_diag = vres and vres.diagnostics[1]
check(
  "entrypoint: ending deeper than 16 flagged",
  entry_diag ~= nil and entry_diag.code == "exit-depth" and entry_diag.severity == "error",
  vim.inspect(entry_diag)
)

-- Depth-neutral programs are fine; ending at exactly 16 has no error.
vres = analyze_virtual({ "begin", "    push.1", "    drop", "end" })
check("entrypoint: neutral program silent", vres ~= nil and #vres.diagnostics == 0)

-- Declared inputs enter named and zero-padded to 16; trackers are checked.
-- (`# => [sum]` alone would be accepted as a legitimate prefix-only claim;
-- a claim that accounts for padding but gets the total wrong is the bug.)
vres = analyze_virtual({
  "#! Inputs: [a, b]",
  "begin",
  "    add",
  "    # => [sum, pad(16)]",
  "end",
})
local entry_stale
for _, d in ipairs(vres and vres.diagnostics or {}) do
  if d.code == "comment-stale" then
    entry_stale = d
  end
end
check(
  "entrypoint: wrong-width tracker flagged",
  entry_stale ~= nil and entry_stale.lnum == 4,
  vim.inspect(vres and vres.diagnostics)
)
vres = analyze_virtual({
  "#! Inputs: [a, b]",
  "begin",
  "    add",
  "    # => [sum, pad(15)]",
  "end",
})
check("entrypoint: full-width tracker accepted", vres ~= nil and #vres.diagnostics == 0)
local begin_proc = vres and vres.procs[1]
check(
  "entrypoint: overlay state available for begin",
  begin_proc ~= nil and begin_proc.name == "begin" and next(begin_proc.states) ~= nil
)

---------------------------------------------------------------------------
-- engine: per-procedure memoization
---------------------------------------------------------------------------

-- The memo must be invisible in results (the corpus oracle pins that); these
-- tests pin WHICH procs re-analyze, via the exposed hit/miss counters.
local function reset_memo_stats()
  stack._memo_stats.hits, stack._memo_stats.misses = 0, 0
end

local memo_src = {
  "#! Invocation: exec",
  "#! Inputs:  [a, b]",
  "#! Outputs: [sum]",
  "proc callee_memo",
  "    add",
  "end",
  "",
  "#! Invocation: exec",
  "#! Inputs:  [a, b]",
  "#! Outputs: [sum]",
  "proc caller_memo",
  "    exec.callee_memo",
  "end",
}
stack.clear_cache()
analyze_virtual(memo_src) -- populate the memo
reset_memo_stats()
analyze_virtual(memo_src)
check(
  "memo: unchanged procs all hit",
  stack._memo_stats.hits == 2 and stack._memo_stats.misses == 0,
  stack._memo_stats.hits .. "/" .. stack._memo_stats.misses
)

-- (i) A body edit invalidates exactly the edited proc; the sibling still
-- hits (its own text and its view of the callee CONTRACT are unchanged).
local body_edit = vim.deepcopy(memo_src)
body_edit[5] = "    swap add"
reset_memo_stats()
analyze_virtual(body_edit)
check(
  "memo: edited proc re-analyzes, untouched sibling hits",
  stack._memo_stats.hits == 1 and stack._memo_stats.misses == 1,
  stack._memo_stats.hits .. "/" .. stack._memo_stats.misses
)

-- (ii) Editing the CALLEE's Outputs contract must re-analyze the caller
-- too: the caller's cached result depends on the contract it spliced in
-- (the cross-proc dependency the dep signatures exist for).
local out_edit = vim.deepcopy(memo_src)
out_edit[3] = "#! Outputs: [sum, carry]"
reset_memo_stats()
local ores = analyze_virtual(out_edit)
check(
  "memo: callee Outputs change re-analyzes the caller",
  stack._memo_stats.hits == 0 and stack._memo_stats.misses == 2,
  stack._memo_stats.hits .. "/" .. stack._memo_stats.misses
)
-- ...and the re-analysis is real: the caller's body now leaves one element
-- but its own Outputs still declare one while the callee delivers two.
local caller_net
for _, d in ipairs(ores and ores.diagnostics or {}) do
  if d.code == "exec-net" and d.lnum == 13 then
    caller_net = d
  end
end
check(
  "memo: stale caller diagnostic replaced after contract change",
  caller_net ~= nil,
  vim.inspect(ores and ores.diagnostics)
)

---------------------------------------------------------------------------
-- engine: poisoned states and the caller-underflow tally
---------------------------------------------------------------------------

-- An undocumented exec callee poisons the state; the draws the later drops
-- make are phantom cells from an unknowable suffix, not the caller's declared
-- Inputs -- they must not count toward caller-underflow (which used to fire
-- here, on a state the analyzer had itself declared unknowable).
local poisoned_draws_src = {
  "#! Invocation: exec",
  "#! Inputs:  [a]",
  "#! Outputs: []",
  "proc poisoned_draws",
  "    exec.nowhere::missing",
  "    drop drop drop",
  "end",
}
vres = analyze_virtual(poisoned_draws_src)
local function codes_of(res)
  local out = {}
  for _, d in ipairs(res and res.diagnostics or {}) do
    out[#out + 1] = d.code
  end
  return table.concat(out, ",")
end
check(
  "poison: no caller-underflow from draws under a poison",
  vres ~= nil and codes_of(vres) == "callee-unresolved",
  codes_of(vres)
)
-- Warm pass must replay the identical outcome (memo lockstep).
vres = analyze_virtual(poisoned_draws_src)
check(
  "poison: warm pass replays the same outcome",
  vres ~= nil and codes_of(vres) == "callee-unresolved",
  codes_of(vres)
)

-- The recovery the callee-unresolved hint promises must actually recover:
-- after the `# => [...]` resync nothing consumed-based may linger (the
-- phantom draws left no tally to trip over).
vres = analyze_virtual({
  "#! Invocation: exec",
  "#! Inputs:  [a]",
  "#! Outputs: [b]",
  "proc resync_after_poison",
  "    exec.nowhere::missing",
  "    drop drop",
  "    # => [b]",
  "end",
})
local resynced = vres and vres.procs[1]
check(
  "poison: tracker resync leaves no residual consumed diagnostics",
  vres ~= nil and codes_of(vres) == "callee-unresolved",
  codes_of(vres)
)
check(
  "poison: resynced exit is clean (unpoisoned, tally zeroed)",
  resynced ~= nil
    and resynced.exit ~= nil
    and resynced.exit.poisoned == nil
    and resynced.exit.consumed == 0
    and #resynced.exit.cells == 1,
  resynced and vim.inspect(resynced.exit) or "no proc"
)

-- The happy path stays detected: a genuine (unpoisoned) draw beyond the
-- declared Inputs still warns, at the line of the first draw.
vres = analyze_virtual({
  "#! Invocation: exec",
  "#! Inputs:  [a]",
  "#! Outputs: []",
  "proc real_underflow",
  "    drop drop",
  "end",
})
local real_cu = vres and vres.diagnostics[1]
check(
  "poison: genuine caller-underflow still fires",
  vres ~= nil
    and #vres.diagnostics == 1
    and real_cu.code == "caller-underflow"
    and real_cu.lnum == 5
    and real_cu.message:find("1 element", 1, true) ~= nil,
  vres and vim.inspect(vres.diagnostics) or "no result"
)

---------------------------------------------------------------------------
-- engine: positional shuffles move the RIGHT cells (names, not just depth)
---------------------------------------------------------------------------

-- Felt-granular index shuffling is the module's core design premise, so
-- each hand-written shuffle is pinned by its full output permutation over
-- named inputs -- an off-by-one in any of them fails here instead of
-- silently corrupting name tracking (and every downstream comment-stale/
-- comment-reordered diagnostic) in the field.
local function names_after(op, inputs)
  local sres = analyze_virtual({
    "#! Invocation: exec",
    "#! Inputs:  [" .. inputs .. "]",
    "#! Outputs: [" .. inputs .. "]",
    "proc shuffle_probe",
    "    " .. op,
    "end",
  })
  local p = sres and sres.procs[1]
  if not p or p.bailed or not p.exit or p.exit.poisoned then
    return "unavailable: " .. tostring(p and (p.bailed or (p.exit and p.exit.poisoned)))
  end
  local out = {}
  for _, c in ipairs(p.exit.cells) do
    out[#out + 1] = c.name or "?"
  end
  return table.concat(out, " ")
end

local W8 = "a, b, c, d, e, f, g, h"
local W12 = W8 .. ", i, j, k, l"
local W16 = W12 .. ", m, n, o, p"
for _, case in ipairs({
  { "swap", "a, b", "b a" },
  { "swap.3", "a, b, c, d", "d b c a" },
  { "movup.2", "a, b, c, d", "c a b d" },
  { "movup.15", W16, "p a b c d e f g h i j k l m n o" },
  { "movdn.2", "a, b, c, d", "b c a d" },
  { "movdn.15", W16, "b c d e f g h i j k l m n o p a" },
  { "dup", "a, b", "a a b" },
  { "dup.1", "a, b", "b a b" },
  { "dupw.1", W8, "e f g h a b c d e f g h" },
  { "swapw.1", W8, "e f g h a b c d" },
  { "swapw.3", W16, "m n o p e f g h i j k l a b c d" },
  { "swapdw", W16, "i j k l m n o p a b c d e f g h" },
  { "movupw.2", W12, "i j k l a b c d e f g h" },
  { "movupw.3", W16, "m n o p a b c d e f g h i j k l" },
  { "movdnw.2", W12, "e f g h i j k l a b c d" },
  { "movdnw.3", W16, "e f g h i j k l m n o p a b c d" },
  { "reversew", "a, b, c, d", "d c b a" },
  { "reversedw", W8, "h g f e d c b a" },
}) do
  local got = names_after(case[1], case[2])
  check("shuffle: " .. case[1] .. " permutes exactly", got == case[3], got)
end

---------------------------------------------------------------------------
-- engine: callee-unresolved dedup happens at publish time, per target
---------------------------------------------------------------------------

-- Two procs exec'ing the same unresolved callee publish ONE hint (the first
-- site in file order); a distinct target publishes its own. Per-proc
-- results stay pass-order independent: each proc's own diagnostics carry
-- its own hint, only the published file result is deduplicated.
local dedup_src = {
  "#! Invocation: exec",
  "#! Inputs:  []",
  "#! Outputs: []",
  "proc first_caller",
  "    exec.nowhere::missing",
  "    # => []",
  "end",
  "",
  "#! Invocation: exec",
  "#! Inputs:  []",
  "#! Outputs: []",
  "proc second_caller",
  "    exec.nowhere::missing",
  "    # => []",
  "end",
  "",
  "#! Invocation: exec",
  "#! Inputs:  []",
  "#! Outputs: []",
  "proc other_caller",
  "    exec.nowhere::other",
  "    # => []",
  "end",
}
vres = analyze_virtual(dedup_src)
local hint_lines = {}
for _, d in ipairs(vres and vres.diagnostics or {}) do
  if d.code == "callee-unresolved" then
    hint_lines[#hint_lines + 1] = d.lnum
  end
end
check(
  "hint dedup: one published hint per distinct target, first site wins",
  vres ~= nil and #hint_lines == 2 and hint_lines[1] == 5 and hint_lines[2] == 21,
  vim.inspect(hint_lines)
)
check(
  "hint dedup: every proc keeps its own hint (pass-order independent)",
  vres ~= nil
    and #vres.procs[1].diagnostics == 1
    and #vres.procs[2].diagnostics == 1
    and vres.procs[2].diagnostics[1].code == "callee-unresolved",
  vres and vim.inspect(vres.procs[2].diagnostics) or "no result"
)

-- The memo interaction the old in-analysis dedup made fragile: edit only
-- the SECOND caller (first is a memo hit, second re-analyzes) and the
-- warm result must be bit-identical to a cold pass over the same content.
local dedup_edited = vim.deepcopy(dedup_src)
table.insert(dedup_edited, 14, "    push.1 drop")
local warm_edited = analyze_virtual(dedup_edited)
stack.clear_cache()
local cold_edited = analyze_virtual(dedup_edited)
check(
  "hint dedup: warm pass after a partial edit equals the cold pass",
  vim.deep_equal(warm_edited, cold_edited),
  vim.inspect(warm_edited and warm_edited.diagnostics)
)

---------------------------------------------------------------------------
-- engine: cross-file lookups are live-buffer-wins, like resolution
---------------------------------------------------------------------------

-- The resolver reads a MODIFIED loaded buffer's live text and returns live
-- line numbers; the analyzer's contract and constant lookups must read the
-- same text. Reading disk here served a stale contract after an unsaved
-- callee edit -- and when the edit shifted lines, missed the declaration
-- entirely and reported a hint about a line where one is plainly visible.
local reg_path = here .. "/fixtures/core_lib/registry.masm"
local live_caller = {
  "use fix::core::registry",
  "",
  "#! Invocation: exec",
  "#! Inputs:  [s, p]",
  "#! Outputs: [VALUE]",
  "proc live_caller",
  "    exec.registry::get_item",
  "end",
}
local const_caller = {
  "use {VALUE_SLOT} from fix::core::registry",
  "",
  "#! Invocation: exec",
  "#! Inputs:  []",
  "#! Outputs: [SLOT]",
  "proc const_caller",
  "    push.VALUE_SLOT",
  "end",
}
-- Baselines against the clean disk fixture -- analyzed for real (not
-- bailed), so nothing below can pass vacuously.
stack.clear_cache()
vres = analyze_virtual(live_caller)
check(
  "live callee: contract baseline is clean",
  vres ~= nil and vres.procs[1].bailed == nil and codes_of(vres) == "",
  vres and (tostring(vres.procs[1].bailed) .. " " .. codes_of(vres)) or "no result"
)
vres = analyze_virtual(const_caller)
check(
  "live callee: constant baseline is clean",
  vres ~= nil and vres.procs[1].bailed == nil and codes_of(vres) == "",
  vres and (tostring(vres.procs[1].bailed) .. " " .. codes_of(vres)) or "no result"
)

local prev_buf = vim.api.nvim_get_current_buf()
vim.cmd("edit! " .. reg_path)
local reg_buf = vim.api.nvim_get_current_buf()
local function reg_line_of(frag)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(reg_buf, 0, -1, false)) do
    if l:find(frag, 1, true) then
      return i
    end
  end
end
local live_ok, live_err = pcall(function()
  -- An unsaved edit that SHIFTS the declaration: the resolved (live) line
  -- must land on the live declaration, not miss on the disk line.
  vim.api.nvim_buf_set_lines(reg_buf, 0, 0, false, { "# live pad", "# live pad" })
  vres = analyze_virtual(live_caller)
  check(
    "live callee: shifted unsaved declaration still resolves",
    vres ~= nil and codes_of(vres) == "",
    codes_of(vres)
  )
  -- An unsaved edit to the CONTRACT: the caller analyzes against the live
  -- Outputs, exactly as a cold pass over saved files would.
  local outputs_lnum = assert(reg_line_of("#! Outputs: [VALUE]"))
  vim.api.nvim_buf_set_lines(
    reg_buf,
    outputs_lnum - 1,
    outputs_lnum,
    false,
    { "#! Outputs: [VALUE, extra]" }
  )
  vres = analyze_virtual(live_caller)
  check(
    "live callee: unsaved contract edit reaches the caller",
    vres ~= nil and codes_of(vres):find("exec%-net") ~= nil,
    codes_of(vres)
  )
  -- Completion summaries ride the same lookup: live line, live contract.
  local summary = stack.contract_summary(reg_path, assert(reg_line_of("pub proc get_item")))
  check(
    "live callee: completion summary reflects the live buffer",
    summary == "[slot_id_suffix, slot_id_prefix] -> [VALUE, extra]",
    tostring(summary)
  )
  -- Constants too: the live definition decides the pushed width.
  local slot_lnum = assert(reg_line_of("pub const VALUE_SLOT"))
  vim.api.nvim_buf_set_lines(
    reg_buf,
    slot_lnum - 1,
    slot_lnum,
    false,
    { "pub const VALUE_SLOT = 7" }
  )
  vres = analyze_virtual(const_caller)
  check(
    "live callee: unsaved constant edit reaches the caller",
    vres ~= nil and codes_of(vres):find("exec%-net") ~= nil,
    codes_of(vres)
  )
end)
vim.api.nvim_buf_call(reg_buf, function()
  vim.cmd("edit!") -- discard every unsaved fixture edit
end)
vim.api.nvim_set_current_buf(prev_buf)
check("live callee: block completed", live_ok, tostring(live_err))
-- Reverted: the next pass reads the clean disk contract again (the
-- changedtick-keyed entries cannot linger past the revert).
vres = analyze_virtual(live_caller)
check(
  "live callee: revert restores the clean baseline",
  vres ~= nil and codes_of(vres) == "",
  codes_of(vres)
)

---------------------------------------------------------------------------
-- engine: the lookup budget counts distinct targets, not raw calls
---------------------------------------------------------------------------

-- 400+ raw lookups of ONE constant are a single distinct target: the budget
-- must not exhaust, and the genuine depth-17 exit at the end of the file
-- must surface as an ERROR (under total counting it silently degraded to a
-- budget poison and a hidden hint).
local repeat_src = { "const REPEATED = 7", "" }
for p = 1, 40 do
  vim.list_extend(repeat_src, {
    "#! Invocation: call",
    "#! Inputs:  [pad(16)]",
    "#! Outputs: [pad(16)]",
    "proc repeats_" .. p,
  })
  for _ = 1, 10 do
    repeat_src[#repeat_src + 1] = "    push.REPEATED"
    repeat_src[#repeat_src + 1] = "    drop"
  end
  vim.list_extend(repeat_src, { "end", "" })
end
vim.list_extend(repeat_src, {
  "#! Invocation: call",
  "#! Inputs:  [pad(16)]",
  "#! Outputs: [pad(16)]",
  "proc deep_exit",
  "    push.REPEATED",
  "end",
})
stack.clear_cache()
vres = analyze_virtual(repeat_src)
local deep_diag = vres and vres.diagnostics[1]
check(
  "budget: repeated lookups of one target never exhaust it",
  vres ~= nil
    and #vres.diagnostics == 1
    and deep_diag.code == "exit-depth"
    and deep_diag.severity == "error"
    and deep_diag.lnum == #repeat_src,
  vres and vim.inspect(vres.diagnostics) or "no result"
)
-- Warm pass: the deps replay must reproduce the distinct-target accounting
-- (every proc hits the memo, the error stays, nothing new appears).
reset_memo_stats()
vres = analyze_virtual(repeat_src)
check(
  "budget: warm pass replays distinct accounting (all procs hit)",
  stack._memo_stats.misses == 0 and vres ~= nil and codes_of(vres) == "exit-depth",
  stack._memo_stats.hits .. "/" .. stack._memo_stats.misses .. " " .. codes_of(vres)
)

-- Exhaustion by genuinely DISTINCT targets still degrades gracefully, with
-- the stated budget reason -- never a guessed width.
local distinct_src = {}
for i = 1, 305 do
  distinct_src[#distinct_src + 1] = ("const C%d = %d"):format(i, i)
end
vim.list_extend(distinct_src, {
  "",
  "#! Invocation: exec",
  "#! Inputs:  []",
  "#! Outputs: []",
  "proc exhausts_budget",
})
for i = 1, 305 do
  distinct_src[#distinct_src + 1] = "    push.C" .. i
  distinct_src[#distinct_src + 1] = "    drop"
end
distinct_src[#distinct_src + 1] = "end"
stack.clear_cache()
vres = analyze_virtual(distinct_src)
local exhausted
for _, p in ipairs(vres and vres.procs or {}) do
  if p.name == "exhausts_budget" then
    exhausted = p
  end
end
check(
  "budget: distinct-target exhaustion poisons with the stated reason",
  exhausted ~= nil
    and exhausted.bailed == nil
    and exhausted.exit ~= nil
    and exhausted.exit.poisoned ~= nil
    and exhausted.exit.poisoned:find("budget exhausted", 1, true) ~= nil,
  exhausted and tostring(exhausted.exit and exhausted.exit.poisoned) or "no proc"
)
stack.clear_cache()

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

-- Invalid config fields degrade loudly to the defaults: publishing still
-- works (diagnostics = "yes" is not `false`), and each bad field notifies
-- by name (previously `overlay_mode = true` silently disabled the "auto"
-- gating and `debounce_ms = "300"` worked only through luv coercion).
local cfg_notified = {}
local saved_notify = vim.notify
-- Replacing the typed built-in is the point of the stub; restored below.
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg)
  cfg_notified[#cfg_notified + 1] = tostring(msg)
end
vim.g.masm_stack = { diagnostics = "yes", overlay_mode = true, debounce_ms = "300" }
stackview.refresh(bufnr)
vim.notify = saved_notify
vim.g.masm_stack = nil
check("view: invalid config falls back to publishing defaults", #published() == 9)
local cfg_mentions = { diagnostics = false, overlay_mode = false, debounce_ms = false }
for _, msg in ipairs(cfg_notified) do
  for field in pairs(cfg_mentions) do
    if msg:find("masm_stack." .. field, 1, true) then
      cfg_mentions[field] = true
    end
  end
end
check(
  "view: each invalid config field notifies by name",
  cfg_mentions.diagnostics and cfg_mentions.overlay_mode and cfg_mentions.debounce_ms,
  vim.inspect(cfg_notified)
)

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

-- Failure notices latch on the MESSAGE, not a boolean: a repeat of the same
-- failure stays quiet, but a DIFFERENT failure notifies even while an
-- earlier one is latched, and a change back re-arms the first.
local latch_notified = {}
local latch_saved_notify = vim.notify
-- Replacing the typed built-in is the point of the stub; restored below.
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg)
  latch_notified[#latch_notified + 1] = tostring(msg)
end
local latch_ok, latch_err = pcall(function()
  local function count(frag)
    local n = 0
    for _, m in ipairs(latch_notified) do
      if m:find(frag, 1, true) then
        n = n + 1
      end
    end
    return n
  end
  local lbuf = vim.api.nvim_create_buf(false, true) -- unnamed: analysis refuses
  stackview.attach(lbuf)
  stackview.refresh(lbuf)
  stackview.refresh(lbuf)
  check(
    "latch: repeated failure notifies once",
    count("unnamed buffer") == 1,
    vim.inspect(latch_notified)
  )
  -- A different failure (size cap fires before the name check) must not be
  -- swallowed by the latched one.
  vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, { string.rep("x", 3 * 1024 * 1024) })
  stackview.refresh(lbuf)
  check(
    "latch: a new, different failure still notifies",
    count("too large") == 1,
    vim.inspect(latch_notified)
  )
  -- ...and flipping back re-arms the first message. Replaced with real
  -- content, not `{}`: clearing a buffer to empty leaves
  -- nvim_buf_get_offset's total stale (a Neovim memline quirk), which
  -- would keep the size check tripping here.
  vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, { "# small again" })
  stackview.refresh(lbuf)
  check(
    "latch: reverting re-arms the earlier message",
    count("unnamed buffer") == 2,
    vim.inspect(latch_notified)
  )
  stackview.detach(lbuf)
  vim.api.nvim_buf_delete(lbuf, { force = true })
end)
vim.notify = latch_saved_notify
check("latch: block completed", latch_ok, tostring(latch_err))

-- The autocmd-driven pipeline end to end: a TextChanged firing must reach
-- publish() through the debounce timer (tests above call refresh() directly,
-- which would mask a broken schedule path).
vim.g.masm_stack = { debounce_ms = 30 }
stackview.attach(bufnr)
stackview.refresh(bufnr)
local baseline_count = #published()
vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "use miden::core::math::{rusty}" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
local debounced = vim.wait(3000, function()
  return #published() ~= baseline_count
end, 20)
local drift_after = false
for _, d in ipairs(published()) do
  if d.code == "unrecognized-import" then
    drift_after = true
  end
end
check("view: TextChanged autocmd re-publishes via the debounce", debounced and drift_after)
vim.g.masm_stack = nil
stackview.detach(bufnr)
vim.cmd("edit!")

-- Changedtick early-out: the debounced path must SKIP when nothing changed
-- since the last publish (InsertLeave without an edit), and must still run
-- after a real edit -- the early-out may never suppress a needed refresh.
vim.g.masm_stack = { debounce_ms = 30 }
stackview.attach(bufnr)
vim.wait(200, function()
  return false
end, 20) -- drain attach's own scheduled first refresh
stackview.refresh(bufnr)
reset_memo_stats()
vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr }) -- no actual edit
vim.wait(300, function()
  return false
end, 20) -- give the debounce timer time to fire (or correctly not refresh)
check(
  "view: no-edit debounce trigger skips analysis",
  stack._memo_stats.hits + stack._memo_stats.misses == 0,
  stack._memo_stats.hits .. "/" .. stack._memo_stats.misses
)
vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "use miden::core::math::{rusty}" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
local re_ran = vim.wait(3000, function()
  return stack._memo_stats.hits + stack._memo_stats.misses > 0
end, 20)
local drift_republished = false
for _, d in ipairs(published()) do
  if d.code == "unrecognized-import" then
    drift_republished = true
  end
end
check("view: real edit still refreshes through the early-out", re_ran and drift_republished)
vim.g.masm_stack = nil
stackview.detach(bufnr)
vim.cmd("edit!")

-- Early-out reentrancy: a user autocmd on DiagnosticChanged that EDITS the
-- buffer runs synchronously inside publish. The recorded tick must describe
-- the lines that were analyzed (captured with the buffer read), not the
-- autocmd's post-edit state -- or the early-out would treat the stale
-- publish as current and pin it until some unrelated edit.
vim.g.masm_stack = { debounce_ms = 30 }
stackview.attach(bufnr)
vim.wait(200, function()
  return false
end, 20) -- drain attach's own scheduled first refresh
local reentrant = vim.api.nvim_create_autocmd("DiagnosticChanged", {
  buffer = bufnr,
  once = true,
  callback = function()
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "use miden::core::math::{rusty}" })
  end,
})
stackview.refresh(bufnr) -- publish fires the autocmd; the edit lands mid-refresh
vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
local reentrant_seen = vim.wait(3000, function()
  for _, d in ipairs(published()) do
    if d.code == "unrecognized-import" then
      return true
    end
  end
  return false
end, 20)
check("view: mid-publish edit is not swallowed by the early-out", reentrant_seen)
pcall(vim.api.nvim_del_autocmd, reentrant) -- once=true already removed it on the happy path
vim.g.masm_stack = nil
stackview.detach(bufnr)
vim.cmd("edit!")

-- MAX_BUF_BYTES gate: an oversized buffer is refused BEFORE the analyzer
-- runs (memo counters stay untouched), without an error and with nothing
-- published. The buffer needs no name -- the size gate fires first.
local big_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(big_buf, 0, -1, false, { string.rep("#", 2 * 1024 * 1024 + 1) })
stackview.attach(big_buf)
reset_memo_stats()
local big_ok, big_err = pcall(stackview.refresh, big_buf)
check("view: oversized buffer refresh does not error", big_ok, tostring(big_err))
check(
  "view: oversized buffer skips analysis entirely",
  stack._memo_stats.hits + stack._memo_stats.misses == 0,
  stack._memo_stats.hits .. "/" .. stack._memo_stats.misses
)
check(
  "view: oversized buffer publishes nothing",
  #vim.diagnostic.get(big_buf, { namespace = stackview._diag_ns }) == 0
)
stackview.detach(big_buf)
vim.api.nvim_buf_delete(big_buf, { force = true })

-- Empty (single-empty-line) buffer: the smallest buffer Neovim can hold
-- must refresh without error and publish nothing.
local empty_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(empty_buf, here .. "/fixtures/app/empty_virtual.masm")
stackview.attach(empty_buf)
local empty_ok, empty_err = pcall(stackview.refresh, empty_buf)
check("view: empty buffer refresh does not error", empty_ok, tostring(empty_err))
check(
  "view: empty buffer publishes nothing",
  #vim.diagnostic.get(empty_buf, { namespace = stackview._diag_ns }) == 0
)
stackview.detach(empty_buf)
vim.api.nvim_buf_delete(empty_buf, { force = true })

---------------------------------------------------------------------------
-- stackview: project-wide inaccurate-comment quickfix
---------------------------------------------------------------------------

local project = require("masm.project")
local real_build_index = project.build_index
local comments_notified = {}
local comments_saved_notify = vim.notify
local comment_bufs = {}
local comments_scanner = require("masm.scan")
local comments_saved_slice = comments_scanner._slice_ms
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg)
  comments_notified[#comments_notified + 1] = tostring(msg)
end

local comments_ok, comments_err = pcall(function()
  local function scratch(name, lines)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, here .. "/fixtures/app/" .. name)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    comment_bufs[#comment_bufs + 1] = b
    return b, vim.api.nvim_buf_get_name(b)
  end

  local reordered_buf, reordered_path = scratch("a_reordered_virtual.masm", {
    "#! Invocation: call",
    "#! Inputs:  [b, a, pad(14)]",
    "#! Outputs: [a, b, pad(14)]",
    "proc reordered",
    "    swap",
    "    # => [b, a, pad(14)]",
    "end",
  })
  local stale_buf, stale_path = scratch("z_stale_virtual.masm", {
    "#! Invocation: call",
    "#! Inputs:  [pad(16)]",
    "#! Outputs: [pad(16)]",
    "proc stale",
    "    push.1",
    "    # => [pad(16)]",
    "    drop",
    "end",
  })
  local missing_path = here .. "/fixtures/app/missing_virtual.masm"
  local indexed = { stale_path, missing_path, reordered_path } -- deliberately unsorted
  project.build_index = function()
    return { masm = indexed }
  end

  local function run_comments()
    vim.cmd("silent! cclose")
    vim.api.nvim_set_current_buf(bufnr)
    return stackview.comments({ sync = true })
  end

  -- Explicit project scans ignore the ambient-diagnostic display gate.
  vim.g.masm_stack = { check_comments = false }
  local comment_items = run_comments()
  vim.g.masm_stack = nil
  check(
    "comments: both inaccurate-comment codes collected project-wide",
    comment_items ~= nil
      and #comment_items == 2
      and comment_items[1].text:find("[comment-reordered]", 1, true) ~= nil
      and comment_items[2].text:find("[comment-stale]", 1, true) ~= nil,
    vim.inspect(comment_items)
  )
  check(
    "comments: findings sorted by file despite index order",
    comment_items ~= nil
      and comment_items[1].filename == reordered_path
      and comment_items[2].filename == stale_path,
    vim.inspect(comment_items)
  )
  local qf = vim.fn.getqflist({ title = 1, items = 1 })
  check(
    "comments: quickfix title and warning entries published",
    qf.title == "MASM inaccurate stack comments"
      and #qf.items == 2
      and qf.items[1].type == "W"
      and qf.items[2].type == "W",
    vim.inspect(qf)
  )
  local partial_notice = false
  for _, msg in ipairs(comments_notified) do
    partial_notice = partial_notice or msg:find("results are partial", 1, true) ~= nil
  end
  check("comments: unreadable indexed files reported as partial", partial_notice)

  -- The user-facing default must yield instead of blocking on a whole
  -- project. A tiny slice makes that observable on this small fixture.
  comments_scanner._slice_ms = 0.05
  vim.cmd("silent! cclose")
  vim.api.nvim_set_current_buf(bufnr)
  vim.fn.setqflist({}, " ", { title = "comments sentinel", items = {} })
  local async_items = stackview.comments()
  check(
    "comments: default scan returns before replacing quickfix",
    async_items == nil and vim.fn.getqflist({ title = 1 }).title == "comments sentinel"
  )
  local async_landed = vim.wait(5000, function()
    return vim.fn.getqflist({ title = 1 }).title ~= "comments sentinel"
  end, 5)
  check("comments: asynchronous scan eventually publishes", async_landed)
  comments_scanner._slice_ms = comments_saved_slice

  -- Correct the loaded, unsaved buffers. A disk-only scan would either keep
  -- the findings or fail (these virtual paths do not exist).
  vim.api.nvim_buf_set_lines(reordered_buf, 5, 6, false, { "    # => [a, b, pad(14)]" })
  vim.api.nvim_buf_set_lines(stale_buf, 5, 6, false, { "    # => [1, pad(16)]" })
  indexed = { stale_path, reordered_path }
  comments_notified = {}
  local empty_items = run_comments()
  qf = vim.fn.getqflist({ title = 1, items = 1 })
  local accurate_notice = false
  for _, msg in ipairs(comments_notified) do
    accurate_notice = accurate_notice
      or msg:find("all indexed stack comments are accurate", 1, true) ~= nil
  end
  check("comments: live unsaved corrections win over disk", empty_items == nil)
  check(
    "comments: zero findings clear stale quickfix results",
    qf.title == "MASM inaccurate stack comments" and #qf.items == 0,
    vim.inspect(qf)
  )
  check("comments: zero findings notify success", accurate_notice)
end)

vim.cmd("silent! cclose")
project.build_index = real_build_index
vim.notify = comments_saved_notify
vim.g.masm_stack = nil
comments_scanner._slice_ms = comments_saved_slice
for _, b in ipairs(comment_bufs) do
  if vim.api.nvim_buf_is_valid(b) then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end
check("comments: block completed", comments_ok, tostring(comments_err))

---------------------------------------------------------------------------

helpers.finish()
