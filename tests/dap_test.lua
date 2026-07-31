-- Tests for the nvim-dap integration (masm.dap): launch argv construction,
-- port allocation and the spawn/readiness protocol, all without nvim-dap or
-- Miden binaries installed. Run with:
--   nvim --headless --clean -l tests/dap_test.lua
-- or `make test`.

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fs.dirname(vim.fn.fnamemodify(script, ":p"))
vim.opt.rtp:prepend(vim.fs.dirname(here))

local dap = require("masm.dap")
local uv = vim.uv or vim.loop

local failed = 0
local function check(desc, ok, detail)
  if ok then
    print("PASS: " .. desc)
  else
    print("FAIL: " .. desc .. (detail and (" -- " .. detail) or ""))
    failed = failed + 1
  end
end

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
local blocker = uv.new_tcp()
blocker:bind("127.0.0.1", 0)
blocker:listen(1, function() end)
local taken = blocker:getsockname().port
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

local function wait_result(spec_arg, timeout_ms)
  local result = "pending"
  dap._start_adapter(spec_arg, function(err)
    result = err or "ready"
  end, timeout_ms)
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

print(failed == 0 and "ALL PASS" or (failed .. " FAILURES"))
if failed > 0 then
  os.exit(1)
end
