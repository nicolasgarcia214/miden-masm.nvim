-- Parser for Miden's stack-list notation, shared by doc contracts
-- (`#! Inputs: [...]` / `#! Outputs: [...]`) and inline trackers (`# => [...]`).
-- The notation is convention, not grammar (the assembler treats `#!` as opaque
-- trivia), so this parser must accept exactly the corpus conventions -- the
-- sizing rules below come from the protocol repo's masm-doc-comments and
-- masm-padding convention docs -- and must *refuse* anything outside them
-- with a reason rather than guess a width: a wrong width here becomes a wrong
-- diagnostic in masm.stack, which is worse than no diagnostic.
--
-- Sizing rules (felts per element):
--   lowercase ident, number, arithmetic, `x'`, `name = v` binding  -> 1
--   ALL-CAPS ident (a word, even with digits: ASSET_VALUE_0)       -> 4
--   pad(N) / name(N)                                               -> N
--   NAME[N]                                                        -> N
--   prefix{a, b, ...} (e.g. account_id_{suffix,prefix})            -> item count
--   nested [A, b] (agglayer wide values)                           -> sum
--   trailing `...`                                    -> width is a lower bound
--   `[...]` alone, prose like `<values ...>`          -> unparseable (reason)

local M = {}

-- Maximum comment continuation lines joined while looking for a closing `]`.
-- The longest legitimate wrap in the protocol corpus is 5 lines.
local MAX_JOIN_LINES = 10

