-- Hand-maintained instruction reference entries for mnemonics the generated
-- masm-lsp snapshot (instructions.lua) does not carry but the hand-audited
-- arity table (arity.lua) simulates: without these, hover and completion
-- silently knew nothing about instructions the stack analyzer understands.
-- Same shape as instructions.lua ({ name, description, stack effect });
-- instructions.lua appends this list at load time, and the generator emits
-- that merge, so regeneration cannot lose these entries.
-- tests/consistency_test.lua enforces the "everything simulated is also
-- documented and highlighted" invariant that caught the original gap.

-- stylua: ignore
return {
  { "eqz", "b = 1, if a = 0, and 0 otherwise.", "(a, ...) → (a = 0, ...)" },
  { "nop", "Does nothing (advances the VM one cycle).", "(...) → (...)" },
  { "breakpoint", "Breaks into the debugger when executed under one; a no-op otherwise.", "(...) → (...)" },
  { "adv_pushw", "Pops a word from the advice stack and pushes it onto the operand stack.", "(...) → (A, ...)" },
  { "reversew", "Reverses the order of the top 4 stack elements.", "(d, c, b, a, ...) → (a, b, c, d, ...)" },
  { "reversedw", "Reverses the order of the top 8 stack elements.", "(h, .., a, ...) → (a, .., h, ...)" },
  { "mem_loadw", "A ← mem[a..a+3] (word). Pre-byte-order form of mem_loadw_be/_le. Overwrites top 4 stack elements. If a on stack, it's popped.", "(a, A, ...) → (mem[a..a+3], ...)" },
  { "mem_loadw.{n}", "A ← mem[{n}..{n+3}] (word). Pre-byte-order form of mem_loadw_be/_le. Overwrites top 4 stack elements.", "(A, ...) → (mem[{n}..{n+3}], ...)" },
  { "mem_storew", "mem[a..a+3] ← A. Pre-byte-order form of mem_storew_be/_le. If a on stack, it's popped.", "(a, A, ...) → (A, ...)" },
  { "mem_storew.{n}", "mem[{n}..{n+3}] ← A. Pre-byte-order form of mem_storew_be/_le.", "(A, ...) → (A, ...)" },
  { "loc_loadw.{n}", "B ← local[{n}..{n+3}]. Pre-byte-order form of loc_loadw_be/_le. Overwrites top 4 stack elements.", "(A, ...) → (B, ...)" },
  { "loc_storew.{n}", "local[{n}..{n+3}] ← A. Pre-byte-order form of loc_storew_be/_le.", "(A, ...) → (A, ...)" },
  { "u32widening_add", "c = (a + b) mod 2^32, d = 1 if (a + b) ≥ 2^32, and 0 otherwise (the carry). Current-dialect name of u32overflowing_add.", "(b, a, ...) → (carry, (a + b) mod 2^32, ...)" },
  { "u32widening_add.{n}", "c = (a + {n}) mod 2^32, d = 1 if (a + {n}) ≥ 2^32, and 0 otherwise (the carry).", "(a, ...) → (carry, (a + {n}) mod 2^32, ...)" },
  { "u32widening_add3", "d = (a+b+c) mod 2^32, e = ⌊(a+b+c) / 2^32⌋. Current-dialect name of u32overflowing_add3.", "(c, b, a, ...) → (⌊(a+b+c) / 2^32⌋, (a+b+c) mod 2^32, ...)" },
  { "u32widening_mul", "c = (a * b) mod 2^32, d = ⌊(a * b) / 2^32⌋ (the high limb). Current-dialect name of u32overflowing_mul.", "(b, a, ...) → (⌊(a * b) / 2^32⌋, (a * b) mod 2^32, ...)" },
  { "u32widening_mul.{n}", "c = (a * {n}) mod 2^32, d = ⌊(a * {n}) / 2^32⌋ (the high limb).", "(a, ...) → (⌊(a * {n}) / 2^32⌋, (a * {n}) mod 2^32, ...)" },
  { "u32widening_madd", "d = (a * b + c) mod 2^32, e = ⌊(a * b + c) / 2^32⌋. Current-dialect name of u32overflowing_madd.", "(b, a, c, ...) → (⌊(a * b + c) / 2^32⌋, (a * b + c) mod 2^32, ...)" },
}
