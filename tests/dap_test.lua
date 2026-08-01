-- Tests for the nvim-dap integration (masm.dap): launch argv construction,
-- port allocation and the spawn/readiness protocol, all without nvim-dap or
-- Miden binaries installed. Run with:
--   nvim --headless --clean -l tests/dap_test.lua
-- or `make test`.

local helpers = dofile(
  vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")) .. "/helpers.lua"
)
local check = helpers.check

local dap = require("masm.dap")
local uv = vim.uv or vim.loop

---------------------------------------------------------------------------
-- _build_launch
---------------------------------------------------------------------------

local spec, reason = dap._build_launch({
  program = "/w/target/miden/app.masp",
  cwd = "/w",
  inputs = "/w/inputs.toml",
  entrypoint = "app::main",
  searchPath = { "/w/lib" },
  linkLibraries = { "std" },
  sourcePathPrefixes = { "/w/src" },
  programArgs = { 1, 2 },
}, "127.0.0.1:4711")
check("launch: miden-debug argv", spec ~= nil and spec.cmd == "miden-debug", tostring(reason))
check(
  "launch: full debugger argv shape",
  spec ~= nil
    and table.concat(spec.args, " ")
      == "--start-debug-adapter 127.0.0.1:4711 --working-dir /w --inputs /w/inputs.toml" .. " --entrypoint app::main --search-path /w/lib --link-library std" .. " --source-path-prefix /w/src /w/target/miden/app.masp -- 1 2",
  spec and table.concat(spec.args, " ")
)

spec = dap._build_launch({ scriptPath = "/w/tx.masm", accountId = "0xabc", cwd = "/w" }, "h:1")
check("launch: miden-client argv", spec ~= nil and spec.cmd == "miden-client")
check(
  "launch: client argv shape",
  spec ~= nil
    and table.concat(spec.args, " ")
      == "exec --script-path /w/tx.masm --start-debug-adapter h:1 --account 0xabc",
  spec and table.concat(spec.args, " ")
)

spec = dap._build_launch({ runtime = "debugger" }, "h:1")
check("launch: missing program refused", spec == nil)
spec, reason = dap._build_launch({}, "h:1")
check("launch: no runtime hint refused with reason", spec == nil and reason ~= nil, reason)
spec = dap._build_launch({ program = "/f.masm", midenDebugPath = "/opt/md" }, "h:1")
check("launch: binary path override", spec ~= nil and spec.cmd == "/opt/md")

---------------------------------------------------------------------------
-- _free_port
---------------------------------------------------------------------------

local port = dap._free_port("127.0.0.1", 0)
check("port: allocates a free port", type(port) == "number" and port > 0, tostring(port))

-- Occupy a port; asking for it must fall back to a different free one.
-- assert()s: handle allocation only fails on fd exhaustion, which should
-- kill the suite loudly, and the narrowing keeps the type checker honest.
local blocker = assert(uv.new_tcp())
blocker:bind("127.0.0.1", 0)
blocker:listen(1, function() end)
local taken = assert(blocker:getsockname()).port
local fallback = dap._free_port("127.0.0.1", taken)
blocker:close()
check(
  "port: busy preferred port falls back",
  type(fallback) == "number" and fallback ~= taken,
  ("taken %s got %s"):format(taken, tostring(fallback))
)

---------------------------------------------------------------------------
-- _start_adapter: readiness, early exit, timeout, missing binary
---------------------------------------------------------------------------

local function wait_result(spec_arg, timeout_ms, key)
  local result = "pending"
  dap._start_adapter(spec_arg, function(err)
    result = err or "ready"
  end, timeout_ms, key)
  vim.wait(5000, function()
    return result ~= "pending"
  end, 10)
  return result
end

local res = wait_result({
  cmd = "sh",
  args = { "-c", 'echo "DAP server listening on 127.0.0.1:1"; sleep 5' },
})
check("adapter: readiness line detected", res == "ready", tostring(res))
dap._kill()

-- Pipes must stay open and drained past readiness: closing them at the
-- handshake gave the backend dead write ends, and a single post-handshake
-- log line (Rust panics on println! EPIPE) killed live sessions.
res = wait_result({
  cmd = "sh",
  args = { "-c", 'echo "DAP server listening"; sleep 0.3; echo post-ready-output; sleep 5' },
}, nil, 1000)
check("adapter: ready before post-ready output", res == "ready", tostring(res))
local drained = vim.wait(3000, function()
  return table.concat(dap._output(1000) or {}):find("post-ready-output", 1, true) ~= nil
end, 50)
check("adapter: pipes drained after readiness", drained)
dap._kill()

