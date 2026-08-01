-- Tests for the security/robustness hardening: util.read_file's refusals,
-- the project walk's traversal bounds and symlink defenses, lib_root_file's
-- manifest containment, references-scan cancellation and the stack
-- simulator's budgets. Run with:
--   nvim --headless --clean -l tests/hardening_test.lua
-- or `make test`.
--
-- The resolver's re-export limits (5-hop depth cap, cycle detection) are
-- covered by the "Resolver limits" block in tests/masm_test.lua.
--
-- Every fixture this suite needs is created in a temp directory and deleted
-- in teardown; tests/fixtures/ is only ever read.

local helpers = dofile(
  vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")) .. "/helpers.lua"
)
local here = helpers.here
local check = helpers.check

local util = require("masm.util")
local project = require("masm.project")
local goto_mod = require("masm.goto")
local stack = require("masm.stack")

local uv = vim.uv or vim.loop
local fixtures = here .. "/fixtures/"

-- Temp-dir plumbing: every fixture tree lives under a tempname directory and
-- is deleted in the teardown at the bottom, whatever happened in between.
local tmp_dirs = {}
local function mktmp()
  local d = helpers.temp_dir()
  tmp_dirs[#tmp_dirs + 1] = d
  return d
end

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- Captures vim.notify messages emitted by fn (build_index reports walk
-- truncation through it).
local function with_notify(fn)
  local msgs = {}
  local saved = vim.notify
  -- Replacing the typed built-in is the point of the stub; restored below.
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg)
    msgs[#msgs + 1] = tostring(msg)
  end
  local ok, res = pcall(fn)
  vim.notify = saved
  if not ok then
    error(res, 0)
  end
  return res, msgs
end

local function any_contains(msgs, frag)
  for _, m in ipairs(msgs) do
    if m:find(frag, 1, true) then
      return true
    end
  end
  return false
end

local run_ok, run_err = pcall(function()
  -------------------------------------------------------------------------
  -- util.read_file: size cap, FIFO refusal, symlink behavior
  -------------------------------------------------------------------------

  local rdir = mktmp()

  -- Just over the cap (sparse, so creation is instant): refused.
  local big = rdir .. "/big.masm"
  local f = assert(io.open(big, "w"))
  f:seek("set", util.MAX_FILE_BYTES) -- one byte AT offset cap => size cap+1
  f:write("x")
  f:close()
  check(
    "read_file: file over MAX_FILE_BYTES refused",
    util.read_file(big) == nil,
    "size " .. (uv.fs_stat(big) or {}).size
  )

  -- Exactly at the cap: allowed, and the bounded read returns it whole.
  local atcap = rdir .. "/atcap.masm"
  f = assert(io.open(atcap, "w"))
  f:seek("set", util.MAX_FILE_BYTES - 1)
  f:write("x")
  f:close()
  local atcap_text = util.read_file(atcap)
  check(
    "read_file: file at exactly MAX_FILE_BYTES read in full",
    atcap_text ~= nil and #atcap_text == util.MAX_FILE_BYTES,
    atcap_text and tostring(#atcap_text) or "nil"
  )

  -- A FIFO must be refused by the stat-type check BEFORE any open/read: an
  -- open on a writerless FIFO blocks forever, so if this hangs (CI timeout),
  -- the defense is gone.
  local fifo = rdir .. "/pipe.masm"
  vim.fn.system({ "mkfifo", fifo }) -- libuv has no mkfifo binding
  if vim.v.shell_error == 0 then
    local t0 = uv.hrtime()
    local fifo_text = util.read_file(fifo)
    local ms = (uv.hrtime() - t0) / 1e6
    check("read_file: FIFO refused", fifo_text == nil)
    check("read_file: FIFO refusal does not block", ms < 1000, ("%.1fms"):format(ms))

    -- A .masm-named symlink at a FIFO is just as refused (fs_stat follows
    -- the link, so the type check sees the FIFO).
    local fifolink = rdir .. "/pipelink.masm"
    assert(uv.fs_symlink(fifo, fifolink))
    check("read_file: symlink to a FIFO refused", util.read_file(fifolink) == nil)
  else
    print("PASS: read_file: FIFO refused (skipped: no mkfifo binary)")
  end

  -- Contract check, not a refusal: read_file stats with fs_stat (which
  -- follows links), so a symlink to a REGULAR file reads fine -- the walk's
  -- scandir-type check is what keeps symlinks out of the index (below).
  local real = rdir .. "/real.masm"
  write_file(real, "proc real_thing\n    push.1 drop\nend\n")
  local reallink = rdir .. "/reallink.masm"
  assert(uv.fs_symlink(real, reallink))
  check(
    "read_file: symlink to a regular file follows (contracted: stat-level check)",
    util.read_file(reallink) == util.read_file(real)
  )

  check("read_file: missing file refused", util.read_file(rdir .. "/nope.masm") == nil)
  check("read_file: directory refused", util.read_file(rdir) == nil)

  -------------------------------------------------------------------------
  -- project walk: symlinked directories are never descended
  -------------------------------------------------------------------------

  local outside = mktmp()
  write_file(outside .. "/planted.masm", "proc planted\n    push.1 drop\nend\n")
  local wroot = mktmp()
  write_file(wroot .. "/main.masm", "begin\n    push.1 drop\nend\n")
  vim.fn.mkdir(wroot .. "/real", "p")
  write_file(wroot .. "/real/inside.masm", "proc inside\n    push.1 drop\nend\n")
  assert(uv.fs_symlink(outside, wroot .. "/vendor", { dir = true }))

  project.clear_cache()
  local widx = with_notify(function()
    return project.build_index(wroot .. "/main.masm")
  end)
  check("walk: regular subdirectory indexed", widx.masm_set[wroot .. "/real/inside.masm"] == true)
  local through_link = false
  for _, p in ipairs(widx.masm) do
    if p:find("/vendor/", 1, true) or p == outside .. "/planted.masm" then
      through_link = true
    end
  end
  check("walk: symlinked directory not descended", not through_link, vim.inspect(widx.masm))

  -- A symlink-SPELLED root is different from a symlinked directory inside
  -- the tree: the root is canonicalized before walking (Neovim spells
  -- buffer names with symlinks resolved -- /var vs /private/var on macOS --
  -- and index paths must match that spelling for exact-name buffer lookups
  -- to work), so the index carries canonical paths, not the alias.
  local canon_root = mktmp()
  write_file(canon_root .. "/main.masm", "begin\n    push.1 drop\nend\n")
  write_file(canon_root .. "/helper.masm", "pub proc helped\n    push.1 drop\nend\n")
  local alias_root = canon_root .. "-alias"
  assert(uv.fs_symlink(canon_root, alias_root, { dir = true }))
  project.clear_cache()
  local cidx = with_notify(function()
    return project.build_index(alias_root .. "/main.masm") -- alias spelling in
  end)
  check(
    "walk: symlink-spelled root indexes canonical paths",
    cidx.masm_set[canon_root .. "/helper.masm"] == true
      and cidx.masm_set[alias_root .. "/helper.masm"] == nil,
    vim.inspect(cidx.masm)
  )
  vim.fn.delete(alias_root)

  -------------------------------------------------------------------------
  -- project walk: MAX_SCAN_DEPTH honored, truncation reported
  -------------------------------------------------------------------------

  local droot = mktmp()
  write_file(droot .. "/entry.masm", "begin\n    push.1 drop\nend\n")
  local chain = droot
  local depth12
  for i = 1, 13 do
    chain = chain .. "/d" .. i
    if i == 12 then
      depth12 = chain
    end
  end
  vim.fn.mkdir(chain, "p")
  write_file(depth12 .. "/ok.masm", "proc ok\n    push.1 drop\nend\n")
  write_file(chain .. "/deep.masm", "proc deep\n    push.1 drop\nend\n")

  project.clear_cache()
  local didx, dmsgs = with_notify(function()
    return project.build_index(droot .. "/entry.masm")
  end)
  check("walk: file at the depth cap indexed", didx.masm_set[depth12 .. "/ok.masm"] == true)
  check("walk: file beyond the depth cap not indexed", didx.masm_set[chain .. "/deep.masm"] == nil)
  check("walk: depth truncation reported, not silent", any_contains(dmsgs, "truncated"))

  -------------------------------------------------------------------------
  -- project walk: entry cap (via the _max_scan_entries test hook -- the
  -- real 200k cap is untestable with a sane file count)
  -------------------------------------------------------------------------

  local eroot = mktmp()
  for i = 1, 20 do
    write_file(("%s/f%02d.masm"):format(eroot, i), "proc p\n    push.1 drop\nend\n")
  end
  project._max_scan_entries = 10
  project.clear_cache()
  local eidx, emsgs = with_notify(function()
    return project.build_index(eroot .. "/f01.masm")
  end)
  project._max_scan_entries = nil
  check("walk: entry cap stops the scan", #eidx.masm < 20, "indexed " .. #eidx.masm)
  check("walk: entry truncation reported, not silent", any_contains(emsgs, "truncated"))

  -------------------------------------------------------------------------
  -- lib_root_file: untrusted manifest paths stay under the manifest dir
  -------------------------------------------------------------------------

  -- Positive control first: a well-formed manifest with a nested relative
  -- path yields a library, so the refusals below cannot pass vacuously.
  local groot = mktmp()
  write_file(groot .. "/main.masm", "begin\n    push.1 drop\nend\n")
  vim.fn.mkdir(groot .. "/lib/src", "p")
  write_file(
    groot .. "/lib/miden-project.toml",
    '[lib]\nnamespace = "good::lib"\npath = "src/lib.masm"\n'
  )
  write_file(groot .. "/lib/src/lib.masm", "pub proc fine\n    push.1 drop\nend\n")
  project.clear_cache()
  local gidx = with_notify(function()
    return project.build_index(groot .. "/main.masm")
  end)
  check(
    "manifest: well-formed relative path accepted (control)",
    #gidx.libs == 1 and gidx.libs[1].root_file == groot .. "/lib/src/lib.masm",
    vim.inspect(gidx.libs)
  )

  -- Absolute path: refused up front. The candidate is built as
  -- `dir .. "/" .. rel`, so an absolute rel also has to be mirrored UNDER the
  -- manifest dir for the refusal (and not a mere failed stat) to be what this
  -- asserts -- without the mirror, removing the check would go unnoticed.
  local abs_out = mktmp()
  local absrel = abs_out .. "/abs.masm"
  write_file(absrel, "pub proc stolen\n    push.1 drop\nend\n")
  local aroot = mktmp()
  write_file(aroot .. "/main.masm", "begin\n    push.1 drop\nend\n")
  vim.fn.mkdir(vim.fs.dirname(aroot .. "/lib" .. absrel), "p")
  write_file(aroot .. "/lib" .. absrel, "pub proc mirrored\n    push.1 drop\nend\n")
  write_file(
    aroot .. "/lib/miden-project.toml",
    '[lib]\nnamespace = "evil::abs"\npath = "' .. absrel .. '"\n'
  )
  project.clear_cache()
  local aidx = with_notify(function()
    return project.build_index(aroot .. "/main.masm")
  end)
  check("manifest: absolute lib path refused", #aidx.libs == 0, vim.inspect(aidx.libs))

  -- `..` component: refused even though the escape target exists.
  local proot = mktmp()
  write_file(proot .. "/main.masm", "begin\n    push.1 drop\nend\n")
  write_file(proot .. "/escape.masm", "pub proc stolen\n    push.1 drop\nend\n")
  vim.fn.mkdir(proot .. "/proj", "p")
  write_file(
    proot .. "/proj/miden-project.toml",
    '[lib]\nnamespace = "evil::dots"\npath = "../escape.masm"\n'
  )
  project.clear_cache()
  local pidx = with_notify(function()
    return project.build_index(proot .. "/main.masm")
  end)
  check("manifest: `..` lib path refused", #pidx.libs == 0, vim.inspect(pidx.libs))

  -- Symlinked path component: textually clean (`sub/root.masm`), but `sub`
  -- links outside the manifest dir; the realpath containment re-check must
  -- refuse it.
  local souter = mktmp()
  write_file(souter .. "/root.masm", "pub proc stolen\n    push.1 drop\nend\n")
  local sroot = mktmp()
  write_file(sroot .. "/main.masm", "begin\n    push.1 drop\nend\n")
  vim.fn.mkdir(sroot .. "/proj", "p")
  write_file(
    sroot .. "/proj/miden-project.toml",
    '[lib]\nnamespace = "evil::link"\npath = "sub/root.masm"\n'
  )
  assert(uv.fs_symlink(souter, sroot .. "/proj/sub", { dir = true }))
  project.clear_cache()
  local sidx = with_notify(function()
    return project.build_index(sroot .. "/main.masm")
  end)
  check("manifest: symlink-escaping lib path refused", #sidx.libs == 0, vim.inspect(sidx.libs))

  -------------------------------------------------------------------------
  -- references scan: in-flight cancellation, sync preemption, no stuck state
  -------------------------------------------------------------------------

  local place = helpers.placer(fixtures)

  local function qf_title()
    return vim.fn.getqflist({ title = 1 }).title
  end
  local function qf_tick()
    return vim.fn.getqflist({ changedtick = 1 }).changedtick
  end

  goto_mod.clear_cache()
  -- Shrink the scan slice so the fixture project needs many slices; without
  -- this the whole scan finishes inside its first 10ms slice and the
  -- cancellation paths are unreachable.
  goto_mod._scan_slice_ms = 0.05

  -- Async scan A (const MAX_VALUE), immediately preempted by async scan B
  -- (proc add_checked): exactly B's result set lands, A's never does.
  vim.fn.setqflist({}, " ", { title = "sentinel", items = {} })
  place("app/main.masm", "push.MAX_VALUE", 5)
  check("cancel: async references returns nothing immediately", goto_mod.references() == nil)
  check("cancel: first scan is genuinely in flight", qf_title() == "sentinel", qf_title())
  place("app/main.masm", "exec.math::add_checked", 12)
  goto_mod.references()
  local landed = vim.wait(5000, function()
    return qf_title() ~= "sentinel"
  end, 5)
  check("cancel: preempting scan completes", landed, qf_title())
  check(
    "cancel: winner is the second scan",
    qf_title():find("add_checked", 1, true) ~= nil,
    qf_title()
  )
  local tick = qf_tick()
  -- Condition-poll for the FAILURE event: a not-quite-cancelled scan A
  -- landing would bump the quickfix changedtick, ending the wait early with
  -- true. On a correct implementation the wait runs its full (generous but
  -- hard-bounded) timeout and returns false. This replaces a fixed 300ms
  -- pump, which a loaded CI box could starve past -- the corpse's scheduled
  -- slices would land after the window and the check passed vacuously.
  local corpse_landed = vim.wait(1500, function()
    return qf_tick() ~= tick
  end, 10)
  check(
    "cancel: cancelled scan never lands",
    not corpse_landed and qf_title():find("add_checked", 1, true) ~= nil
  )
  vim.cmd("cclose")

  -- Sync preemption: a sync scan cancels the in-flight async one, returns
  -- its own items, and the corpse never lands afterwards.
  place("app/main.masm", "push.MAX_VALUE", 5)
  goto_mod.references()
  place("app/main.masm", "exec.math::add_checked", 12)
  local sync_items = goto_mod.references({ sync = true })
  check("preempt: sync scan returns items", sync_items ~= nil and #sync_items > 0)
  check(
    "preempt: sync result lists the definition first",
    sync_items ~= nil and sync_items[1].text:find("proc add_checked", 1, true) ~= nil,
    sync_items and sync_items[1].text or "none"
  )
  check(
    "preempt: quickfix holds the sync scan",
    qf_title():find("add_checked", 1, true) ~= nil,
    qf_title()
  )
  local tick2 = qf_tick()
  -- Same failure-event poll as above: false means the corpse never landed
  -- within the generous window.
  local async_corpse_landed = vim.wait(1500, function()
    return qf_tick() ~= tick2
  end, 10)
  check("preempt: cancelled async scan never lands", not async_corpse_landed)
  vim.cmd("cclose")

  -- No stuck 'active scan' state: after both cancellations, a fresh async
  -- scan runs to completion.
  vim.fn.setqflist({}, " ", { title = "sentinel2", items = {} })
  place("app/main.masm", "push.MAX_VALUE", 5)
  goto_mod.references()
  landed = vim.wait(5000, function()
    return qf_title() ~= "sentinel2"
  end, 5)
  check(
    "cancel: no stuck state, fresh scan completes",
    landed and qf_title():find("MAX_VALUE", 1, true) ~= nil,
    qf_title()
  )
  vim.cmd("cclose")
  goto_mod._scan_slice_ms = nil

  -------------------------------------------------------------------------
  -- stack simulator budgets: MAX_SIM_OPS and MAX_CELLS
  -------------------------------------------------------------------------

  local vroot = mktmp()
  local vpath = vroot .. "/virtual.masm"
  local function proc_named(res, name)
    for _, p in ipairs(res and res.procs or {}) do
      if p.name == name then
        return p
      end
    end
  end

  -- A repeat nest unrolling to 10^6 iterations must bail on the instruction
  -- budget with a stated reason, promptly, instead of simulating it all.
  local t0 = uv.hrtime()
  local ops_res = stack.analyze_lines({
    "#! Invocation: exec",
    "#! Inputs:  []",
    "#! Outputs: []",
    "proc op_hog",
    "    repeat.100",
    "        repeat.100",
    "            repeat.100",
    "                add",
    "            end",
    "        end",
    "    end",
    "end",
  }, vpath)
  local ops_ms = (uv.hrtime() - t0) / 1e6
  local op_hog = proc_named(ops_res, "op_hog")
  check(
    "budget: repeat nest bails on the instruction budget",
    op_hog ~= nil
      and op_hog.bailed ~= nil
      and op_hog.bailed:find("instruction budget", 1, true) ~= nil,
    op_hog and tostring(op_hog.bailed) or "proc not scanned"
  )
  check("budget: bail is prompt, not a hang", ops_ms < 5000, ("%.0fms"):format(ops_ms))

  -- Growing past MAX_CELLS truncates the tracked window and poisons the
  -- state with a reason instead of modeling unbounded depth.
  local cell_lines = {
    "#! Invocation: call",
    "#! Inputs:  [pad(16)]",
    "#! Outputs: [pad(16)]",
    "proc cell_hog",
  }
  for _ = 1, 60 do
    cell_lines[#cell_lines + 1] = "    push.1"
  end
  cell_lines[#cell_lines + 1] = "end"
  local cell_res = stack.analyze_lines(cell_lines, vpath)
  local cell_hog = proc_named(cell_res, "cell_hog")
  check(
    "budget: deep stack poisons with the tracked-window reason",
    cell_hog ~= nil
      and cell_hog.bailed == nil
      and cell_hog.exit ~= nil
      and cell_hog.exit.poisoned ~= nil
      and cell_hog.exit.poisoned:find("tracked window", 1, true) ~= nil,
    cell_hog and tostring(cell_hog.exit and cell_hog.exit.poisoned) or "proc not scanned"
  )
  check(
    "budget: cell window truncated at the cap",
    cell_hog ~= nil and cell_hog.exit ~= nil and #cell_hog.exit.cells == 64,
    cell_hog and cell_hog.exit and tostring(#cell_hog.exit.cells) or "no exit"
  )
end)

-- Teardown: temp trees deleted, test hooks restored, whatever happened above.
for _, d in ipairs(tmp_dirs) do
  vim.fn.delete(d, "rf")
end
goto_mod._scan_slice_ms = nil
project._max_scan_entries = nil
if not run_ok then
  print("FAIL (error): " .. tostring(run_err))
  helpers.failed = helpers.failed + 1
end

helpers.finish()
