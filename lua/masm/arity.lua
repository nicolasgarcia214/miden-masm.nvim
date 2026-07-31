-- Hand-audited operand-stack arities for Miden Assembly instructions.
--
-- This table is written by hand, NOT generated from the prose stack-effect
-- strings in instructions.lua: those strings carry known arity errors (e.g.
-- `mem_load.{n}` shown as popping an address it does not pop) and cannot
-- express counts for `movup.n`/`pad`-relative effects. Each entry below was
-- checked against the official Miden Assembly instruction reference
-- (0xmiden.github.io/miden-vm, assembler 0.24 mnemonic set).
--
-- Omissions are deliberate policy, not oversight: the simulator must BAIL on
-- an unknown mnemonic rather than guess (a guessed arity produces a wrong
-- diagnostic). Rare STARK/kernel-only ops (fri_ext2fold4, horner_eval_*,
-- eval_circuit, crypto_stream, log_precompile) are omitted for that reason.
--
-- Shapes:
--   ops[name] = { bare = {pops, pushes}, imm = {pops, pushes}, expr = "..." }
--     `bare` applies when the instruction has no immediate, `imm` when it has
--     one (`add.5`, `mem_load.400`). An instruction used with an immediate
--     but lacking `imm` here (or vice versa) is unknown -> bail. `expr`, when
--     present, names the pushed result from the popped operand names
--     ({a} = first popped / top of stack, {b} = second).
--   special[name] = true
--     Positional/structural ops the simulator implements directly (they
--     permute or copy cells; a pops/pushes pair cannot describe them).
--
-- The `.err=`/`.err="..."` suffix on assertions is an error annotation, not
-- an immediate; masm.stack strips it before lookup. `exp.uN` is an
-- exponent-bit-length hint, not a literal exponent; masm.stack maps it to
-- `bare` arity.

local M = {}

---@class masm.ArityEntry stack effect of one mnemonic (see the header)
---@field bare {[1]: integer, [2]: integer|'"n"'}? {pops, pushes} without an
---   immediate; "n" pushes take the count from the immediate
---@field imm {[1]: integer, [2]: integer|'"n"'}? {pops, pushes} with one
---@field expr string? pushed-result name template ({a} = top popped operand,
---   {b} = second)