-- Concurrent backends: keyed by port, killing one leaves the other running.
local ready_spec = { cmd = "sh", args = { "-c", 'echo "DAP server listening"; sleep 5' } }
check("adapter: first keyed backend ready", wait_result(ready_spec, nil, 1001) == "ready")
check("adapter: second keyed backend ready", wait_result(ready_spec, nil, 1002) == "ready")
check("adapter: both children tracked", dap._children[1001] ~= nil and dap._children[1002] ~= nil)
dap._kill(1001)
check(
  "adapter: killing one child spares the other",
  dap._children[1001] == nil and dap._children[1002] ~= nil
)
dap._kill()
check("adapter: kill-all clears the table", next(dap._children) == nil)

-- A NEW launch must never take a live child's key: binding the preferred
-- port can succeed in the window before that child's backend binds its
-- socket, and reusing the key would kill the sibling session's backend
-- (replace-on-relaunch is for RE-launches of one endpoint only).
check("launch port: sibling backend ready", wait_result(ready_spec, nil, 3001) == "ready")
local lport = dap._launch_port("127.0.0.1", 3001)
check(
  "launch port: live child's key avoided",
  type(lport) == "number" and lport ~= 3001,
  tostring(lport)
)
check("launch port: sibling backend untouched", dap._children[3001] ~= nil)
dap._kill()

-- Quitting Neovim without nvim-dap's terminated/exited/disconnect events
-- must not orphan backends: the first spawn registers a VimLeavePre hook
-- that kills them all. Fired here via doautocmd (headless nvim -l never
-- leaves through VimLeavePre itself).
check(
  "adapter: exit hook registered once a child spawned",
  #vim.api.nvim_get_autocmds({ group = "masm_dap_exit", event = "VimLeavePre" }) == 1
)
check("adapter: exit-hook backend ready", wait_result(ready_spec, nil, 1003) == "ready")
vim.api.nvim_exec_autocmds("VimLeavePre", {})
check("adapter: exit hook kills every child", next(dap._children) == nil)

-- Concurrent captured output: diagnostics are keyed per backend like the
-- children table -- a shared buffer let the second launch wipe the first
-- session's captured output (the evidence for a failed launch) and both
-- backends interleave writes into it.
res = wait_result({
  cmd = "sh",
  args = { "-c", 'echo "DAP server listening"; echo output-of-alpha; sleep 5' },
}, nil, 2001)
check("output: first keyed backend ready", res == "ready", tostring(res))
res = wait_result({
  cmd = "sh",
  args = { "-c", 'echo "DAP server listening"; echo output-of-beta; sleep 5' },
}, nil, 2002)
check("output: second keyed backend ready", res == "ready", tostring(res))
local both_captured = vim.wait(3000, function()
  return table.concat(dap._output(2001) or {}):find("output-of-alpha", 1, true) ~= nil
    and table.concat(dap._output(2002) or {}):find("output-of-beta", 1, true) ~= nil
end, 50)
local alpha = table.concat(dap._output(2001) or {})
local beta = table.concat(dap._output(2002) or {})
check("output: each session captures its own backend", both_captured, alpha .. " / " .. beta)
check(
  "output: second launch does not clear the first",
  alpha:find("DAP server listening", 1, true) ~= nil
    and alpha:find("output-of-alpha", 1, true) ~= nil,
  alpha
)
check(
  "output: no cross-session interleaving",
  alpha:find("output-of-beta", 1, true) == nil and beta:find("output-of-alpha", 1, true) == nil,
  alpha .. " / " .. beta
)
-- The companion property (already fixed): ending one session kills only
-- its own child.
dap._kill(2001)
check(
  "output: killing one session's child spares the other",
  dap._children[2001] == nil and dap._children[2002] ~= nil
)
dap._kill()

res = wait_result({ cmd = "sh", args = { "-c", "echo nope; exit 3" } })
check(
  "adapter: early exit reported",
  type(res) == "string" and res:find("exited", 1, true) ~= nil,
  tostring(res)
)

res = wait_result({ cmd = "sh", args = { "-c", "sleep 5" } }, 300)
check(
  "adapter: timeout reported and process killed",
  type(res) == "string" and res:find("readiness", 1, true) ~= nil,
  tostring(res)
)

