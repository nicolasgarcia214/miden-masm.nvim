-- Static operand-stack simulator for Miden Assembly.
--
-- The assembler performs no stack-depth checking; the only enforcement is the
-- VM's runtime `InvalidStackDepthOnReturn` when a call/syscall/dyncall-invoked
-- procedure returns at a depth other than 16. This module simulates the stack
-- per instruction so those bugs surface in the editor instead.
--
-- Design constraints that shape the code:
--  * One cell per felt, always. Positional ops (`movup.n`, `swapw.n`, ...)
--    address felt positions, so felt-granular cells make them literal index
--    shuffles; word/pad grouping is display metadata, not structure.
--  * Cells are immutable: every transfer builds a new cells array (and new
--    cell tables when renaming), so recorded per-line snapshots stay valid
--    and branch simulation can share unchanged cells.
--  * Two evaluation modes, chosen by the `#! Invocation:` doc tag (or a
--    script attribute): call/syscall/dyncall procs enter at exactly 16 with
--    the VM's zero-fill floor modeled ("floored"); exec/dynexec procs enter
--    at their declared Inputs width and anything popped beyond it is drawn
--    from the caller ("relative", the masm-padding "Danger Zone").
--  * Never guess. Unknown mnemonics bail the whole procedure with a reason;
--    unresolvable data (callee contracts, constants) poisons the state until
--    the next parseable `# => [...]` tracker, which doubles as a recovery
--    point. Procedures without an invocation mode are skipped entirely --
--    that is the false-positive firewall for kernel-style code.
--  * Handwritten trackers are checked by WIDTH only; names are display
--    material (they carry primes, rebindings and synonyms in the wild) and
--    are adopted into the simulation when widths agree.

local notation = require("masm.stacknotation")
local arity = require("masm.arity")

local M = {}

-- Per-procedure simulated-instruction budget (repeat unrolling included).
-- Real procedures are 5-50 instructions; the cap only exists so a
-- pathological `repeat.32` nest cannot stall the UI thread.
local MAX_SIM_OPS = 10000
-- Distinct cross-file callee/constant lookups per analyze() pass. Lookups
-- hit goto's mtime-keyed caches after the first pass; the cap bounds the
-- cold-start worst case. Beyond it, affected procs poison with a reason.
local MAX_LOOKUPS = 300
-- Visible cells tracked per state; deeper stacks are legal but not useful
-- to model (nothing in real code addresses that deep).
local MAX_CELLS = 64

-- Script attributes that imply the 16-in/16-out dyncall ABI when no
-- explicit `#! Invocation:` tag is present.
local SCRIPT_ATTRS = {
  ["@note_script"] = true,
  ["@auth_script"] = true,
  ["@transaction_script"] = true,
}

local FLOORED_INVOCATIONS = { call = true, dyncall = true, syscall = true }
local RELATIVE_INVOCATIONS = { exec = true, dynexec = true }

---------------------------------------------------------------------------
-- Cells and states
---------------------------------------------------------------------------