---@type table<string, masm.ArityEntry>
M.ops = {
  -- Field arithmetic ------------------------------------------------------
  add = { bare = { 2, 1 }, imm = { 1, 1 }, expr = "{b} + {a}" },
  sub = { bare = { 2, 1 }, imm = { 1, 1 }, expr = "{b} - {a}" },
  mul = { bare = { 2, 1 }, imm = { 1, 1 }, expr = "{b} * {a}" },
  div = { bare = { 2, 1 }, imm = { 1, 1 } },
  neg = { bare = { 1, 1 }, expr = "-{a}" },
  inv = { bare = { 1, 1 } },
  pow2 = { bare = { 1, 1 } },
  exp = { bare = { 2, 1 }, imm = { 1, 1 } },
  ilog2 = { bare = { 1, 1 } },
  is_odd = { bare = { 1, 1 } },
  ["not"] = { bare = { 1, 1 }, expr = "!{a}" }, -- Lua keyword, hence brackets
  ["and"] = { bare = { 2, 1 } },
  ["or"] = { bare = { 2, 1 } },
  xor = { bare = { 2, 1 } },
  -- Comparisons -----------------------------------------------------------
  eq = { bare = { 2, 1 }, imm = { 1, 1 } },
  neq = { bare = { 2, 1 }, imm = { 1, 1 } },
  lt = { bare = { 2, 1 }, imm = { 1, 1 } },
  lte = { bare = { 2, 1 }, imm = { 1, 1 } },
  gt = { bare = { 2, 1 }, imm = { 1, 1 } },
  gte = { bare = { 2, 1 }, imm = { 1, 1 } },
  eqz = { bare = { 1, 1 } },
  eqw = { bare = { 8, 9 } }, -- pushes the flag above both preserved words
  -- Quadratic extension field --------------------------------------------
  ext2add = { bare = { 4, 2 } },
  ext2sub = { bare = { 4, 2 } },
  ext2mul = { bare = { 4, 2 } },
  ext2div = { bare = { 4, 2 } },
  ext2neg = { bare = { 2, 2 } },
  ext2inv = { bare = { 2, 2 } },
  -- Assertions (`.err=` suffix stripped before lookup) --------------------
  assert = { bare = { 1, 0 } },
  assertz = { bare = { 1, 0 } },
  assert_eq = { bare = { 2, 0 } },
  assert_eqw = { bare = { 8, 0 } },
  -- u32 conversions / tests ----------------------------------------------
  u32cast = { bare = { 1, 1 } },
  u32split = { bare = { 1, 2 } },
  u32test = { bare = { 1, 2 } },
  u32testw = { bare = { 4, 5 } },
  u32assert = { bare = { 1, 1 } },
  u32assert2 = { bare = { 2, 2 } },
  u32assertw = { bare = { 4, 4 } },
  -- u32 arithmetic --------------------------------------------------------
  u32overflowing_add = { bare = { 2, 2 }, imm = { 1, 2 } },
  u32wrapping_add = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32overflowing_sub = { bare = { 2, 2 }, imm = { 1, 2 } },
  u32wrapping_sub = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32overflowing_add3 = { bare = { 3, 2 } },
  u32wrapping_add3 = { bare = { 3, 1 } },
  u32widening_add = { bare = { 2, 2 }, imm = { 1, 2 } },
  u32widening_add3 = { bare = { 3, 2 } },
  u32widening_mul = { bare = { 2, 2 }, imm = { 1, 2 } },
  u32wrapping_mul = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32widening_madd = { bare = { 3, 2 } },
  u32wrapping_madd = { bare = { 3, 1 } },
  u32div = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32mod = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32divmod = { bare = { 2, 2 }, imm = { 1, 2 } },
  -- u32 bitwise -----------------------------------------------------------
  u32and = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32or = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32xor = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32not = { bare = { 1, 1 } },
  u32shl = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32shr = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32rotl = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32rotr = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32popcnt = { bare = { 1, 1 } },
  u32clz = { bare = { 1, 1 } },
  u32ctz = { bare = { 1, 1 } },
  u32clo = { bare = { 1, 1 } },
  u32cto = { bare = { 1, 1 } },
  -- u32 comparisons -------------------------------------------------------
  u32lt = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32lte = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32gt = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32gte = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32min = { bare = { 2, 1 }, imm = { 1, 1 } },
  u32max = { bare = { 2, 1 }, imm = { 1, 1 } },
  -- Conditional selection (top is the condition; result order is
  -- data-dependent, so cells come back anonymous) -------------------------
  cswap = { bare = { 3, 2 } },
  cswapw = { bare = { 9, 8 } },
  cdrop = { bare = { 3, 1 } },
  cdropw = { bare = { 9, 4 } },
  -- Simple stack ops (positional ones are in `special`) -------------------
  drop = { bare = { 1, 0 } },
  dropw = { bare = { 4, 0 } },
  padw = { bare = { 0, 4 } },
  -- Advice provider -------------------------------------------------------
  -- The dialect in current corpora uses bare `adv_push` (one felt);
  -- `adv_push.n` reads n felts.
  adv_push = { bare = { 0, 1 }, imm = { 0, "n" } },
  adv_pushw = { bare = { 0, 4 } },
  adv_loadw = { bare = { 4, 4 } },
  adv_pipe = { bare = { 13, 13 } }, -- [C, B, A, a] words overwritten in place
  -- Memory ----------------------------------------------------------------
  mem_load = { bare = { 1, 1 }, imm = { 0, 1 } },
  mem_store = { bare = { 2, 0 }, imm = { 1, 0 } },
  mem_loadw = { bare = { 5, 4 }, imm = { 4, 4 } },
  mem_storew = { bare = { 5, 4 }, imm = { 4, 4 } },
  mem_loadw_be = { bare = { 5, 4 }, imm = { 4, 4 } },
  mem_loadw_le = { bare = { 5, 4 }, imm = { 4, 4 } },
  mem_storew_be = { bare = { 5, 4 }, imm = { 4, 4 } },
  mem_storew_le = { bare = { 5, 4 }, imm = { 4, 4 } },
  mem_stream = { bare = { 13, 13 } },
  -- Procedure locals (always immediate-indexed) ---------------------------
  loc_load = { imm = { 0, 1 } },
  loc_store = { imm = { 1, 0 } },
  loc_loadw = { imm = { 4, 4 } },
  loc_storew = { imm = { 4, 4 } },
  loc_loadw_be = { imm = { 4, 4 } },
  loc_loadw_le = { imm = { 4, 4 } },
  loc_storew_be = { imm = { 4, 4 } },
  loc_storew_le = { imm = { 4, 4 } },
  locaddr = { imm = { 0, 1 } },
  -- Environment -----------------------------------------------------------
  sdepth = { bare = { 0, 1 } },
  clk = { bare = { 0, 1 } },
  caller = { bare = { 4, 4 } },
  -- Cryptographic ---------------------------------------------------------
  hash = { bare = { 4, 4 } },
  hperm = { bare = { 12, 12 } },
  hmerge = { bare = { 8, 4 } },
  mtree_get = { bare = { 6, 8 } }, -- [d, i, R] -> [V, R]
  mtree_set = { bare = { 10, 8 } }, -- [d, i, R, V'] -> [V, R']
  mtree_merge = { bare = { 8, 4 } },
  mtree_verify = { bare = { 10, 10 } }, -- [V, d, i, R] left intact
  -- No-ops / decorators. `debug.*`, `trace.*` and `adv.*` are intercepted
  -- by masm.stack (their dotted suffixes are subcommands, not immediates,
  -- and have no entries here); `emit` is table-driven on purpose -- this
  -- entry is its single source of truth for both the bare and the
  -- `.event_id` form (masm.stack deliberately does not intercept it) ------
  nop = { bare = { 0, 0 } },
  breakpoint = { bare = { 0, 0 } },
  emit = { bare = { 0, 0 }, imm = { 0, 0 } },
}

-- Positional/copy ops the simulator implements cell-by-cell. `swap`, `dup`
-- and `dupw` accept an optional index immediate; the rest of the indexed
-- ones require it. All are net 0 except dup/dupw (+1/+4).
---@type table<string, true>
M.special = {
  swap = true,
  swapw = true,
  swapdw = true,
  movup = true,
  movdn = true,
  movupw = true,
  movdnw = true,
  dup = true,
  dupw = true,
  reversew = true,
  reversedw = true,
}

return M