res = wait_result({ cmd = "definitely-not-a-real-binary-9x", args = {} })
check(
  "adapter: missing binary reported",
  type(res) == "string" and res:find("not installed", 1, true) ~= nil,
  tostring(res)
)

---------------------------------------------------------------------------
-- register() without nvim-dap; state rendering
---------------------------------------------------------------------------

local ok, why = dap.register()
check("register: inert without nvim-dap", ok == false and why ~= nil, tostring(why))

-- With nvim-dap present (stubbed to its registration surface), register()
-- wires the adapter, default configurations, listeners and the command.
local stub = {
  adapters = {},
  configurations = {},
  listeners = {
    after = setmetatable({}, {
      __index = function(t, k)
        t[k] = {}
        return t[k]
      end,
    }),
  },
}
-- Redefining a loader the runtime defs already type is the point of a stub.
---@diagnostic disable-next-line: duplicate-set-field
package.preload["dap"] = function()
  return stub
end
ok = dap.register()
check("register: succeeds with nvim-dap", ok == true)
check("register: adapter installed", type(stub.adapters.miden) == "function")
check("register: three default configurations", #stub.configurations.masm == 3)
check("register: uiState listener installed", stub.listeners.after["event_miden/uiState"] ~= nil)
check("register: :MasmDapState defined", vim.fn.exists(":MasmDapState") == 2)
check("register: idempotent", dap.register() == true and #stub.configurations.masm == 3)

-- User-defined configurations must win: re-register never overwrites.
stub.configurations.masm = { { name = "mine" } }
package.loaded["masm.dap"] = nil
local dap2 = require("masm.dap")
dap2.register()
check("register: user configurations untouched", stub.configurations.masm[1].name == "mine")

-- The adapter function: attach connects straight to the given endpoint.
local attach_result
stub.adapters.miden(function(cfg)
  attach_result = cfg
end, { request = "attach", host = "10.0.0.1", port = 9999 })
check(
  "adapter fn: attach passes endpoint through",
  attach_result ~= nil
    and attach_result.type == "server"
    and attach_result.host == "10.0.0.1"
    and attach_result.port == 9999,
  vim.inspect(attach_result)
)

-- The uiState listener feeds :MasmDapState.
stub.listeners.after["event_miden/uiState"]["masm"](nil, { cycle = 7, current_stack = {} })
check("adapter fn: uiState captured", dap2._ui_state ~= nil and dap2._ui_state.cycle == 7)

-- Launch-setup failure must resume nvim-dap's suspended coroutine with nil
-- (its adapter validation aborts on it), never leave the callback uncalled.
local failed_cb, failed_val = false, "sentinel"
stub.adapters.miden(function(cfg)
  failed_cb, failed_val = true, cfg
end, { request = "launch" })
check("adapter fn: setup failure resumes callback with nil", failed_cb and failed_val == nil)

-- Session cleanup: only LAUNCH sessions own a backend. An attach session
-- can be attached to a sibling launch's backend on that very port, so its
-- disconnect must leave the child alone; the launch session's own end must
-- still kill it.
local launch_res = "pending"
dap2._start_adapter(ready_spec, function(err)
  launch_res = err or "ready"
end, nil, 4712)
vim.wait(5000, function()
  return launch_res ~= "pending"
end, 10)
check("cleanup: launch backend ready", launch_res == "ready", tostring(launch_res))
local cleanup = stub.listeners.after.event_terminated["masm"]
cleanup({ config = { request = "attach" }, adapter = { port = 4712 } })
check("cleanup: attach disconnect spares the launch backend", dap2._children[4712] ~= nil)
cleanup({ config = { request = "launch" }, adapter = { port = 4712 } })
check("cleanup: launch termination kills its backend", dap2._children[4712] == nil)

local lines = dap._render_state({
  cycle = 42,
  current_stack = { 7, 3 },
  callstack = {
    { name = "increment", source_path = "script.masm", line = 21 },
    { name = "main" },
  },
})
check("render: cycle line", lines[1] == "Cycle: 42")
local text = table.concat(lines, "\n")
check("render: operand stack entries", text:find("[ 0] 7", 1, true) ~= nil, text)
check("render: frame with location", text:find("increment  script.masm:21", 1, true) ~= nil, text)
check("render: frame without location survives", text:find("main", 1, true) ~= nil)

helpers.finish()
