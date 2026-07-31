-- Omnifunc completion for Miden Assembly (<C-x><C-o>).
--
-- Everything completes from what the plugin already knows -- the navigation
-- index, the buffer's imports and the instruction reference -- so the
-- candidate list is exactly the set of names `gd` could resolve, never a
-- fuzzy guess:
--   exec./call./procref.<..>   local procs, imported symbols, module
--                              qualifiers; after `mod::`, that module's procs
--   syscall.<..>               kernel library procs
--   push.<..>                  constants, local and imported/qualified
--   bare instruction position  opcodes (with stack effects) and keywords
-- Procedure candidates show their `[inputs] -> [outputs]` doc contract in
-- the menu -- the de facto type signature in Miden code.

local M = {}

local INVOKE_KEYWORDS = { exec = true, call = true, procref = true, syscall = true, push = true }

-- Kinds shown in the popup: f(unction), v(alue/const), t(ype), m(odule),
-- k(eyword/opcode). Unresolvable re-exports keep a blank kind.
local KIND_LETTER = { proc = "f", const = "v", type = "t" }

-- Control-flow and declaration keywords the instruction reference does not
-- carry (it documents opcodes only). Dotted entries retrigger member
-- completion once accepted.
local KEYWORDS = {
  "begin",
  "call.",
  "const",
  "dyncall",
  "dynexec",
  "else",
  "end",
  "exec.",
  "if.false",
  "if.true",
  "proc",
  "procref.",
  "pub",
  "push.",
  "repeat.",
  "syscall.",
  "type",
  "use",
  "while.true",
}

---------------------------------------------------------------------------
-- Candidate sources
---------------------------------------------------------------------------

local function buffer_state()
  local bufpath = vim.api.nvim_buf_get_name(0)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return bufpath, lines, table.concat(lines, "\n")
end

local function add(items, word, kind, menu, info)
  items[#items + 1] = { word = word, kind = kind or "", menu = menu, info = info, dup = 0 }
end

local function symbol_items(items, symbols, want_kind)
  local stack = require("masm.stack")
  for _, sym in ipairs(symbols or {}) do
    -- Unknown kinds (unresolvable re-exports) are offered everywhere: the
    -- name is visibly part of the interface even when its source is not.
    if sym.kind == want_kind or sym.kind == nil then
      local menu
      if want_kind == "proc" and sym.path and sym.lnum then
        menu = stack.contract_summary(sym.path, sym.lnum)
      end
      add(items, sym.name, sym.kind and KIND_LETTER[sym.kind], menu)
    end
  end
end

-- Resolves the interface of the module an import alias points at, memoized
-- per completion call (several imported symbols usually share a module).
local function module_lookup(bufpath)
  local memo = {}
  return function(segs)
    local key = table.concat(segs, "::")
    if memo[key] == nil then
      memo[key] = require("masm.goto").module_symbols(bufpath, segs) or false
    end
    return memo[key] or nil
  end
end

-- Candidates for `exec.` / `call.` / `procref.` / `syscall.` / `push.` with
-- no qualifier yet: local definitions, selectively-imported symbols and
-- module qualifiers.
local function unqualified_items(kw, bufpath, lines, buftext)
  local g = require("masm.goto")
  local stack = require("masm.stack")
  local items = {}

  if kw == "syscall" then
    symbol_items(items, g.kernel_symbols(bufpath), "proc")
    return items
  end

  local want = kw == "push" and "const" or "proc"
  if want == "proc" then
    for name, proc in pairs(stack.buffer_proc_summaries(lines)) do
      if name ~= "begin" then
        add(items, name, "f", proc.summary)
      end
    end
  else
    for _, line in ipairs(lines) do
      local name = line:match("^%s*const%s+([%w_]+)") or line:match("^%s*pub%s+const%s+([%w_]+)")
      if name then
        add(items, name, "v")
      end
    end
  end

  local mods, syms = g.buffer_imports(buftext)
  local lookup = module_lookup(bufpath)
  for alias, imp in pairs(syms) do
    local kind
    for _, sym in ipairs(lookup(imp.mod) or {}) do
      if sym.name == imp.orig then
        kind = sym.kind
        break
      end
    end
    if kind == want or kind == nil then
      add(items, alias, kind and KIND_LETTER[kind])
    end
  end
  for alias, segs in pairs(mods) do
    add(items, alias .. "::", "m", table.concat(segs, "::"))
  end
  return items
end

local function qualified_items(kw, qual, bufpath, buftext)
  local g = require("masm.goto")
  local path = qual:match("^([%w_:%$]-)::$")
  if not path or path == "" then
    return {}
  end
  local segs = {}
  for seg in path:gmatch("[^:]+") do
    segs[#segs + 1] = seg
  end
  local mods = g.buffer_imports(buftext)
  if mods[segs[1]] then
    local full = vim.list_extend({}, mods[segs[1]])
    for i = 2, #segs do
      full[#full + 1] = segs[i]
    end
    segs = full
  end
  local items = {}
  symbol_items(items, g.module_symbols(bufpath, segs), kw == "push" and "const" or "proc")
  return items
end

local function opcode_items()
  local items, seen = {}, {}
  for _, e in ipairs(require("masm.instructions")) do
    local name = e[1]
    if name:find("{", 1, true) then
      -- Immediate-only templates (`loc_load.{n}`) surface as `loc_load.`;
      -- variants whose bare mnemonic is also documented (`lte`/`lte.{n}`,
      -- the reference lists the bare form first) are covered by it.
      name = name:match("^([%w_%.]-%.){") or ""
      if name ~= "" and seen[name:sub(1, -2)] then
        name = ""
      end
    end
    if name ~= "" and not seen[name] then
      seen[name] = true
      add(items, name, "k", e[3] ~= "" and e[3] or nil, e[2])
    end
  end
  for _, kw in ipairs(KEYWORDS) do
    if not seen[kw] then
      seen[kw] = true
      add(items, kw, "k")
    end
  end
  return items
end

---------------------------------------------------------------------------
-- Omnifunc
---------------------------------------------------------------------------

-- Text left of the word being completed, captured at findstart: the second
-- omnifunc call runs with the base already removed from the line, so
-- context must be decided here and remembered.
local before_base

function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local text = line:sub(1, col)
    local word = text:match("[%w_%$]*$")
    before_base = text:sub(1, #text - #word)
    return col - #word
  end

  local before = before_base or ""
  local bufpath, lines, buftext = buffer_state()
  local items
  local kw, qual = before:match("([%w_]+)%.([%w_:%$]*)$")
  if kw and INVOKE_KEYWORDS[kw] then
    if qual == "" then
      items = unqualified_items(kw, bufpath, lines, buftext)
    else
      items = qualified_items(kw, qual, bufpath, buftext)
    end
  elseif before:match("^%s*$") or before:match("%s$") then
    items = opcode_items()
  else
    return {}
  end

  local matches = {}
  for _, item in ipairs(items) do
    if vim.startswith(item.word, base) then
      matches[#matches + 1] = item
    end
  end
  table.sort(matches, function(a, b)
    return a.word < b.word
  end)
  return matches
end

return M
