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
--  * Refreshes must be cheap, never different: per-procedure results are
--    memoized (see "Per-procedure memoization") strictly as a replay of
--    what a cold pass would compute -- every cache in this module is keyed
--    or validated so that a warm result is bit-identical to a cold one.

local notation = require("masm.stacknotation")
local arity = require("masm.arity")
local util = require("masm.util")

local M = {}

---@class masm.StackCell one felt on the simulated stack
---@field name string? display name (nil = anonymous)
---@field origin string? "input"|"literal"|"computed"|"callee"|"caller"|"comment"|"zerofill"|"merge"|"unknown"
---@field lane integer? 0-based lane inside a word/span group
---@field group {kind: string, name: string, width: integer}? display grouping

---@class masm.StackState
---@field cells masm.StackCell[] top-first
---@field mode '"floored"'|'"relative"'
---@field consumed integer felts drawn from beneath the declared inputs (relative)
---@field poisoned string? reason the suffix is unknowable
---@field bottom boolean this path diverges (provably-failing assertion)
---@field renormalized boolean a call/dyncall/syscall ran on this path
---@field floor_debt integer zeros the 16-floor has pulled in so far (floored)

---@class masm.StackDiagnostic
---@field lnum integer 1-based line
---@field col integer
---@field severity '"error"'|'"warn"'|'"hint"'
---@field code string e.g. "exit-depth", "comment-stale", "abi-16"
---@field message string
---@field target string? publish-time dedup key (callee-unresolved only)

---@class masm.StackProc a scanned (and possibly analyzed) procedure
---@field name string
---@field lnum integer declaration line
---@field body_lnum integer? first body line
---@field end_lnum integer? matching `end` line
---@field doc_lnum integer first line of the `#!` doc block
---@field contract table parsed doc contract (masm.stacknotation)
---@field attrs string[] `@` attributes above the declaration
---@field invocation string? "exec"|"call"|"syscall"|"dyncall"|"dynexec"|"entrypoint"
---@field bailed string? reason the whole proc was not simulated
---@field diagnostics masm.StackDiagnostic[]
---@field states table<integer, masm.StackState> per-line snapshots
---@field exit masm.StackState?

---@class masm.StackResult
---@field procs masm.StackProc[]
---@field diagnostics masm.StackDiagnostic[]

-- Per-procedure simulated-instruction budget (repeat unrolling included).
-- Real procedures are 5-50 instructions; the cap only exists so a
-- pathological `repeat.32` nest cannot stall the UI thread.
local MAX_SIM_OPS = 10000
-- Distinct cross-file callee/constant lookups per analyze() pass. Lookups
-- hit goto's mtime-keyed caches after the first pass; the cap bounds the
-- cold-start worst case. Beyond it, affected procs poison with a reason.
-- Distinct is load-bearing (budget_lookup): a target already counted this
-- pass never ticks again -- a repeat lookup is a pure cache hit, and a
-- total count would let 400 `push.CONST`s of one constant starve genuine
-- diagnostics later in the file.
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
-- caller-underflow check). Draws made while the state is poisoned are NOT
-- counted: the suffix is unknowable there, so a phantom cell conjured under
-- a poison is not attributable to the caller's declared Inputs -- counting
-- it made caller-underflow fire on states the analyzer had already declared
-- unknowable, and no `# => [...]` resync could clear the tally.
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
    if not state.poisoned then
      if state.consumed == 0 and ctx then
        ctx.first_draw_lnum = ctx.first_draw_lnum or lnum
      end
      state.consumed = state.consumed + need
    end
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

