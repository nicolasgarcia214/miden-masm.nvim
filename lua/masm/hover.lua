-- `K` hover for Miden Assembly.
--
-- Two sources, tried in order:
--   1. The resolver (masm.goto): names resolve exactly like `gd`, and the
--      hover shows the definition site verbatim -- its `#!` doc comment,
--      `@` attributes and signature line. In the Miden codebases the
--      `Inputs:/Outputs:` stack notation in those doc comments is the de
--      facto type system, so this is the text a reader would otherwise jump
--      away to find. Module qualifiers show the module file's leading doc
--      block and path.
--   2. The instruction reference (masm.instructions, generated): opcodes
--      show their description and stack effect, e.g. `u32overflowing_add`:
--      (b, a, ...) -> (d, c, ...).
--
-- content() is separate from the floating-window plumbing so tests can
-- assert on the text without a UI.

local M = {}

---------------------------------------------------------------------------
-- Hover content
---------------------------------------------------------------------------

-- The definition line plus the contiguous `#!` doc comment and `@` attribute
-- lines directly above it -- exactly the block a reader sees at the source.
local function definition_block(lines, lnum)
  local first = lnum
  while first > 1 do
    local l = lines[first - 1]
    if l:match("^%s*#!") or l:match("^%s*@") then
      first = first - 1
    else
      break
    end
  end
  return vim.list_slice(lines, first, lnum)
end

-- Path shown in hovers: shortened, never the raw absolute path.
local function short_path(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

-- Reads the resolved file's lines, preferring live buffer text whenever ANY
-- loaded buffer holds the file -- not just the current one: a definition
-- edited in another window must hover its unsaved docs, not the disk state.
-- util.loaded_bufnr is the exact-name lookup scans use, and util.read_file
-- honors the same untrusted-input rules as the index (bounded reads, regular
-- files only).
local function file_lines(path)
  local util = require("masm.util")
  local bufnr = util.loaded_bufnr(path)
  if bufnr then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  local text = util.read_file(path)
  return text and vim.split(text, "\n")
end

-- Lazily indexed instruction metadata: exact name -> entry, plus every entry
-- sharing a mnemonic (`lte` and `lte.{n}`), keyed by the part before the dot.
local by_name, families
local function instruction_index()
  if by_name then
    return
  end
  by_name, families = {}, {}
  for _, e in ipairs(require("masm.instructions")) do
    by_name[e[1]] = e
    local base = e[1]:match("^[^.]+")
    families[base] = families[base] or {}
    table.insert(families[base], e)
  end
end

-- The dotted instruction word under the cursor (`push.CONST`,
-- `adv.insert_mem`), its mnemonic, and whether the cursor sits on the
-- mnemonic segment. Same convention as the resolver's cursor scan: the first
-- word ending past the cursor counts.
local function instruction_token()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based
  local init = 1
  while true do
    local s, e = line:find("[%w_.]+", init)
    if not s then
      return nil
    end
    if col < e then
      local word = line:sub(s, e):gsub("%.+$", "")
      -- Dots-only or dot-led tokens (the `...` in every `Inputs: [b, a, ...]`
      -- doc line) are not instructions; without this, #base below would
      -- error on nil.
      local base = word:match("^[%w_]+")
      if not base then
        return nil
      end
      -- `col` is 0-based, `s` 1-based: the mnemonic's last byte sits at
      -- 0-based column s - 1 + #base - 1. `col < s + #base` would count the
      -- DOT after the mnemonic as on it, showing `push.{n}` family docs when
      -- hovering the dot of an unresolvable `push.OPERAND`.
      return word, base, col < s - 1 + #base
    end
    init = e + 1
  end
end

local function instruction_content()
  instruction_index()
  local word, base, on_mnemonic = instruction_token()
  if not word then
    return nil
  end
  -- Exact entries match wherever the cursor sits in the word
  -- (`adv.insert_mem`); template variants (`push.{n}` for `push.123`) only
  -- when the cursor is on the mnemonic itself, so hovering an operand that
  -- failed to resolve reports the resolver's reason instead of opcode docs.
  local hits = by_name[word] and { by_name[word] } or (on_mnemonic and families[base])
  if not hits then
    return nil
  end
  local out = {}
  for i, e in ipairs(hits) do
    if i > 1 then
      out[#out + 1] = ""
    end
    out[#out + 1] = e[1]
    out[#out + 1] = "  " .. e[2]
    if e[3] ~= "" then
      out[#out + 1] = "  stack: " .. e[3]
    end
  end
  return { lines = out, masm = false }
end

-- Returns { lines, masm } (masm: highlight the float as MASM source), or nil
-- and a reason.
---@return {lines: string[], masm: boolean}? content
---@return string? reason
function M.content()
  local item, reason = require("masm.goto").resolve()
  if item then
    local lines = file_lines(item.filename)
    local lnum = tonumber(item.cmd) or 1
    if not lines or not lines[lnum] then
      return nil, "cannot read " .. item.filename
    end
    local out
    if item.user_data == "module" then
      out = { "# " .. short_path(item.filename) }
      for _, l in ipairs(lines) do
        if not l:match("^%s*#!") then
          break
        end
        if #out == 1 then
          out[#out + 1] = ""
        end
        out[#out + 1] = l
      end
    else
      out = definition_block(lines, lnum)
      if item.filename ~= vim.api.nvim_buf_get_name(0) then
        out[#out + 1] = ""
        out[#out + 1] = "# " .. short_path(item.filename)
      end
    end
    return { lines = out, masm = true }
  end
  local inst = instruction_content()
  if inst then
    return inst
  end
  return nil, reason
end

---------------------------------------------------------------------------
-- Floating window
---------------------------------------------------------------------------

local state = { win = nil, augroup = nil, focusing = false }

local function close_float()
  -- Augroup first: closing the window fires its WinClosed autocmd, and
  -- deleting the group beforehand is what breaks the recursion.
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win, state.augroup = nil, nil
end

local function open_float(res)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, res.lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  -- Highlight definition hovers as MASM source (doc comments, signature)
  -- when the parser exists. Deliberately not `:setf masm`: that would run
  -- the whole ftplugin (maps, tagfunc, command) inside the float.
  if res.masm and #vim.api.nvim_get_runtime_file("parser/masm.*", false) > 0 then
    pcall(vim.treesitter.start, buf, "masm")
  end

  local width = 1
  for _, l in ipairs(res.lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, 100, math.max(vim.o.columns - 4, 20))
  local height = 0
  for _, l in ipairs(res.lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  height = math.min(height, 24)

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })
  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", close_float, { buffer = buf, nowait = true })

  state.win = win
  state.augroup = vim.api.nvim_create_augroup("masm_hover", { clear = true })
  -- BufLeave also fires while `K K` focuses the float; state.focusing keeps
  -- that one switch from closing the window it targets.
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    group = state.augroup,
    buffer = vim.api.nvim_get_current_buf(),
    callback = function()
      if not state.focusing then
        close_float()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    pattern = tostring(win),
    callback = close_float,
  })
end

-- Shows the hover float; a second `K` focuses it (then the usual window
-- commands apply, plus `q` to close).
---@return nil
function M.hover()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    state.focusing = true
    vim.api.nvim_set_current_win(state.win)
    state.focusing = false
    return
  end
  local res, reason = M.content()
  if not res then
    vim.notify("masm hover: " .. (reason or "no documentation found"), vim.log.levels.WARN)
    return
  end
  open_float(res)
end

return M