local function anon_cells(n, origin)
  local out = {}
  for _ = 1, n do
    out[#out + 1] = { origin = origin or "unknown" }
  end
  return out
end

local function zero_cells(n)
  local group = { kind = "pad", name = "pad", width = n }
  local out = {}
  for _ = 1, n do
    out[#out + 1] = { name = "0", origin = "zerofill", group = group }
  end
  return out
end

-- state.cells: top-first array. state.mode: "floored"|"relative".
-- state.consumed: felts drawn from beneath the declared inputs (relative).
-- state.poisoned: reason string when the suffix is unknowable.
-- state.bottom: this path diverges (provably-failing assertion).
-- state.renormalized: a call/dyncall/syscall ran on this path.
-- state.floor_debt: zeros the 16-floor has pulled in so far (floored mode).
local function new_state(mode, cells)
  return {
    cells = cells,
    mode = mode,
    consumed = 0,
    poisoned = nil,
    bottom = false,
    renormalized = false,
    floor_debt = 0,
  }
end

-- Field-agnostic on purpose (like assign_state below): adding a state field
-- must not require touching every copy site.
local function copy_state(state)
  local copy = {}
  for k, v in pairs(state) do
    copy[k] = v
  end
  local cells = {}
  for i, c in ipairs(state.cells) do
    cells[i] = c
  end
  copy.cells = cells
  return copy
end

-- Guarantees at least n cells, drawing from the zero-fill floor (floored
-- mode) or the caller's stack (relative mode; the draw is counted for the
-- caller-underflow check).
local function ensure_cells(state, n, ctx, lnum)
  local have = #state.cells
  if have >= n then
    return
  end
  local need = n - have
  if state.mode == "floored" then
    -- The VM pulls zeros in from below; depth never drops under 16.
    for _, c in ipairs(zero_cells(need)) do
      state.cells[#state.cells + 1] = c
    end
  else
    for _, c in ipairs(anon_cells(need, "caller")) do
      state.cells[#state.cells + 1] = c
    end
    if state.consumed == 0 and ctx then
      ctx.first_draw_lnum = ctx.first_draw_lnum or lnum
    end
    state.consumed = state.consumed + need
  end
end

-- Restores the 16-element floor after pops (floored mode only), remembering
-- how many zeros were ever pulled in (`floor_debt`). Corpus authors
-- frequently keep counting the un-pulled view in their trackers, so a claim
-- of `sim - debt` elements is the same stack seen through that convention,
-- not a stale comment.
local function refloor(state)
  if state.mode == "floored" and #state.cells < 16 then
    local need = 16 - #state.cells
    for _, c in ipairs(zero_cells(need)) do
      state.cells[#state.cells + 1] = c
    end
    state.floor_debt = state.floor_debt + need
  end
end

-- Pops WITHOUT restoring the 16-floor: an instruction's stack transition is
-- atomic (net effect first, floor after), so `add` at depth 16 lands at 16,
-- not 17, and a net-0 exec splice at depth 16 stays at 16. Callers refloor
-- once per instruction, after pushes.
local function pop_cells(state, n, ctx, lnum)
  ensure_cells(state, n, ctx, lnum)
  local popped = {}
  for i = 1, n do
    popped[i] = table.remove(state.cells, 1)
  end
  return popped
end

local function push_cells(state, cells)
  for i = #cells, 1, -1 do
    table.insert(state.cells, 1, cells[i])
  end
  if #state.cells > MAX_CELLS then
    for i = #state.cells, MAX_CELLS + 1, -1 do
      state.cells[i] = nil
    end
    state.poisoned = state.poisoned or "stack deeper than the tracked window"
  end
end

local function poison(state, reason)
  state.poisoned = state.poisoned or reason
end

---------------------------------------------------------------------------
-- Diagnostics
---------------------------------------------------------------------------

local function diag(ctx, lnum, severity, code, message)
  ctx.proc.diagnostics[#ctx.proc.diagnostics + 1] =
    { lnum = lnum, col = 0, severity = severity, code = code, message = message }
end

---------------------------------------------------------------------------
-- Segmentation: procs, doc blocks, contracts
---------------------------------------------------------------------------

local BLOCK_OPENERS = { ["if.true"] = true, ["if.false"] = true, ["while.true"] = true }

local function opens_block(tok)
  return BLOCK_OPENERS[tok] or tok:match("^repeat%.") ~= nil
end

-- Collects the `#!` doc block and `@` attributes directly above `lnum`.
-- Plain `#` comments may sit between the doc block and the declaration
-- (e.g. a `# TODO` note in the protocol corpus); they are skipped, not
-- treated as ending the block.
local function doc_block_above(lines, lnum)
  local attrs, first = {}, lnum
  local i = lnum - 1
  while i >= 1 do
    local l = lines[i]
    if l:match("^%s*@") then
      attrs[#attrs + 1] = l:match("^%s*(@[%w_]+)")
    elseif l:match("^%s*#!") or not l:match("^%s*#") then
      break
    end
    i = i - 1
  end
  local doc_end = i
  while i >= 1 and lines[i]:match("^%s*#!") do
    first = i
    i = i - 1
  end
  local doc = {}
  for j = first, doc_end do
    doc[#doc + 1] = lines[j]
  end
  return doc, attrs, first
end

-- Scans a file's lines for proc declarations and their doc contracts.
-- Shared between the current buffer and callee files (contract cache).
-- Returns { by_lnum = { [decl_lnum] = proc } , list = { proc... } } where
-- proc = { name, lnum, end_lnum, doc_lnum, contract, attrs, invocation }.
local function scan_procs(lines, code_only)
  local by_lnum, list = {}, {}
  local i = 1
  while i <= #lines do
    local code = code_only(lines[i])
    local decl = code:match("^%s*pub%s+proc%f[^%w_]") or code:match("^%s*proc%f[^%w_]")
    local is_begin = code:match("^%s*begin%f[^%w_]") ~= nil
    if decl or is_begin then
      local name = decl and code:match("proc%s+([%w_%$]+)") or "begin"
      local doc, attrs, doc_lnum = doc_block_above(lines, i)
      -- A typed signature may wrap over several lines; the body starts
      -- after its parentheses balance.
      local body_first = i + 1
      if decl and code:find("%(") then
        local function paren_delta(s)
          local d = 0
          for ch in s:gmatch("[()]") do
            d = d + (ch == "(" and 1 or -1)
          end
          return d
        end
        local bal = paren_delta(code)
        while bal > 0 and body_first <= #lines do
          bal = bal + paren_delta(code_only(lines[body_first]))
          body_first = body_first + 1
        end
      end
      -- Body tokens may legally share the declaration line (`proc foo
      -- push.1 drop end`). They MUST take part in `end` matching -- skipping
      -- them once let a one-line proc steal the next procedure's `end`,
      -- mis-attributing every following body range. Events stay line-based,
      -- so such procs are not simulated either: analyze_proc bails on
      -- `same_line_body` with a stated reason instead of silently reading an
      -- empty body.
      local rest, rest_lnum
      if is_begin then
        rest = code:match("^%s*begin%f[^%w_](.*)$")
        rest_lnum = i
      elseif not code:find("%(") then
        rest = code:match("^%s*pub%s+proc%s+[%w_%$]+(.*)$")
          or code:match("^%s*proc%s+[%w_%$]+(.*)$")
        rest_lnum = i
      else
        -- Typed signature: the remainder follows the last `)` of the line
        -- where the parens balanced (body_first - 1; equals `i` when they
        -- balance on the declaration line itself).
        rest_lnum = body_first - 1
        local closed = rest_lnum == i and code or code_only(lines[rest_lnum])
        rest = closed:match(".*%)(.*)$")
      end
      if rest and rest:match("^%s*%->") then
        rest = "" -- a return-type annotation, not body tokens
      end

      -- Find the matching `end`, counting nested blocks. The declaration
      -- (or signature-closing) line's remainder is scanned first.
      local depth, end_lnum = 1, nil
      local same_line_body = false
      if rest then
        for tok in rest:gmatch("%S+") do
          same_line_body = true
          if opens_block(tok) then
            depth = depth + 1
          elseif tok == "end" then
            depth = depth - 1
            if depth == 0 then
              end_lnum = rest_lnum
              break
            end
          end
        end
      end
      local j = body_first
      while not end_lnum and j <= #lines do
        for tok in code_only(lines[j]):gmatch("%S+") do
          if opens_block(tok) then
            depth = depth + 1
          elseif tok == "end" then
            depth = depth - 1
            if depth == 0 then
              end_lnum = j
              break
            end
          end
        end
        if end_lnum then
          break
        end
        j = j + 1
      end
      local contract = notation.contract(doc)
      -- `begin..end` is the program entrypoint: it always runs on the
      -- 16-element physical stack, whatever the doc block says.
      local invocation = is_begin and "entrypoint" or contract.invocation
      local inferred = false
      if not invocation then
        for _, a in ipairs(attrs) do
          if SCRIPT_ATTRS[a] then
            -- Scripts run under the 16/16 dyncall ABI, but only some script
            -- files document the padded stack; others annotate relative to
            -- their meaningful arguments. Infer the floored mode only when
            -- the doc follows the padded convention, else stay out.
            if
              contract.inputs
              and not contract.inputs.lower_bound
              and contract.inputs.width == 16
            then
              invocation = "dyncall"
              inferred = true
            else
              invocation = nil
            end
          end
        end
      end
      local proc = {
        name = name,
        lnum = i,
        body_lnum = body_first,
        same_line_body = same_line_body,
        end_lnum = end_lnum,
        doc_lnum = doc_lnum,
        contract = contract,
        attrs = attrs,
        invocation = invocation,
        inferred_invocation = inferred,
        diagnostics = {},
        states = {},
      }
      -- Entrypoints are analyzed (they are in `list`) but can never be a
      -- callee, so only proc declarations enter the by-line contract map.
      if decl then
        by_lnum[i] = proc
      end
      list[#list + 1] = proc
      i = (end_lnum or #lines) + 1
    else
      i = i + 1
    end
  end
  return { by_lnum = by_lnum, list = list }
end

---------------------------------------------------------------------------
-- Contract cache for callee files
---------------------------------------------------------------------------

local contract_cache = {}
local lines_cache = {}

function M.clear_cache()
  contract_cache = {}
  lines_cache = {}
end

local function goto_mod()
  return require("masm.goto")
end

-- Scanned procs (declarations + doc contracts) of an on-disk file, cached
-- under its freshness key.
local function file_procs(path)
  local g = goto_mod()
  local key = g._stat_key(path)
  if not key then
    return nil, "cannot stat " .. path
  end
  local hit = contract_cache[path]
  if hit and hit.key == key then
    return hit.procs
  end
  local text = g._read_file(path)
  if not text then
    return nil, "cannot read " .. path
  end
  local lines = vim.split(text, "\n", { plain = true })
  local procs = scan_procs(lines, g._code_only)
  contract_cache[path] = { key = key, procs = procs }
  return procs
end

-- Contracts for a file, keyed by declaration line. The current buffer's
-- contracts come from the caller's own scan (unsaved edits must win).
local function contracts_for_file(ctx, path)
  if path == ctx.bufpath then
    return ctx.local_procs
  end
  return file_procs(path)
end

-- Compact `[inputs] -> [outputs]` summary of the procedure declared at
-- `path`:`lnum`, in the author's own notation, or nil when the file has no
-- parseable contract there. Cache-backed; used by masm.complete menus.
function M.contract_summary(path, lnum)
  local procs = file_procs(path)
  local proc = procs and procs.by_lnum[lnum]
  local c = proc and proc.contract
  if not c or (not c.inputs_raw and not c.outputs_raw) then
    return nil
  end
  return (c.inputs_raw or "[?]") .. " -> " .. (c.outputs_raw or "[?]")
end

-- Same summaries for the (possibly unsaved) current buffer: one scan of
-- `lines`, returning name -> { lnum, summary }. Not cached -- completion
-- calls are user-paced and a scan of a real file is well under a
-- millisecond.
function M.buffer_proc_summaries(lines)
  local procs = scan_procs(lines, goto_mod()._code_only)
  local out = {}
  for _, proc in ipairs(procs.list) do
    local c = proc.contract
    local summary
    if c and (c.inputs_raw or c.outputs_raw) then
      summary = (c.inputs_raw or "[?]") .. " -> " .. (c.outputs_raw or "[?]")
    end
    out[proc.name] = { lnum = proc.lnum, summary = summary }
  end
  return out
end

-- Resolves an invocation target to its contract via goto's resolver.
-- Returns contract, nil on success; nil, reason otherwise.
local function callee_contract(ctx, target, kind)
  if ctx.lookups > MAX_LOOKUPS then
    return nil, "cross-file lookup budget exhausted"
  end
  ctx.lookups = ctx.lookups + 1
  local item, reason = ctx.resolver(target, kind)
  if not item then
    return nil, reason or (target .. " not resolved")
  end
  local procs, err = contracts_for_file(ctx, item.filename)
  if not procs then
    return nil, err
  end
  local proc = procs.by_lnum[tonumber(item.cmd)]
  if not proc then
    return nil, "no procedure declaration at " .. item.filename .. ":" .. item.cmd
  end
  return proc.contract
end

-- Raw lines of an on-disk file for constant-definition lookups, cached
-- under the file's freshness key like every other callee lookup (an
-- analysis pass may resolve many `push.CONST`s against the same module).
local function file_lines_cached(path)
  local g = goto_mod()
  local key = g._stat_key(path)
  if not key then
    return nil, "cannot stat " .. path
  end
  local hit = lines_cache[path]
  if hit and hit.key == key then
    return hit.lines
  end
  local text = g._read_file(path)
  if not text then
    return nil, "cannot read " .. path
  end
  local lines = vim.split(text, "\n", { plain = true })
  lines_cache[path] = { key = key, lines = lines }
  return lines
end

-- Resolves `push.CONST`: how many felts does the constant push?
-- A `word("...")` constant pushes 4; any other single value pushes 1.
local function const_width(ctx, name)
  if ctx.lookups > MAX_LOOKUPS then
    return nil, "cross-file lookup budget exhausted"
  end
  ctx.lookups = ctx.lookups + 1
  local item, reason = ctx.resolver(name, nil)
  if not item then
    return nil, reason or (name .. " not resolved")
  end
  local line
  if item.filename == ctx.bufpath then
    line = ctx.lines[tonumber(item.cmd)]
  else
    local lines, err = file_lines_cached(item.filename)
    if not lines then
      return nil, err
    end
    line = lines[tonumber(item.cmd)]
  end
  if not line then
    return nil, "definition line not found for " .. name
  end
  if line:match("=%s*word%s*%(") then
    return 4
  end
  -- Bracket-list word constants: `const PAUSED_WORD = [1, 0, 0, 0]`.
  local list = line:match("=%s*(%b[])")
  if list then
    local parsed = notation.parse_list(list)
    if parsed and not parsed.lower_bound then
      return parsed.width
    end
    return nil, "unparseable constant list"
  end
  return 1
end

---------------------------------------------------------------------------
-- Events: instruction tokens and tracker comments in buffer order
---------------------------------------------------------------------------

local function build_events(ctx, first, last)
  local events = {}
  local lines = ctx.lines
  for lnum = first, last do
    local code = ctx.code_only(lines[lnum])
    for tok in code:gmatch("%S+") do
      events[#events + 1] = { kind = "op", tok = tok, lnum = lnum }
    end
    local comment = notation.comment_part(lines[lnum])
    if comment then
      local ckind, value = notation.tracker_kind(comment)
      if ckind == "tracker" then
        local joined = notation.join_value(value, lines, lnum)
        if joined then
          local bracket = joined:match("^(%b[])")
          if bracket then
            local parsed = notation.parse_list(bracket)
            if parsed then
              events[#events + 1] = { kind = "tracker", parsed = parsed, lnum = lnum }
            end
          end
        end
      end
    end
  end
  return events
end

-- Index of the event just past the block opened before `i` (nesting-aware).
-- Used to skip diverged arms and to slice repeat bodies.
local function block_end(events, i)
  local depth = 1
  while i <= #events do
    local ev = events[i]
    if ev.kind == "op" then
      if opens_block(ev.tok) then
        depth = depth + 1
      elseif ev.tok == "end" then
        depth = depth - 1
        if depth == 0 then
          return i
        end
      elseif ev.tok == "else" and depth == 1 then
        return i
      end
    end
    i = i + 1
  end
  return i
end

---------------------------------------------------------------------------
-- Transfers
---------------------------------------------------------------------------

-- Index ranges the assembler accepts for positional ops. Simulating an
-- out-of-range index (`movup.99`) would model code that cannot assemble --
-- and in relative mode manufacture a phantom caller draw, up to a bogus
-- caller-underflow diagnostic. Out of range bails the proc with a reason,
-- exactly like an unknown mnemonic.
local SPECIAL_RANGE = {
  swap = { 1, 15 },
  movup = { 2, 15 },
  movdn = { 2, 15 },
  dup = { 0, 15 },
  dupw = { 0, 3 },
  swapw = { 1, 3 },
  movupw = { 2, 3 },
  movdnw = { 2, 3 },
}

-- Positional ops. `n` is the parsed index immediate (nil when absent).
local function apply_special(base, n, state, ctx, lnum)
  local cells = state.cells
  if base == "swap" then
    n = n or 1
    ensure_cells(state, n + 1, ctx, lnum)
    cells[1], cells[n + 1] = cells[n + 1], cells[1]
  elseif base == "movup" then
    ensure_cells(state, n + 1, ctx, lnum)
    table.insert(cells, 1, table.remove(cells, n + 1))
  elseif base == "movdn" then
    ensure_cells(state, n + 1, ctx, lnum)
    table.insert(cells, n + 1, table.remove(cells, 1))
  elseif base == "dup" then
    n = n or 0
    ensure_cells(state, n + 1, ctx, lnum)
    table.insert(cells, 1, cells[n + 1])
  elseif base == "dupw" then
    n = n or 0
    ensure_cells(state, (n + 1) * 4, ctx, lnum)
    local word = {}
    for i = 1, 4 do
      word[i] = cells[n * 4 + i]
    end
    for i = 4, 1, -1 do
      table.insert(cells, 1, word[i])
    end
  elseif base == "swapw" then
    n = n or 1
    ensure_cells(state, (n + 1) * 4, ctx, lnum)
    for i = 1, 4 do
      cells[i], cells[n * 4 + i] = cells[n * 4 + i], cells[i]
    end
  elseif base == "swapdw" then
    ensure_cells(state, 16, ctx, lnum)
    for i = 1, 8 do
      cells[i], cells[i + 8] = cells[i + 8], cells[i]
    end
  elseif base == "movupw" then
    ensure_cells(state, (n + 1) * 4, ctx, lnum)
    local word = {}
    for i = 1, 4 do
      word[i] = table.remove(cells, n * 4 + 1)
    end
    for i = 4, 1, -1 do
      table.insert(cells, 1, word[i])
    end
  elseif base == "movdnw" then
    ensure_cells(state, (n + 1) * 4, ctx, lnum)
    local word = {}
    for i = 1, 4 do
      word[i] = table.remove(cells, 1)
    end
    for i = 4, 1, -1 do
      table.insert(cells, n * 4 + 1, word[i])
    end
  elseif base == "reversew" then
    ensure_cells(state, 4, ctx, lnum)
    for i = 1, 2 do
      cells[i], cells[5 - i] = cells[5 - i], cells[i]
    end
  elseif base == "reversedw" then
    ensure_cells(state, 8, ctx, lnum)
    for i = 1, 4 do
      cells[i], cells[9 - i] = cells[9 - i], cells[i]
    end
  else
    return false
  end
  return true
end

-- Names a computed result from an `expr` template and the popped operands.
local function computed_cell(entry, popped)
  local name
  if entry.expr then
    local a = popped[1] and popped[1].name
    local b = popped[2] and popped[2].name
    local function simple(s)
      return s and #s <= 12 and s:match("^[%w_']+$") ~= nil
    end
    if simple(a) and ((not entry.expr:find("{b}", 1, true)) or simple(b)) then
      name = entry.expr:gsub("{a}", a):gsub("{b}", b or "")
      if #name > 24 then
        name = nil
      end
    end
  end
  return { name = name, origin = "computed" }
end

-- Splits `push` immediates on dots that are not inside `[..]` ranges.
local function split_push_imm(s)
  local parts, depth, start = {}, 0, 1
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "[" or c == "(" then
      depth = depth + 1
    elseif c == "]" or c == ")" then
      depth = depth - 1
    elseif c == "." and depth == 0 then
      parts[#parts + 1] = s:sub(start, i - 1)
      start = i + 1
    end
  end
  parts[#parts + 1] = s:sub(start)
  return parts
end

local function apply_push(state, imm, ctx, lnum)
  if not imm then
    return nil, "push requires an immediate"
  end
  local pushed = {}
  for _, part in ipairs(split_push_imm(imm)) do
    if part:match("^%-?%d+$") or part:match("^0x%x+$") then
      pushed[#pushed + 1] = { name = part, origin = "literal" }
    else
      local cname, a, b = part:match("^([%w_]+)%[(%d+)%.%.(%d+)%]$")
      if cname then
        local group = { kind = "span", name = cname, width = tonumber(b) - tonumber(a) }
        for idx = tonumber(a), tonumber(b) - 1 do
          pushed[#pushed + 1] = { name = cname, lane = idx, origin = "literal", group = group }
        end
      elseif part:match("^[%w_]+$") then
        local width, reason = const_width(ctx, part)
        if not width then
          poison(state, ("constant %s: %s"):format(part, reason))
          return true
        end
        if width == 4 then
          local group = { kind = "word", name = part, width = 4 }
          for lane = 0, 3 do
            pushed[#pushed + 1] = { name = part, lane = lane, origin = "literal", group = group }
          end
        elseif width == 1 then
          pushed[#pushed + 1] = { name = part, origin = "literal" }
        else
          -- Miden constants are felts or words; any other width means the
          -- definition was misread. Refuse rather than model it wrong.
          poison(state, ("constant %s has width %d (not a felt or a word)"):format(part, width))
          return true
        end
      else
        return nil, ("unrecognized push immediate %q"):format(part)
      end
    end
  end
  -- `push.a.b.c` leaves c on top: operands are pushed left to right.
  local top_first = {}
  for i = #pushed, 1, -1 do
    top_first[#top_first + 1] = pushed[i]
  end
  push_cells(state, top_first)
  return true
end

-- call/syscall/dyncall seen from the caller: the top 16 elements are
-- replaced by the callee's outputs (anonymous when unknown); depth is
-- otherwise preserved. Only valid when at least 16 cells are visible.
local function apply_context_call(state, ctx, lnum, target, kind)
  if state.mode == "relative" and #state.cells < 16 then
    poison(state, kind .. " at unknown depth (fewer than 16 declared elements visible)")
    return
  end
  ensure_cells(state, 16, ctx, lnum)
  local outputs
  if target then
    local contract = callee_contract(ctx, target, kind)
    if contract and contract.outputs and not contract.outputs.lower_bound then
      if contract.outputs.width == 16 then
        outputs = notation.expand(contract.outputs)
        for _, c in ipairs(outputs) do
          c.origin = "callee"
        end
      end
    end
  end
  outputs = outputs or anon_cells(16, "callee")
  for _ = 1, 16 do
    table.remove(state.cells, 1)
  end
  push_cells(state, outputs)
  state.renormalized = true
end

---------------------------------------------------------------------------
-- The simulator
---------------------------------------------------------------------------

local sim_block -- forward declaration

-- Applies one instruction token. Returns true, or nil + bail reason.
local function apply_op(state, tok, ctx, lnum)
  -- `.err=`/.err="..." on assertions annotates the error, not the arity.
  tok = tok:gsub("%.err=.*$", "")

  local base, imm = tok:match("^([%w_]+)%.(.*)$")
  if not base then
    base, imm = tok, nil
  end

  -- Invocations -----------------------------------------------------------
  if base == "exec" then
    if not imm then
      return nil, "exec requires a target"
    end
    local contract, reason = callee_contract(ctx, imm, "exec")
    if not contract or not contract.inputs or not contract.outputs then
      local why = reason
        or (contract and (contract.inputs_reason or contract.outputs_reason))
        or "no Inputs/Outputs contract"
      if not ctx.reported_callees[imm] then
        ctx.reported_callees[imm] = true
        diag(
          ctx,
          lnum,
          "hint",
          "callee-unresolved",
          ("cannot determine stack effect of exec.%s (%s); analysis resumes at the next `# => [...]` comment"):format(
            imm,
            why
          )
        )
      end
      poison(state, ("exec.%s: %s"):format(imm, why))
      return true
    end
    if contract.inputs.lower_bound or contract.outputs.lower_bound then
      poison(state, ("exec.%s: contract declared with `...`"):format(imm))
      return true
    end
    -- Floor ambiguity: when the callee's declared consumption reaches into
    -- the zone near the 16-floor (depth - inputs < 16) and it produces
    -- outputs, its exact exit depth depends on where its INTERNAL ops dip
    -- below 16 and pull zeros -- unknowable from the contract (e.g. the
    -- kernel's get_item exits one deeper than its net effect suggests).
    -- Poison and let the next handwritten tracker resynchronize; when the
    -- consumed elements sit safely above the floor the result is exact.
    if
      state.mode == "floored"
      and contract.outputs.width > 0
      and #state.cells - contract.inputs.width < 16
    then
      pop_cells(state, contract.inputs.width, ctx, lnum)
      push_cells(state, anon_cells(contract.outputs.width, "callee"))
      poison(
        state,
        ("exec.%s near the stack floor: exact depth depends on callee internals"):format(imm)
      )
      return true
    end
    pop_cells(state, contract.inputs.width, ctx, lnum)
    local outputs = notation.expand(contract.outputs)
    for _, c in ipairs(outputs) do
      c.origin = "callee"
    end
    push_cells(state, outputs)
    return true
  end
  if base == "call" or base == "syscall" then
    if not imm then
      return nil, base .. " requires a target"
    end
    apply_context_call(state, ctx, lnum, imm, base)
    return true
  end
  if base == "dyncall" then
    pop_cells(state, 1, ctx, lnum)
    if state.mode == "relative" then
      -- dyncall truncates the physical stack to 16, cutting into territory
      -- we cannot see from a relative prefix (whether the proc is
      -- exec-invoked or a call proc documented in the relative style).
      state.renormalized = true
      poison(state, "dyncall: the physical stack is only partially visible here")
      return true
    end
    apply_context_call(state, ctx, lnum, nil, "dyncall")
    -- dyncall truncates the caller-visible stack to exactly 16.
    local keep = {}
    for i = 1, 16 do
      keep[i] = state.cells[i]
    end
    state.cells = keep
    return true
  end
  if base == "dynexec" then
    pop_cells(state, 1, ctx, lnum)
    poison(state, "dynexec target unknown")
    return true
  end
  if base == "procref" then
    if not imm then
      return nil, "procref requires a target"
    end
    local short = imm:match("([%w_%$]+)$") or imm
    local gname = short:upper() .. "_ROOT"
    local group = { kind = "word", name = gname, width = 4 }
    local cells = {}
    for lane = 0, 3 do
      cells[#cells + 1] = { name = gname, lane = lane, origin = "literal", group = group }
    end
    push_cells(state, cells)
    return true
  end
  if base == "push" then
    return apply_push(state, imm, ctx, lnum)
  end

  -- Decorators: dotted suffixes are subcommands, never arity immediates.
  if base == "debug" or base == "trace" or base == "adv" or base == "emit" then
    return true
  end

  -- Positional ops --------------------------------------------------------
  if arity.special[base] then
    local n = imm and tonumber(imm) or nil
    if imm and not n then
      return nil, ("non-numeric index on %s"):format(tok)
    end
    if not n and (base == "movup" or base == "movdn" or base == "movupw" or base == "movdnw") then
      return nil, ("%s requires an index"):format(base)
    end
    local range = SPECIAL_RANGE[base]
    if n and range and (n % 1 ~= 0 or n < range[1] or n > range[2]) then
      return nil, ("%s: index outside the assembler's %d..%d range"):format(tok, range[1], range[2])
    end
    apply_special(base, n, state, ctx, lnum)
    return true
  end

  -- Table-driven arities --------------------------------------------------
  local entry = arity.ops[base]
  if not entry then
    return nil, ("unknown instruction %q"):format(tok)
  end
  -- `exp.uN` carries a bit-length hint, not a literal exponent: the
  -- exponent still comes from the stack.
  local has_imm = imm ~= nil and not (base == "exp" and imm:match("^u%d+$"))
  local effective
  if has_imm then
    effective = entry.imm
  else
    effective = entry.bare
  end
  if not effective then
    return nil, ("%s %s an immediate; not covered"):format(base, imm and "with" or "without")
  end
  local pops, pushes = effective[1], effective[2]
  if pushes == "n" then
    pushes = tonumber(imm)
    if not pushes then
      return nil, ("non-numeric count on %s"):format(tok)
    end
  end
  local popped = pop_cells(state, pops, ctx, lnum)
  -- A provably failing assertion marks the path as diverging: `push.0
  -- assert` is the corpus idiom for unreachable branch arms.
  if base == "assert" and popped[1] and popped[1].origin == "literal" and popped[1].name == "0" then
    state.bottom = true
    return true
  end
  if
    base == "assertz"
    and popped[1]
    and popped[1].origin == "literal"
    and popped[1].name
    and popped[1].name:match("^%d+$")
    and popped[1].name ~= "0"
  then
    state.bottom = true
    return true
  end
  if pushes > 0 then
    local out = {}
    if pushes == 1 then
      out[1] = computed_cell(entry, popped)
    else
      out = anon_cells(pushes, "computed")
    end
    push_cells(state, out)
  end
  return true
end

-- Checks a tracker against the state; adopts its names when widths agree,
-- and uses it as a recovery point when the state is poisoned.
local function apply_tracker(state, parsed, ctx, lnum)
  if state.bottom then
    return
  end
  local sim_width = #state.cells
  if state.poisoned then
    if not parsed.lower_bound then
      state.cells = notation.expand(parsed)
      for _, c in ipairs(state.cells) do
        c.origin = "comment"
      end
      refloor(state)
      state.poisoned = nil
    end
    return
  end
  if ctx.inexact then
    -- Widths are lower bounds on both sides; only adopt on exact agreement.
    if not parsed.lower_bound and parsed.width == sim_width then
      state.cells = notation.expand(parsed)
      for _, c in ipairs(state.cells) do
        c.origin = "comment"
      end
    end
    return
  end
  if parsed.lower_bound then
    if sim_width < parsed.width then
      diag(
        ctx,
        lnum,
        "warn",
        "comment-stale",
        ("stack has %d element(s) here, comment claims at least %d"):format(sim_width, parsed.width)
      )
    end
    return
  end
  -- Style split in the corpus: some trackers describe the full physical
  -- stack, others leave out floor zeros -- either the ones the VM pulled in
  -- mid-procedure (`floor_debt`) or all padding entirely. A smaller claim is
  -- accepted when everything beneath the claimed prefix is zeros AND either
  -- the surplus is exactly the pulled-in debt (the author counts the
  -- un-pulled view) or the claim doesn't mention pad() at all (the author
  -- writes only the meaningful prefix). A claim that accounts for padding
  -- explicitly but gets it wrong -- the min_burn_amount bug -- stays flagged.
  if state.mode == "floored" and parsed.width < sim_width then
    local extra = sim_width - parsed.width
    -- Zeros, or untouched anonymous entry cells (a proc documented only via
    -- its typed signature): both are padding as far as the author's
    -- prefix-only view is concerned.
    local all_zeros = true
    for k = parsed.width + 1, sim_width do
      local c = state.cells[k]
      if c.name ~= "0" and not (c.name == nil and c.origin == "input") then
        all_zeros = false
        break
      end
    end
    local mentions_pad = false
    for _, e in ipairs(parsed.elems) do
      if e.kind == "pad" then
        mentions_pad = true
        break
      end
    end
    if all_zeros and (extra == state.floor_debt or not mentions_pad) then
      local prefix = notation.expand(parsed)
      for _, c in ipairs(prefix) do
        c.origin = "comment"
      end
      for k = parsed.width + 1, sim_width do
        prefix[#prefix + 1] = state.cells[k]
      end
      state.cells = prefix
      return
    end
  end
  -- UPPERCASE claim elements are words by convention, but authors also name
  -- FELT CONSTANTS in caps (`SUBKEY_ADDR_HI`). The simulation knows which:
  -- when the cell at that position is an ungrouped single felt whose name
  -- matches (often the constant's longer name), re-size the element to 1.
  -- Accept and adopt if the corrected widths line up.
  if parsed.width ~= sim_width then
    local pos, total, cells = 1, 0, {}
    for _, e in ipairs(parsed.elems) do
      local w = e.width
      local cell = state.cells[pos]
      if
        e.kind == "word"
        and cell
        and not cell.group
        and cell.name
        and (cell.name == e.name or cell.name:find(e.name, 1, true) ~= nil)
      then
        w = 1
        cells[#cells + 1] = { name = e.name, origin = "comment" }
      else
        for _, c in ipairs(notation.expand({ elems = { e } })) do
          c.origin = "comment"
          cells[#cells + 1] = c
        end
      end
      pos = pos + w
      total = total + w
    end
    if total == sim_width then
      state.cells = cells
      return
    end
  end
  -- Relative-mode trackers freely mix two views -- the declared-inputs
  -- prefix and the caller's deeper stack the author can see. The two cannot
  -- be reconciled from the contract, so width mismatches are not flagged in
  -- relative mode (the exec-net check against declared Outputs verifies
  -- these procs instead). Floored mode keeps strict checking: there the
  -- physical stack is fully known, and that is where the runtime-fatal
  -- depth-16 bug class lives.
  if state.mode == "relative" and parsed.width ~= sim_width then
    return
  end
  if parsed.width ~= sim_width then
    diag(
      ctx,
      lnum,
      "warn",
      "comment-stale",
      ("stack has %d element(s) here, comment claims %d"):format(sim_width, parsed.width)
    )
    return
  end
  local cells = notation.expand(parsed)
  for _, c in ipairs(cells) do
    c.origin = "comment"
  end
  -- Order check: widths agree, so normally the comment's names are adopted
  -- without judgment (they carry primes, rebindings and synonyms). The one
  -- case that IS judged: the comment lists exactly the same named elements
  -- as the simulation but in a different order. Same multiset + different
  -- sequence cannot be a renaming -- it is a swapped-operands comment, the
  -- width-blind bug class order-insensitive checking cannot see. Guarded to
  -- floored mode (the physical stack is fully known there; relative-mode
  -- comments legitimately mix declared-inputs and caller views) and to
  -- fully-named states on both sides, so synonyms and anonymous cells can
  -- never trip it. Compared by name only: word lanes are numbered in
  -- opposite directions by push (top-first) and by notation expansion
  -- (declaration order), so lane indices are presentation, not identity.
  if state.mode == "floored" then
    local counts, all_named, same_order = {}, true, true
    for i = 1, sim_width do
      local sk, ck = state.cells[i].name, cells[i].name
      if not sk or not ck then
        all_named = false
        break
      end
      counts[sk] = (counts[sk] or 0) + 1
      counts[ck] = (counts[ck] or 0) - 1
      if sk ~= ck then
        same_order = false
      end
    end
    if all_named and not same_order then
      local same_multiset = true
      for _, n in pairs(counts) do
        if n ~= 0 then
          same_multiset = false
          break
        end
      end
      if same_multiset then
        diag(
          ctx,
          lnum,
          "warn",
          "comment-reordered",
          ("comment lists the same elements in a different order; the stack is %s here"):format(
            M.render_cells(state)
          )
        )
        return -- keep the simulated order; adopting the wrong one would hide it
      end
    end
  end
  state.cells = cells
end

-- Copies every field of `src` over `dst` (clearing fields absent in src),
-- so a state table can be rebound in place without enumerating its fields.
local function assign_state(dst, src)
  for k in pairs(dst) do
    dst[k] = nil
  end
  for k, v in pairs(src) do
    dst[k] = v
  end
end

-- Positional merge of two if/else arm states, merged into `a` in place.
local function merge_arms(a, b, ctx, lnum)
  if a.bottom then
    assign_state(a, b)
    return
  end
  if b.bottom then
    return
  end
  a.renormalized = a.renormalized or b.renormalized
  a.consumed = math.max(a.consumed, b.consumed)
  a.floor_debt = math.max(a.floor_debt, b.floor_debt)
  if a.poisoned or b.poisoned then
    a.poisoned = a.poisoned or b.poisoned
    return
  end
  if #a.cells ~= #b.cells then
    if a.renormalized then
      -- A call/dyncall arm legitimately re-normalizes depth; the merged
      -- suffix is unknowable but not wrong.
      poison(
        a,
        ("branches leave %d vs %d elements (call re-normalization)"):format(#a.cells, #b.cells)
      )
    else
      diag(
        ctx,
        lnum,
        "warn",
        "branch-depth",
        ("if/else branches leave different stack depths: %d vs %d elements"):format(
          #a.cells,
          #b.cells
        )
      )
      poison(a, "branch depths differ")
    end
    return
  end
  local merged = {}
  for i = 1, #a.cells do
    local ca, cb = a.cells[i], b.cells[i]
    if ca.name == cb.name and ca.name ~= nil then
      merged[i] = ca
    elseif ca.name == nil then
      merged[i] = cb
    elseif cb.name == nil then
      merged[i] = ca
    else
      merged[i] = { origin = "merge" }
    end
  end
  a.cells = merged
end

-- Simulates events from `i` until the block's terminator (`end`, or `else`
-- at this nesting level). Returns next_index, terminator ("end"|"else"|nil),
-- or nil + bail reason.
sim_block = function(ctx, events, i, state)
  while i <= #events do
    local ev = events[i]
    ctx.ops = ctx.ops + 1
    if ctx.ops > MAX_SIM_OPS then
      return nil, nil, "instruction budget exceeded"
    end
    if ev.kind == "tracker" then
      if ctx.check_trackers then
        apply_tracker(state, ev.parsed, ctx, ev.lnum)
        ctx.proc.states[ev.lnum] = copy_state(state)
      end
      i = i + 1
    elseif ev.tok == "end" or ev.tok == "else" then
      return i + 1, ev.tok
    elseif state.bottom then
      -- Diverged: fast-forward to this block's terminator, touching nothing.
      if opens_block(ev.tok) then
        i = block_end(events, i + 1)
        -- block_end may stop at an inner `else`; skip on to the real end.
        while i <= #events and events[i].tok ~= "end" do
          i = block_end(events, i + 1)
        end
        i = i + 1
      else
        i = i + 1
      end
    elseif ev.tok == "if.true" or ev.tok == "if.false" then
      -- if.false swaps which arm runs on which value; for width/name merge
      -- purposes the two forms are identical.
      pop_cells(state, 1, ctx, ev.lnum)
      refloor(state)
      local before = copy_state(state)
      local ni, term, bail = sim_block(ctx, events, i + 1, state)
      if not ni then
        return nil, nil, bail
      end
      local other = before
      if term == "else" then
        ni, term, bail = sim_block(ctx, events, ni, other)
        if not ni then
          return nil, nil, bail
        end
        if term ~= "end" then
          return nil, nil, "malformed if/else nesting"
        end
      end
      merge_arms(state, other, ctx, events[ni - 1].lnum)
      ctx.proc.states[events[ni - 1].lnum] = copy_state(state)
      i = ni
    elseif ev.tok == "while.true" then
      pop_cells(state, 1, ctx, ev.lnum)
      refloor(state)
      local entry = copy_state(state)
      local ni, term, bail = sim_block(ctx, events, i + 1, state)
      if not ni then
        return nil, nil, bail
      end
      if term ~= "end" then
        return nil, nil, "malformed while block"
      end
      if not state.poisoned and not state.bottom then
        if #state.cells ~= #entry.cells + 1 then
          diag(
            ctx,
            ev.lnum,
            "warn",
            "while-net",
            ("while.true body must leave exactly one new element (the continuation flag); it leaves %+d"):format(
              #state.cells - #entry.cells
            )
          )
          poison(state, "while body is not depth-neutral")
        else
          pop_cells(state, 1, ctx, ev.lnum)
          refloor(state)
          -- Loop-varying cells lose their names (they only described the
          -- first iteration).
          local merged = {}
          for k = 1, #state.cells do
            local ca, cb = state.cells[k], entry.cells[k]
            if cb and ca.name == cb.name then
              merged[k] = ca
            else
              merged[k] = { origin = "merge" }
            end
          end
          state.cells = merged
        end
      end
      ctx.proc.states[events[ni - 1].lnum] = copy_state(state)
      i = ni
    elseif ev.tok:match("^repeat%.") then
      local count = tonumber(ev.tok:match("^repeat%.(%d+)$"))
      if not count then
        return nil, nil, ("unparseable %q"):format(ev.tok)
      end
      local body_first = i + 1
      local body_last = block_end(events, body_first) -- index of `end`
      if body_last > #events then
        return nil, nil, "unterminated repeat block"
      end
      for iter = 1, count do
        local saved = ctx.check_trackers
        ctx.check_trackers = saved and iter == 1
        local ni, term, bail = sim_block(ctx, events, body_first, state)
        ctx.check_trackers = saved
        if not ni then
          return nil, nil, bail
        end
        if term ~= "end" then
          return nil, nil, "malformed repeat block"
        end
      end
      ctx.proc.states[events[body_last].lnum] = copy_state(state)
      i = body_last + 1
    else
      local ok, reason = apply_op(state, ev.tok, ctx, ev.lnum)
      if not ok then
        return nil, nil, ("%s (line %d)"):format(reason, ev.lnum)
      end
      refloor(state)
      ctx.proc.states[ev.lnum] = copy_state(state)
      i = i + 1
    end
  end
  return i, nil
end

---------------------------------------------------------------------------
-- Per-procedure analysis
---------------------------------------------------------------------------

local function entry_state(proc)
  local c = proc.contract
  -- Program entrypoints run on the physical stack: their declared inputs
  -- (padded to 16 with the VM's zero-fill) when a parseable contract says
  -- so, otherwise 16 unknown input elements. Always floored -- begin IS the
  -- 16-element stack.
  if proc.invocation == "entrypoint" then
    local cells
    if c.inputs and not c.inputs.lower_bound and c.inputs.width <= 16 then
      cells = notation.expand(c.inputs)
      for _, cell in ipairs(cells) do
        cell.origin = "input"
      end
      for _, cell in ipairs(zero_cells(16 - #cells)) do
        cells[#cells + 1] = cell
      end
    else
      cells = anon_cells(16, "input")
    end
    return new_state("floored", cells)
  end
  if FLOORED_INVOCATIONS[proc.invocation] then
    if c.inputs and not c.inputs.lower_bound and c.inputs.width == 16 then
      local cells = notation.expand(c.inputs)
      for _, cell in ipairs(cells) do
        cell.origin = "input"
      end
      return new_state("floored", cells)
    end
    if c.inputs and not c.inputs.lower_bound then
      -- The whole file family (guardian, multisig, ...) documents call
      -- procs relative to their meaningful arguments, padding ignored. The
      -- abi-16 diagnostic already flags the convention violation once;
      -- analyzing in the same relative style keeps every tracker checkable
      -- instead of drowning the file in padding-offset warnings.
      local cells = notation.expand(c.inputs)
      for _, cell in ipairs(cells) do
        cell.origin = "input"
      end
      return new_state("relative", cells)
    end
    return new_state("floored", anon_cells(16, "input"))
  end
  -- Relative (exec/dynexec): entry is the declared inputs.
  if not c.inputs then
    return nil,
      c.inputs_reason and ("Inputs contract unparseable: " .. c.inputs_reason)
        or "no Inputs contract"
  end
  local cells = notation.expand(c.inputs)
  for _, cell in ipairs(cells) do
    cell.origin = "input"
  end
  -- A relative proc declaring exactly 16 inputs is written in the padded
  -- convention (kernel api wrappers, protocol library): the visible stack IS
  -- the physical stack, so the 16-floor applies and must be modeled.
  if not c.inputs.lower_bound and c.inputs.width == 16 then
    return new_state("floored", cells)
  end
  local state = new_state("relative", cells)
  return state, nil, c.inputs.lower_bound
end

local function check_abi16(ctx)
  local proc, c = ctx.proc, ctx.proc.contract
  local function bad(field, parsed)
    if parsed and not parsed.lower_bound and parsed.width ~= 16 then
      local idx = c[field .. "_idx"]
      local lnum = idx and (proc.doc_lnum + idx - 1) or proc.lnum
      diag(
        ctx,
        lnum,
        "error",
        "abi-16",
        ("%s-invoked procedures take exactly 16 stack elements; %s declares %d (pad to 16)"):format(
          proc.invocation,
          field:gsub("^%l", string.upper),
          parsed.width
        )
      )
    end
  end
  bad("inputs", c.inputs)
  bad("outputs", c.outputs)
end

local function analyze_proc(ctx)
  local proc = ctx.proc
  if not proc.invocation then
    proc.bailed = "no #! Invocation annotation (and no script attribute)"
    return
  end
  if not proc.end_lnum then
    proc.bailed = "unterminated procedure"
    return
  end
  if proc.same_line_body then
    -- Events are line-based; tokens sharing the declaration line would be
    -- silently absent from the simulation. Refuse rather than guess.
    proc.bailed = "body tokens on the declaration line are not simulated"
    return
  end
  if
    not FLOORED_INVOCATIONS[proc.invocation]
    and not RELATIVE_INVOCATIONS[proc.invocation]
    and proc.invocation ~= "entrypoint"
  then
    proc.bailed = ("unknown invocation kind %q"):format(proc.invocation)
    return
  end

  -- The 16-in/16-out convention check only applies where the author claimed
  -- the ABI explicitly; inferred script modes already required Inputs == 16.
  if FLOORED_INVOCATIONS[proc.invocation] and not proc.inferred_invocation then
    check_abi16(ctx)
  end

  local state, reason, inexact = entry_state(proc)
  if not state then
    proc.bailed = reason
    return
  end
  ctx.inexact = inexact or false
  ctx.check_trackers = true
  ctx.ops = 0

  local events = build_events(ctx, proc.body_lnum or proc.lnum + 1, proc.end_lnum)
  local i, term, bail = sim_block(ctx, events, 1, state)
  if not i then
    proc.bailed = bail
    return
  end
  -- The block terminator consumed here is the procedure's own `end`; only
  -- tracker comments may legitimately follow it in the event stream.
  if term ~= "end" then
    proc.bailed = "unbalanced blocks in procedure body"
    return
  end
  for k = i, #events do
    if events[k].kind == "op" then
      proc.bailed = "unbalanced blocks in procedure body"
      return
    end
  end
  proc.exit = copy_state(state)

  if state.bottom then
    return -- every path diverges; nothing to check at the exit
  end

  -- Exit checks ----------------------------------------------------------
  if state.mode == "floored" then
    -- Entrypoints have no return-depth contract to violate: the floor keeps
    -- them at >= 16, and the VM caps program stack outputs at 16, so only
    -- ending DEEPER than 16 is an error.
    if proc.invocation == "entrypoint" then
      if not state.poisoned and #state.cells > 16 then
        diag(
          ctx,
          proc.end_lnum,
          "error",
          "exit-depth",
          ("program ends with %d stack elements; the VM rejects executions ending deeper than 16 (stack outputs are capped at 16)"):format(
            #state.cells
          )
        )
      end
    elseif not state.poisoned and #state.cells ~= 16 then
      diag(
        ctx,
        proc.end_lnum,
        "error",
        "exit-depth",
        ("returns at stack depth %d; %s-invoked procedures must return at exactly 16 or the VM aborts with InvalidStackDepthOnReturn"):format(
          #state.cells,
          proc.invocation
        )
      )
    end
  else
    local c = proc.contract
    if
      not state.poisoned
      and not ctx.inexact
      and c.outputs
      and not c.outputs.lower_bound
      and #state.cells ~= c.outputs.width
    then
      diag(
        ctx,
        proc.end_lnum,
        "warn",
        "exec-net",
        ("body leaves %d element(s) but Outputs declares %d"):format(#state.cells, c.outputs.width)
      )
    end
    if state.consumed > 0 and not ctx.inexact then
      diag(
        ctx,
        ctx.first_draw_lnum or proc.end_lnum,
        "warn",
        "caller-underflow",
        ("consumes %d element(s) beyond the declared Inputs -- an exec-invoked procedure dipping below its inputs eats the caller's stack"):format(
          state.consumed
        )
      )
    end
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Analyzes `lines` as the content of the file at `path`. Pure with respect
-- to the UI: no notifications, no buffer access; reasons travel in the
-- result. Returns { procs = {...}, diagnostics = {...} } or nil, reason.
function M.analyze_lines(lines, path)
  local g = goto_mod()
  local resolver, err = g.make_resolver(path, table.concat(lines, "\n"))
  if not resolver then
    return nil, err
  end
  local local_procs = scan_procs(lines, g._code_only)
  local result = { procs = local_procs.list, diagnostics = {} }
  local shared = {
    lines = lines,
    bufpath = path,
    code_only = g._code_only,
    resolver = resolver,
    local_procs = local_procs,
    lookups = 0,
    reported_callees = {},
  }
  for _, proc in ipairs(local_procs.list) do
    local ctx = setmetatable({ proc = proc }, { __index = shared })
    analyze_proc(ctx)
    for _, d in ipairs(proc.diagnostics) do
      result.diagnostics[#result.diagnostics + 1] = d
    end
    shared.lookups = ctx.lookups or shared.lookups
  end
  -- Full tiebreak: table.sort is unstable, and same-line diagnostics would
  -- otherwise come back in nondeterministic order across runs.
  table.sort(result.diagnostics, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    if a.code ~= b.code then
      return a.code < b.code
    end
    return a.message < b.message
  end)
  return result
end

-- Buffer wrapper around analyze_lines.
function M.analyze(bufnr)
  bufnr = bufnr or 0
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil, "unnamed buffer"
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.analyze_lines(lines, path)
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

-- Compresses a state back to `[name, pad(N), ...]` notation. Word and span
-- groups whose cells sit adjacent and complete re-collapse to their group
-- name; runs of zero-fill collapse to pad(N); anonymous runs to unknown(N).
function M.render_cells(state, max_items)
  max_items = max_items or 12
  if state.bottom then
    return "unreachable"
  end
  local parts = {}
  local cells = state.cells
  local i = 1
  while i <= #cells do
    local c = cells[i]
    local part, step
    if c.group and c.lane == 0 then
      -- Try to collapse the whole group.
      local w = c.group.width
      local whole = true
      for k = 1, w - 1 do
        local n = cells[i + k]
        if not n or n.group ~= c.group or n.lane ~= k then
          whole = false
          break
        end
      end
      if whole then
        part = c.group.kind == "span"
            and c.group.name ~= "pad"
            and (c.group.name .. "(" .. w .. ")")
          or c.group.name
        step = w
      end
    end
    if not part and c.name == "0" then
      local n = 0
      while cells[i + n] and cells[i + n].name == "0" do
        n = n + 1
      end
      if n >= 2 then
        part = "pad(" .. n .. ")"
        step = n
      end
    end
    if not part and c.name == nil then
      local n = 0
      while cells[i + n] and cells[i + n].name == nil do
        n = n + 1
      end
      part = n >= 2 and ("unknown(" .. n .. ")") or "?"
      step = n
    end
    if not part then
      part = c.lane and ("%s[%d]"):format(c.name, c.lane) or c.name
      step = 1
    end
    parts[#parts + 1] = part
    i = i + step
  end
  local suffix = ""
  if #parts > max_items then
    suffix = (", ..+%d"):format(#parts - max_items)
    for k = #parts, max_items + 1, -1 do
      parts[k] = nil
    end
  end
  local rendered = "[" .. table.concat(parts, ", ") .. suffix .. "]"
  if state.poisoned then
    rendered = "? " .. rendered .. " (" .. state.poisoned .. ")"
  end
  return rendered
end

return M