-- `target` marks the diagnostic for publish-time per-target dedup
-- (callee-unresolved only; see analyze_lines).
local function diag(ctx, lnum, severity, code, message, target)
  ctx.proc.diagnostics[#ctx.proc.diagnostics + 1] =
    { lnum = lnum, col = 0, severity = severity, code = code, message = message, target = target }
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

-- Blanks every line once (util.code_only). Scanning and event building both
-- consume blanked lines; computing them a single time per pass (instead of
-- re-blanking per consumer, which one refresh used to do three or four
-- times) is the analyzer's single-pass text prep.
local function blank_lines(lines)
  local out = {}
  for i = 1, #lines do
    out[i] = util.code_only(lines[i])
  end
  return out
end

-- Doc-block contract parse, memoized by the block's exact text: every scan
-- pass re-reads all ~doc blocks of the buffer, and notation.contract's
-- per-element parsing was a measurable slice of the refresh. Contract
-- tables are treated as immutable everywhere (nothing writes to a parsed
-- contract), so sharing one table between identical doc blocks is safe.
-- Pure function of the doc text; bounded like every cache here.
local contract_memo = util.new_cache(8192)
local function contract_of(doc)
  local key = table.concat(doc, "\n")
  local hit = contract_memo:get(key)
  if hit then
    return hit
  end
  local contract = notation.contract(doc)
  contract_memo:put(key, contract)
  return contract
end

-- Scans a file's lines for proc declarations and their doc contracts.
-- Shared between the current buffer and callee files (contract cache).
-- `code_lines` is the blanked twin of `lines` (blank_lines).
-- Returns { by_lnum = { [decl_lnum] = proc } , list = { proc... } } where
-- proc = { name, lnum, end_lnum, doc_lnum, contract, attrs, invocation }.
local function scan_procs(lines, code_lines)
  local by_lnum, list = {}, {}
  local i = 1
  while i <= #lines do
    local code = code_lines[i]
    -- Plain-find pre-filters: the anchored patterns cannot match without
    -- the keyword substring, and a find is far cheaper than the matches on
    -- the vast majority of lines that declare nothing.
    local decl = code:find("proc", 1, true)
        and (code:match("^%s*pub%s+proc%f[^%w_]") or code:match("^%s*proc%f[^%w_]"))
      or nil
    local is_begin = (code:find("begin", 1, true) and code:match("^%s*begin%f[^%w_]")) ~= nil
    if decl or is_begin then
      local name = decl and code:match("proc%s+(" .. util.IDENT .. ")") or "begin"
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
          bal = bal + paren_delta(code_lines[body_first])
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
        rest = code:match("^%s*pub%s+proc%s+" .. util.IDENT .. "(.*)$")
          or code:match("^%s*proc%s+" .. util.IDENT .. "(.*)$")
        rest_lnum = i
      else
        -- Typed signature: the remainder follows the last `)` of the line
        -- where the parens balanced (body_first - 1; equals `i` when they
        -- balance on the declaration line itself).
        rest_lnum = body_first - 1
        local closed = rest_lnum == i and code or code_lines[rest_lnum]
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
      -- Set when a NEW declaration line appears before this proc's `end`:
      -- MASM has no nested procedures, so a `proc`/`begin` line inside the
      -- body can only mean the `end` above it is missing. Ending the search
      -- there (instead of letting the unterminated proc swallow the next
      -- declaration and steal ITS `end`) keeps every following procedure
      -- independently analyzable while the author is still typing the one
      -- above; the unterminated proc itself is reported by analyze_proc's
      -- missing-end diagnostic.
      local truncated_at
      while not end_lnum and j <= #lines do
        local cl = code_lines[j]
        if
          (
            cl:find("proc", 1, true)
            and (cl:match("^%s*pub%s+proc%f[^%w_]") or cl:match("^%s*proc%f[^%w_]"))
          ) or (cl:find("begin", 1, true) and cl:match("^%s*begin%f[^%w_]"))
        then
          truncated_at = j
          break
        end
        -- Plain-find pre-filter: only tokenize lines that can contain a
        -- block token (every opens_block token contains "if.", "while." or
        -- "repeat.", and closing needs "end"). False positives -- e.g. a
        -- path segment like `exec.foo::send` -- just take the exact
        -- tokenizing path below; they can never be missed.
        if
          cl:find("end", 1, true)
          or cl:find("if.", 1, true)
          or cl:find("while.", 1, true)
          or cl:find("repeat.", 1, true)
        then
          for tok in cl:gmatch("%S+") do
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
        end
        if end_lnum then
          break
        end
        j = j + 1
      end
      local contract = contract_of(doc)
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
      -- Resume at the declaration that truncated an unterminated proc, so
      -- the procs below it are scanned normally; only a proc with neither
      -- an `end` nor a following declaration runs to end-of-file.
      i = end_lnum and (end_lnum + 1) or truncated_at or (#lines + 1)
    else
      i = i + 1
    end
  end
  return { by_lnum = by_lnum, list = list }
end

---------------------------------------------------------------------------
-- Contract cache for callee files
---------------------------------------------------------------------------

-- Bounded (one entry per callee file; the generous cap is pure overflow
-- armor -- see util.new_cache for the full-clear-on-overflow reasoning).
local contract_cache = util.new_cache(10000)
local lines_cache = util.new_cache(10000)
-- Per-procedure analysis memo (see "Per-procedure memoization" below).
local proc_cache = util.new_cache(8192)
-- Hit/miss counters for the memo, exposed for tests (they assert WHICH
-- procs re-analyze, not just what the result is) and for profiling.
M._memo_stats = { hits = 0, misses = 0 }

function M.clear_cache()
  contract_cache:clear()
  lines_cache:clear()
  proc_cache:clear()
  -- Content-keyed and therefore never stale, but :MasmRebuildIndex promises
  -- to drop the caches wholesale -- honor the documented contract.
  contract_memo:clear()
end

-- Scanned procs (declarations + doc contracts) of a callee file, cached
-- under its live-buffer-wins content key (util.content_key). Live-buffer-
-- wins is not optional here: the resolver that produced the line numbers
-- this scan is indexed by reads a modified buffer's LIVE text
-- (resolve.file_interface), so reading disk instead made an unsaved callee
-- edit either serve a stale contract or -- when the edit shifted lines --
-- miss the declaration entirely and report a "no procedure declaration"
-- hint about a line where one is plainly visible.
local function file_procs(path)
  local hit = contract_cache:get(path)
  local key, read_bufnr, found = util.content_key(path, hit and hit.bufnr)
  if not key then
    return nil, "cannot stat " .. path
  end
  if hit and hit.key == key then
    hit.bufnr = found
    return hit.procs
  end
  local text = util.content_text(path, read_bufnr)
  if not text then
    return nil, "cannot read " .. path
  end
  local lines = vim.split(text, "\n", { plain = true })
  local procs = scan_procs(lines, blank_lines(lines))
  contract_cache:put(path, { key = key, bufnr = found, procs = procs })
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
---@param path string
---@param lnum integer declaration line
---@return string? summary
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
---@param lines string[]
---@return table<string, {lnum: integer, summary: string?}>
function M.buffer_proc_summaries(lines)
  local procs = scan_procs(lines, blank_lines(lines))
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

local BUDGET_REASON = "cross-file lookup budget exhausted"

-- One key per distinct lookup target, shared verbatim by the raw lookups'
-- budget accounting (budget_lookup) and deps_fresh's replay/val_memo, so
-- "distinct" means exactly the same thing on the cold path and in memo
-- validation.
local function lookup_key(t, target, kind)
  return t .. "\1" .. target .. "\1" .. tostring(kind)
end

-- The budget tick for one raw lookup. Only a target not yet counted this
-- pass draws the budget (MAX_LOOKUPS counts DISTINCT lookups; repeats are
-- cache hits that cost nothing). Returns false when the budget refuses --
-- without counting the target, so a refused target keeps refusing for the
-- rest of the pass (the budget never shrinks): every lookup of one target
-- gets the same budget outcome within a pass, which deps_fresh's val_memo
-- relies on.
local function budget_lookup(ctx, key)
  if ctx.counted[key] then
    return true
  end
  if ctx.lookups > MAX_LOOKUPS then
    return false
  end
  ctx.counted[key] = true
  ctx.lookups = ctx.lookups + 1
  return true
end

-- Resolves an invocation target to its contract via goto's resolver.
-- Returns contract, nil on success; nil, reason otherwise. The `_core`
-- form is budget-free (memo validation replays the budget itself and
-- memoizes core answers per pass); `_raw` adds the per-pass lookup budget
-- and is what analysis goes through.
local function callee_contract_core(ctx, target, kind)
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

local function callee_contract_raw(ctx, target, kind)
  if not budget_lookup(ctx, lookup_key("callee", target, kind)) then
    return nil, BUDGET_REASON
  end
  return callee_contract_core(ctx, target, kind)
end

-- Everything a caller-side transition can consume from a callee contract:
-- the raw Inputs/Outputs spellings (the parsed lists and the names spliced
-- into cells derive deterministically from them) and the reason strings
-- (they appear verbatim in hint messages and poison reasons). A resolution
-- failure signs as its reason, so "resolved to a different file/proc" and
-- "stopped resolving" both change the signature.
local function contract_sig(contract, reason)
  if not contract then
    return "nil:" .. tostring(reason)
  end
  return tostring(contract.inputs_raw)
    .. "|"
    .. tostring(contract.inputs_reason)
    .. "|"
    .. tostring(contract.outputs_raw)
    .. "|"
    .. tostring(contract.outputs_reason)
end

-- Recording wrapper: every lookup a procedure's analysis performs is
-- appended to ctx.deps with a signature of what it observed, so the memo
-- (proc_cache) can later ask "would this lookup answer the same today?"
-- without re-simulating. One dep is recorded per raw call -- including
-- budget-refused ones -- so replaying deps reproduces the lookup budget's
-- cold-pass accounting exactly.
local function callee_contract(ctx, target, kind)
  local contract, reason = callee_contract_raw(ctx, target, kind)
  local deps = ctx.deps
  if deps then
    deps[#deps + 1] =
      { t = "callee", target = target, kind = kind, sig = contract_sig(contract, reason) }
  end
  return contract, reason
end

-- Raw lines of a file for constant-definition lookups, cached under the
-- same live-buffer-wins content key as file_procs (an analysis pass may
-- resolve many `push.CONST`s against the same module, and the resolved
-- definition line is a LIVE line when that module's buffer is modified).
local function file_lines_cached(path)
  local hit = lines_cache:get(path)
  local key, read_bufnr, found = util.content_key(path, hit and hit.bufnr)
  if not key then
    return nil, "cannot stat " .. path
  end
  if hit and hit.key == key then
    hit.bufnr = found
    return hit.lines
  end
  local text = util.content_text(path, read_bufnr)
  if not text then
    return nil, "cannot read " .. path
  end
  local lines = vim.split(text, "\n", { plain = true })
  lines_cache:put(path, { key = key, bufnr = found, lines = lines })
  return lines
end

-- Resolves `push.CONST`: how many felts does the constant push?
-- A `word("...")` constant pushes 4; any other single value pushes 1.
-- `_core`/`_raw`/wrapper split for the same reason as callee_contract.
local function const_width_core(ctx, name)
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

local function const_width_raw(ctx, name)
  if not budget_lookup(ctx, lookup_key("const", name, nil)) then
    return nil, BUDGET_REASON
  end
  return const_width_core(ctx, name)
end

-- The signature is the observed width or the failure reason: the width is
-- all the simulation consumes, and the reason appears verbatim in the
-- poison message.
local function const_sig(width, reason)
  return width and ("w:" .. width) or ("e:" .. tostring(reason))
end

local function const_width(ctx, name)
  local width, reason = const_width_raw(ctx, name)
  local deps = ctx.deps
  if deps then
    deps[#deps + 1] = { t = "const", target = name, sig = const_sig(width, reason) }
  end
  return width, reason
end

---------------------------------------------------------------------------
-- Events: instruction tokens and tracker comments in buffer order
---------------------------------------------------------------------------

local function build_events(ctx, first, last)
  local events = {}
  local lines = ctx.lines
  for lnum = first, last do
    local code = ctx.code_lines[lnum]
    for tok in code:gmatch("%S+") do
      events[#events + 1] = { kind = "op", tok = tok, lnum = lnum }
    end
    local comment = notation.comment_part(lines[lnum])
    if comment then
      local ckind, value = notation.tracker_kind(comment)
      -- "tracker" always carries a value; the `and value` spells that out
      -- for flow analysis (the two returns cannot be tied in a signature).
      if ckind == "tracker" and value then
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
-- exactly like an unknown mnemonic. arity.special bases ABSENT from this
-- table (swapdw, reversew, reversedw) take no index at all: the bundled
-- instruction reference documents them in bare form only (no `.{n}`
-- variant exists for the assembler to accept), so ANY immediate on them
-- bails the same way.
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
  end
  -- No fallthrough handling: the only caller dispatches on arity.special,
  -- and every base in that table has a branch above, so an unmatched base
  -- cannot reach here (a formerly present `return false` was dead code).
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

-- _lnum: unused here but kept so the handler matches the dispatch signature.
local function apply_push(state, imm, ctx, _lnum)
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
      -- Emitted per exec SITE, tagged with the target; analyze_lines keeps
      -- only the first per target at publish time. Emitting unconditionally
      -- keeps every proc's outcome a pure function of its own source and
      -- lookups -- no cross-proc reporting state for the memo to replay.
      diag(
        ctx,
        lnum,
        "hint",
        "callee-unresolved",
        ("cannot determine stack effect of exec.%s (%s); analysis resumes at the next `# => [...]` comment"):format(
          imm,
          why
        ),
        imm
      )
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
    local short = imm:match("(" .. util.IDENT .. ")$") or imm
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
  -- `emit` is deliberately NOT intercepted here: arity.ops.emit ({0, 0} in
  -- both bare and immediate form) is its one source of truth, keeping the
  -- consistency test's arity/reference/highlight link live instead of
  -- shadowing the table entry dead.
  if base == "debug" or base == "trace" or base == "adv" then
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
    if n and not range then
      -- No entry means no immediate form exists (see SPECIAL_RANGE):
      -- `swapdw.3` cannot assemble any more than `movup.99` can.
      return nil, ("%s: %s takes no index immediate"):format(tok, base)
    end
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
    local count = tonumber(imm)
    if not count then
      return nil, ("non-numeric count on %s"):format(tok)
    end
    pushes = count --[[@as integer]]
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
  -- Checked BEFORE the invocation gate: an end-less proc is a syntax error
  -- the assembler rejects whatever its invocation mode is, so this cannot
  -- false-positive on valid code -- which is why it may be a real WARN
  -- diagnostic and not just a bail reason. It must be one: bail reasons
  -- only surface as overlay ghost text (off by default), and this state is
  -- exactly what the buffer looks like while a new proc is being typed
  -- above existing code -- losing it silently would break the "never
  -- guess, always state a reason" contract at the UI.
  if not proc.end_lnum then
    proc.bailed = "missing `end`"
    diag(
      ctx,
      proc.lnum,
      "warn",
      "missing-end",
      ("%s has no matching `end`; the assembler rejects this, and its body is not analyzed"):format(
        proc.name == "begin" and "this begin block" or ("procedure " .. proc.name)
      )
    )
    return
  end
  if not proc.invocation then
    proc.bailed = "no #! Invocation annotation (and no script attribute)"
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
    -- `not state.poisoned` mirrors the exec-net check above -- defense in
    -- depth: ensure_cells never counts draws made under a poison, so this
    -- only differs when the poison arrived AFTER real draws. Even those stay
    -- unreported at a poisoned exit: never warn on a state the analyzer
    -- declared unknowable (a `# => [...]` resync clears the poison, and the
    -- tally of real draws then speaks again).
    if state.consumed > 0 and not state.poisoned and not ctx.inexact then
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
-- Per-procedure memoization
---------------------------------------------------------------------------
-- A procedure's analysis is a pure function of (a) its own source slice and
-- (b) the answers its cross-proc lookups returned. On a typical edit only
-- the touched proc's slice changes, so everything else can be replayed from
-- proc_cache instead of re-simulated. The key is (a); (b) is validated per
-- hit by re-asking each recorded lookup (deps_fresh) -- lookups are
-- freshness-cached in goto/resolve, so validation is cheap, and threading
-- them through the KEY instead would miss on every unrelated buffer edit.

-- The key's source slice must cover every line the analysis can read:
--  * the contiguous `#`/`@` block above the declaration -- a superset of
--    what doc_block_above consults (contract, attrs, and the plain comments
--    it skips over), so an attribute-only proc (no `#!` block) still keys
--    on its `@note_script` line;
--  * the declaration through its `end`;
--  * up to MAX_JOIN_LINES trailing comment lines: a tracker on the `end`
--    line itself may join_value into them.
-- Content-only (no line numbers): edits ABOVE a proc shift it without
-- changing its analysis, so hits survive and results are rebased by the
-- declaration-line delta. The path is included because resolution of the
-- same source text differs per file.
local function proc_cache_key(path, lines, proc)
  if not proc.end_lnum then
    -- Unterminated: no definite extent to key on. Never caching these is
    -- also what keeps the missing-end outcome sound -- the truncated slice
    -- (declaration to the next declaration) has no stable content key, and
    -- re-deriving the bail + warn each pass is as cheap as a memo hit.
    return nil
  end
  local first = proc.lnum
  while first > 1 and lines[first - 1]:match("^%s*[#@]") do
    first = first - 1
  end
  local last = proc.end_lnum
  local stop = math.min(#lines, proc.end_lnum + notation.MAX_JOIN_LINES)
  while last < stop and lines[last + 1]:match("^%s*#") do
    last = last + 1
  end
  return path .. "\1" .. table.concat(lines, "\n", first, last)
end

-- True when every recorded lookup would answer with the same signature
-- today, i.e. the cached analysis is still what a cold pass would compute.
-- Deps are replayed in recorded order against the pass's CUMULATIVE lookup
-- budget (one dep was recorded per raw lookup, refused ones included, and
-- validated hits sync their accounting back), with budget_lookup's exact
-- distinct-target semantics: a dep whose target is already counted -- by an
-- earlier proc of the pass or earlier in this replay -- ticks nothing, a
-- new target ticks once, and only an uncounted target can be refused. The
-- budget therefore stands at exactly the value a cold pass would have at
-- every replayed lookup: a dep that was budget-refused when analyzed
-- validates precisely when the replay refuses at the same point, and a
-- refusal can never appear where a cold pass would not have had one. On a
-- validation failure nothing is synced and the proc re-analyzes from the
-- same cumulative accounting a cold pass would reach it with.
local function deps_fresh(deps, shared)
  local vctx = setmetatable({ lookups = shared.lookups }, { __index = shared })
  local memo = shared.val_memo
  -- Targets this replay newly counts against the budget, staged apart from
  -- shared.counted (which vctx would otherwise mutate through its __index):
  -- on a validation failure nothing may leak into the pass-wide accounting
  -- -- the re-analysis performs the real raw lookups and counts them itself.
  local counted_new = {}
  for _, dep in ipairs(deps) do
    -- The budget guard is replayed here (not inside the lookup): the
    -- current answer for a given target is pass-constant and memoized in
    -- shared.val_memo, so each distinct target is looked up once per pass
    -- however many procs depend on it -- but the budget accounting must
    -- still mirror budget_lookup's per replayed dep to stay in cold-pass
    -- lockstep.
    local mkey = lookup_key(dep.t, dep.target, dep.kind)
    local counted = shared.counted[mkey] or counted_new[mkey]
    local sig_now
    if not counted and vctx.lookups > MAX_LOOKUPS then
      sig_now = (dep.t == "callee") and contract_sig(nil, BUDGET_REASON)
        or const_sig(nil, BUDGET_REASON)
    else
      if not counted then
        counted_new[mkey] = true
        vctx.lookups = vctx.lookups + 1
      end
      sig_now = memo[mkey]
      if not sig_now then
        if dep.t == "callee" then
          sig_now = contract_sig(callee_contract_core(vctx, dep.target, dep.kind))
        else
          sig_now = const_sig(const_width_core(vctx, dep.target))
        end
        memo[mkey] = sig_now
      end
    end
    if sig_now ~= dep.sig then
      return false
    end
  end
  shared.lookups = vctx.lookups
  for k in pairs(counted_new) do
    shared.counted[k] = true
  end
  return true
end

-- What a hit must restore: outcome fields (bailed/exit/states/diagnostics)
-- plus the base declaration line for rebasing. Bail reasons are the one
-- outcome that can EMBED an absolute line number ("unknown instruction %q
-- (line 42)", produced by sim_block's bail path only); the number is split
-- out so a shifted hit can re-embed the shifted line.
local function snapshot_proc(ctx)
  local proc = ctx.proc
  local snap = {
    lnum = proc.lnum,
    deps = ctx.deps,
    bailed = proc.bailed,
    exit = proc.exit,
    states = proc.states,
    diagnostics = proc.diagnostics,
  }
  if proc.bailed then
    local line = proc.bailed:match("%(line (%d+)%)$")
    if line then
      snap.bailed_line = tonumber(line)
      snap.bailed_prefix = proc.bailed:gsub("%s*%(line %d+%)$", "")
    end
  end
  return snap
end

-- Rebases a cached outcome onto the freshly scanned `proc`. States and exit
-- snapshots are shared by reference: cells are immutable by design (see the
-- module header) and nothing mutates a state after analysis. Diagnostics
-- are copied when shifted so the cached originals keep their coordinates.
local function restore_proc(proc, snap)
  local delta = proc.lnum - snap.lnum
  proc.exit = snap.exit
  proc.bailed = snap.bailed
  if snap.bailed_line then
    proc.bailed = ("%s (line %d)"):format(snap.bailed_prefix, snap.bailed_line + delta)
  end
  if delta == 0 then
    proc.states = snap.states
    proc.diagnostics = snap.diagnostics
  else
    local states = {}
    for lnum, state in pairs(snap.states) do
      states[lnum + delta] = state
    end
    proc.states = states
    local diags = {}
    for i, d in ipairs(snap.diagnostics) do
      diags[i] = {
        lnum = d.lnum + delta,
        col = d.col,
        severity = d.severity,
        code = d.code,
        message = d.message,
        target = d.target,
      }
    end
    proc.diagnostics = diags
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Analyzes `lines` as the content of the file at `path`. Pure with respect
-- to the UI: no notifications, no buffer access; reasons travel in the
-- result. Returns { procs = {...}, diagnostics = {...} } or nil, reason.
---@param lines string[]
---@param path string the file the lines belong to (anchors resolution)
---@return masm.StackResult? result
---@return string? reason
function M.analyze_lines(lines, path)
  local buftext = table.concat(lines, "\n")
  local code_lines = blank_lines(lines)
  -- One blanking pass for the whole refresh: the resolver's import parse,
  -- resolution internals and the drift canary all call code_text(buftext),
  -- and the primed memo answers them from the per-line pass above.
  util.prime_code_text(buftext, code_lines)
  local resolver, err = require("masm.goto").make_resolver(path, buftext)
  if not resolver then
    return nil, err
  end
  local local_procs = scan_procs(lines, code_lines)
  local result = { procs = local_procs.list, diagnostics = {} }
  local shared = {
    lines = lines,
    bufpath = path,
    code_lines = code_lines,
    resolver = resolver,
    local_procs = local_procs,
    lookups = 0,
    -- Distinct-target set behind the lookup budget (budget_lookup): keys of
    -- targets that already drew it this pass. Reads through ctx's __index
    -- land here, so all procs of a pass share one tally.
    counted = {},
    -- Per-pass memo of current lookup signatures (deps_fresh): validation
    -- asks about the same callee once per DEPENDENT proc, but the answer
    -- within one pass is the same every time.
    val_memo = {},
  }
  -- Publish-time dedup of target-tagged hints (callee-unresolved): analysis
  -- emits one per exec site so per-proc outcomes stay pass-order independent
  -- (see apply_op); the published result keeps only the FIRST site per
  -- distinct target, in file order -- exactly the shape in-analysis dedup
  -- used to produce, without the cross-proc state it made the memo replay.
  local seen_targets = {}
  for _, proc in ipairs(local_procs.list) do
    local key = proc_cache_key(path, lines, proc)
    local hit = key and proc_cache:get(key) or nil
    if hit and deps_fresh(hit.deps, shared) then
      -- deps_fresh already synced shared.lookups, keeping the pass budget
      -- in lockstep with what a cold pass would have consumed here.
      M._memo_stats.hits = M._memo_stats.hits + 1
      restore_proc(proc, hit)
    else
      M._memo_stats.misses = M._memo_stats.misses + 1
      local ctx = setmetatable({ proc = proc, deps = {} }, { __index = shared })
      analyze_proc(ctx)
      shared.lookups = ctx.lookups or shared.lookups
      if key then
        proc_cache:put(key, snapshot_proc(ctx))
      end
    end
    for _, d in ipairs(proc.diagnostics) do
      if d.target == nil or not seen_targets[d.target] then
        if d.target ~= nil then
          seen_targets[d.target] = true
        end
        result.diagnostics[#result.diagnostics + 1] = d
      end
    end
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
---@param bufnr integer? defaults to the current buffer
---@return masm.StackResult? result
---@return string? reason
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
---@param state masm.StackState
---@param max_items integer? rendered element cap (default 12)
---@return string
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