---------------------------------------------------------------------------
-- Element classification
---------------------------------------------------------------------------

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Splits `s` on commas that are not nested inside (), {} or [].
local function split_top(s)
  local parts, depth, start = {}, 0, 1
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "(" or c == "{" or c == "[" then
      depth = depth + 1
    elseif c == ")" or c == "}" or c == "]" then
      depth = depth - 1
      if depth < 0 then
        return nil, "unbalanced brackets"
      end
    elseif c == "," and depth == 0 then
      parts[#parts + 1] = s:sub(start, i - 1)
      start = i + 1
    end
  end
  if depth ~= 0 then
    return nil, "unbalanced brackets"
  end
  parts[#parts + 1] = s:sub(start)
  return parts
end

-- An identifier made of letters/digits/underscore with at least one letter
-- and no lowercase letter is a word (4 felts) by convention.
local function is_word_name(name)
  return name:match("^[%u%d_]+$") ~= nil and name:match("%u") ~= nil
end

local parse_elems -- forward declaration (nested [..] recurses)

-- Classifies one element. Returns { name, width, kind } or nil, reason.
-- kind: "felt" | "word" | "span" | "pad"
local function parse_elem(raw)
  local s = trim(raw)
  if s == "" then
    return nil, "empty element"
  end
  if s:find("<") then
    return nil, ("prose element %q"):format(s)
  end

  -- `name = value` binding (e.g. `is_active_note = 0`): the name is the lhs.
  local lhs = s:match("^([%w_']+)%s*=[^=]")
  if lhs and not s:find("==") then
    return { name = lhs, width = 1, kind = "felt" }
  end

  -- Nested list `[A, b, ...]`: width is the sum of its contents.
  if s:sub(1, 1) == "[" then
    if s:sub(-1) ~= "]" then
      return nil, ("unbalanced nested list %q"):format(s)
    end
    local inner, reason = parse_elems(s:sub(2, -2))
    if not inner then
      return nil, reason
    end
    if inner.lower_bound then
      return nil, "ellipsis inside nested list"
    end
    return { name = s, width = inner.width, kind = "span", elems = inner.elems }
  end

  -- pad(N) / name(N): an explicit span of N felts.
  local base, n = s:match("^([%w_]+)%s*%((%d+)%)$")
  if base then
    return {
      name = base,
      width = tonumber(n),
      kind = base == "pad" and "pad" or "span",
    }
  end

  -- NAME[N]: an N-felt span (agglayer wide-value convention).
  local bname, bn = s:match("^([%w_]+)%[(%d+)%]$")
  if bname then
    return { name = bname, width = tonumber(bn), kind = "span" }
  end

  -- prefix{a, b}: expands to prefix .. item for each item.
  local pre, brace = s:match("^([%w_]*)%{(.+)%}$")
  if pre and brace then
    local items = split_top(brace)
    if not items then
      return nil, ("unbalanced braces in %q"):format(s)
    end
    local names = {}
    for _, it in ipairs(items) do
      local item = trim(it)
      if not item:match("^[%w_']+$") then
        return nil, ("unrecognized brace item %q in %q"):format(item, s)
      end
      names[#names + 1] = pre .. item
    end
    return { name = s, width = #names, kind = "span", names = names }
  end

  -- Plain word: ALL-CAPS ident is a 4-felt word.
  if is_word_name(s) then
    return { name = s, width = 4, kind = "word" }
  end

  -- Everything else that looks like a value expression is one felt:
  -- numbers, lowercase idents, primes (`ptr'`), arithmetic
  -- (`current_index + 1`), calls (`hash(a, b)` -- rare, prose-adjacent).
  if s:match("^[%w_'%.%+%-%*%%/%s%(%)%[%]]+$") then
    return { name = s, width = 1, kind = "felt" }
  end

  return nil, ("unrecognized element %q"):format(s)
end

-- Parses the comma-separated interior of a bracket list.
-- Returns { elems, width, lower_bound } or nil, reason.
parse_elems = function(interior)
  local out = { elems = {}, width = 0, lower_bound = false }
  local body = trim(interior)
  if body == "" then
    return out
  end
  if body == "..." then
    return nil, "ellipsis-only list"
  end
  local parts, reason = split_top(body)
  if not parts then
    return nil, reason
  end
  for i, part in ipairs(parts) do
    local p = trim(part)
    if p == "..." then
      if i ~= #parts then
        return nil, "ellipsis before end of list"
      end
      out.lower_bound = true
    else
      local elem, why = parse_elem(p)
      if not elem then
        return nil, why
      end
      out.elems[#out.elems + 1] = elem
      out.width = out.width + elem.width
    end
  end
  return out
end

-- Parses a full `[...]` list (brackets included). Public for tests.
function M.parse_list(s)
  local body = trim(s)
  local interior = body:match("^%[(.*)%]$")
  if not interior then
    return nil, ("missing brackets in %q"):format(body)
  end
  return parse_elems(interior)
end

---------------------------------------------------------------------------
-- Cell expansion (for the simulator)
---------------------------------------------------------------------------

-- Expands a parsed list into one entry per felt, top of stack first (the
-- notation is written top-first). Cells are immutable once created; a shared
-- `group` table marks felts that belong together (a word or a pad/span run)
-- so the renderer can compress them back to `ASSET` / `pad(N)` notation.
function M.expand(parsed)
  local cells = {}
  for _, elem in ipairs(parsed.elems) do
    if elem.kind == "word" then
      local group = { kind = "word", name = elem.name, width = 4 }
      for lane = 0, 3 do
        cells[#cells + 1] = { name = elem.name, lane = lane, group = group }
      end
    elseif elem.kind == "pad" then
      local group = { kind = "pad", name = "pad", width = elem.width }
      for _ = 1, elem.width do
        cells[#cells + 1] = { name = "0", group = group }
      end
    elseif elem.kind == "span" then
      local group = { kind = "span", name = elem.name, width = elem.width }
      if elem.names then -- prefix{a,b} carries explicit per-felt names
        for _, name in ipairs(elem.names) do
          cells[#cells + 1] = { name = name, group = group }
        end
      else
        for lane = 0, elem.width - 1 do
          cells[#cells + 1] = { name = elem.name, lane = lane, group = group }
        end
      end
    else
      cells[#cells + 1] = { name = elem.name }
    end
  end
  return cells
end

---------------------------------------------------------------------------
-- Comment extraction
---------------------------------------------------------------------------

-- Returns the comment part of a raw line (text after `#`, `#` included) and
-- its byte column, honoring string literals the same way goto's code_only
-- does. nil when the line has no comment.
function M.comment_part(line)
  local in_str, esc = false, false
  for i = 1, #line do
    local c = line:sub(i, i)
    if in_str then
      if esc then
        esc = false
      elseif c == "\\" then
        esc = true
      elseif c == '"' then
        in_str = false
      end
    elseif c == '"' then
      in_str = true
    elseif c == "#" then
      return line:sub(i), i
    end
  end
  return nil
end

-- Classifies a comment as an operand-stack tracker. Returns:
--   "tracker", value  -- `# => ...` or `# OS => ...` (value = text after `=>`)
--   "other-stack"     -- `# AS/AM/LM => ...` (advice/local state: not ours)
--   nil               -- any other comment
function M.tracker_kind(comment)
  local rest = comment:match("^#!?%s*(.*)$")
  if not rest then
    return nil
  end
  local tag, value = rest:match("^(%u%u)%s*=>%s*(.*)$")
  if tag then
    if tag == "OS" then
      return "tracker", value
    end
    return "other-stack"
  end
  value = rest:match("^=>%s*(.*)$")
  if value then
    return "tracker", value
  end
  return nil
end

-- Joins a bracketed value that may continue over following comment lines.
-- `first` is the text after `=>` (or after `Inputs:`); `lines` is the buffer
-- array and `lnum` the line the value starts on. Continuation lines must be
-- comment-only (`#` or `#!` prefixed); their prefix and indentation are
-- stripped. Returns joined_value, last_lnum or nil, reason.
function M.join_value(first, lines, lnum)
  local value = first
  local last = lnum
  local function balanced(s)
    local depth = 0
    for i = 1, #s do
      local c = s:sub(i, i)
      if c == "[" then
        depth = depth + 1
      elseif c == "]" then
        depth = depth - 1
      end
    end
    return depth
  end
  local depth = balanced(value)
  while depth > 0 do
    if last - lnum >= MAX_JOIN_LINES then
      return nil, "value spans too many lines"
    end
    last = last + 1
    local next_line = lines[last]
    if not next_line then
      return nil, "unterminated bracket list"
    end
    local cont = next_line:match("^%s*#!?%s?(.*)$")
    if not cont then
      return nil, "bracket list interrupted by code"
    end
    value = value .. " " .. trim(cont)
    depth = balanced(value)
  end
  if depth < 0 then
    return nil, "unbalanced bracket list"
  end
  return value, last
end

---------------------------------------------------------------------------
-- Doc-block contracts
---------------------------------------------------------------------------

-- Parses `#! Inputs:` / `#! Outputs:` / `#! Invocation:` out of the doc-block
-- lines directly above a proc. Each of inputs/outputs is either a parsed
-- list or nil with a reason recorded, so callers can distinguish "declared
-- empty" ([]) from "not declared" and "declared but unparseable".
-- Returns { inputs, inputs_reason, inputs_idx, outputs, outputs_reason,
-- outputs_idx, invocation }; the `_idx` fields are 1-based indices into
-- doc_lines so callers can place diagnostics on the declaring line.
function M.contract(doc_lines)
  local out = {}
  for i, line in ipairs(doc_lines) do
    local key, rest = line:match("^%s*#!%s*(%a+):%s*(.*)$")
    if key == "Inputs" or key == "Input" or key == "Outputs" or key == "Output" then
      -- Singular forms are corpus typos (`#! Output:`); read them anyway.
      local field = key:lower():gsub("s$", "") .. "s"
      out[field .. "_idx"] = i
      local value, join_err = M.join_value(rest, doc_lines, i)
      if not value then
        out[field .. "_reason"] = join_err
      elseif not value:match("^%[") then
        -- The multi-paragraph form ("Operand stack:" sub-headers) and prose
        -- values are real but rare; refuse rather than misread them.
        out[field .. "_reason"] = "unsupported contract form"
      else
        -- Cut anything after the closing bracket (trailing prose).
        local bracket = value:match("^(%b[])")
        if not bracket then
          out[field .. "_reason"] = "unbalanced bracket list"
        else
          local parsed, reason = M.parse_list(bracket)
          if parsed then
            out[field] = parsed
          else
            out[field .. "_reason"] = reason
          end
        end
      end
    elseif key == "Invocation" then
      out.invocation = trim(rest)
    end
  end
  return out
end

return M
