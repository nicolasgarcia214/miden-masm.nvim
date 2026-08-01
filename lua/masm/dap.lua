-- Optional nvim-dap integration for the Miden VM debug adapter.
--
-- Ported from the Miden VS Code extension's debug provider, keeping its
-- semantics: `attach` connects to a DAP server the user started; `launch`
-- spawns one -- `miden-debug --start-debug-adapter` for standalone .masm /
-- .masp programs, `miden-client exec --start-debug-adapter` for transaction
-- scripts -- and waits for the server's readiness line on stdout/stderr
-- before connecting. A probe TCP connection would consume the single DAP
-- connection the server accepts, hence output-scanning, not port-polling.
--
-- Everything here is inert without nvim-dap: register() no-ops with a
-- reason (surfaced by :checkhealth masm), and no default configuration is
-- forced on users who define their own. Opt out entirely with
-- `vim.g.masm_no_dap = true`.
--
-- nvim-dap performs `${file}` / `${workspaceFolder}` substitution on
-- configuration values before the adapter callback runs, so launch configs
-- may use them exactly like in VS Code.

local M = {}

-- util.uv, not a fresh `vim.uv or vim.loop`: the alias is derived once in
-- masm.util so every module agrees (see stackview for the same rule).
local uv = require("masm.util").uv

local READY_PATTERN = "DAP server listening"
local READY_TIMEOUT_MS = 15000

---------------------------------------------------------------------------
-- Launch plumbing (UI-free, exercised directly by tests)
---------------------------------------------------------------------------

---@class masm.DapLaunchSpec what to spawn for a launch request
---@field cmd string backend executable (miden-debug / miden-client)
---@field args string[] argv, `--start-debug-adapter <addr>` included
---@field cwd string working directory the backend runs in

-- Maps a launch configuration to the backend argv. `addr` is "host:port".
---@param config table the nvim-dap launch configuration
---@param addr string
---@return masm.DapLaunchSpec? spec
---@return string? reason
function M._build_launch(config, addr)
  local cwd = config.cwd or vim.fn.getcwd()
  local runtime = config.runtime
  if not runtime then
    runtime = (config.program and "debugger") or (config.scriptPath and "client") or nil
  end
  if runtime == "debugger" then
    if type(config.program) ~= "string" or config.program == "" then
      return nil, "'program' is required to launch miden-debug"
    end
    local args = { "--start-debug-adapter", addr, "--working-dir", cwd }
    for _, opt in ipairs({
      { "--inputs", config.inputs },
      { "--entrypoint", config.entrypoint },
      { "--sysroot", config.sysroot },
    }) do
      if type(opt[2]) == "string" and opt[2] ~= "" then
        args[#args + 1] = opt[1]
        args[#args + 1] = opt[2]
      end
    end
    for _, flag_list in ipairs({
      { "--search-path", config.searchPath },
      { "--link-library", config.linkLibraries },
      { "--source-path-prefix", config.sourcePathPrefixes },
    }) do
      for _, v in ipairs(type(flag_list[2]) == "table" and flag_list[2] or {}) do
        args[#args + 1] = flag_list[1]
        args[#args + 1] = tostring(v)
      end
    end
    args[#args + 1] = config.program
    local extra = type(config.programArgs) == "table" and config.programArgs or {}
    if #extra > 0 then
      args[#args + 1] = "--"
      for _, v in ipairs(extra) do
        args[#args + 1] = tostring(v)
      end
    end
    return { cmd = config.midenDebugPath or "miden-debug", args = args, cwd = cwd }
  end
  if runtime == "client" then
    if type(config.scriptPath) ~= "string" or config.scriptPath == "" then
      return nil, "'scriptPath' is required to launch miden-client"
    end
    local args = { "exec", "--script-path", config.scriptPath, "--start-debug-adapter", addr }
    if type(config.accountId) == "string" and config.accountId ~= "" then
      args[#args + 1] = "--account"
      args[#args + 1] = config.accountId
    end
    return { cmd = config.midenClientPath or "miden-client", args = args, cwd = cwd }
  end
  return nil, "set 'program' (miden-debug) or 'scriptPath' (miden-client) in the launch config"
end

-- A local port the DAP server can bind: the preferred one when free, else a
-- kernel-assigned free port. The listener closes before the backend starts,
-- which is a small race by design -- the same one every "find a free port"
-- launcher accepts.
---@param host string
---@param preferred integer
---@return integer? port nil when nothing can be bound on `host`
function M._free_port(host, preferred)
  local function try(port)
    -- new_tcp can fail (fd exhaustion); a launch attempt in that state
    -- should report "no port", not crash on a nil handle.
    local tcp = uv.new_tcp()
    if not tcp then
      return nil
    end
    local ok = tcp:bind(host, port) == 0
    local bound = ok and tcp:getsockname() or nil
    tcp:close()
    return ok and bound and bound.port or nil
  end
  return try(preferred) or try(0)
end

-- Spawned backend processes, keyed by the local port their DAP server was
-- asked to listen on (nvim-dap supports concurrent sessions, and every
-- launch gets its own free port): a session's end must kill ITS backend,
-- not whichever launch happened last. Exposed as M._children for tests.
local children = {}
M._children = children

-- The port for a NEW launch: like _free_port, but never the key of a live
-- child. Binding the preferred port succeeds in the window before an
-- in-flight sibling's backend binds its socket, and reusing that sibling's
-- key would make _start_adapter's kill_child tear down a healthy session --
-- the replace-on-relaunch semantics are for RE-launches of one endpoint,
-- not for two launches colliding on the default port. (A live child whose
-- explicit port you want back is released by terminating its session.)
---@param host string
---@param preferred integer
---@return integer? port nil when nothing safe can be bound on `host`
function M._launch_port(host, preferred)
  if children[preferred] then
    preferred = 0
  end
  local port = M._free_port(host, preferred)
  -- A kernel-assigned port can in principle still land on a live child's
  -- not-yet-bound key; refusing the launch is the safe answer to that
  -- vanishing-odds race, and the caller reports it like port exhaustion.
  if port and children[port] then
    return nil
  end
  return port
end

-- Output chunks retained for error diagnosis, keyed like `children`: with
-- concurrent sessions a shared buffer let a second launch wipe the first's
-- captured output and interleave both backends' writes. Entries are NOT
-- cleared in kill_child -- error paths kill the child first and read the
-- output after -- so they persist until a re-launch on the same key; each
-- is capped BY BYTES (a chunk cap left up to chunk-size * count retained,
-- ~16MB per key for 64KB pipe reads) because the pipes stay open for the
-- child's whole lifetime (below), and a chatty backend must not grow it
-- without bound. The TAIL is what error reports show.
local outputs = {}
local MAX_OUTPUT_BYTES = 64 * 1024

-- Captured output for one backend, by the key its launch used. Tests hook
-- this; the adapter's error formatting reads it by port.
---@param key any port number, or the spec table for keyless callers
---@return string[]? chunks raw output chunks, oldest first
function M._output(key)
  return outputs[key]
end

local function close_pipes(c)
  for _, pipe in ipairs({ c.stdout, c.stderr }) do
    if pipe and not pipe:is_closing() then
      pipe:close()
    end
  end
end

local function kill_child(key)
  local c = children[key]
  if not c then
    return
  end
  children[key] = nil
  close_pipes(c)
  if c.handle and not c.handle:is_closing() then
    c.handle:kill("sigterm")
  end
end

local function kill_all()
  for key in pairs(children) do
    kill_child(key)
  end
end

-- Kills every backend when Neovim exits. nvim-dap's terminated/exited/
-- disconnect listeners handle normal session teardown, but quitting the
-- editor mid-session emits none of them -- without this hook the spawned
-- miden-debug/miden-client would outlive Neovim as an orphan. Registered
-- once, and only when the first child actually spawns (not at module
-- load): merely requiring this module must stay side-effect free.
local exit_hook_installed = false
local function ensure_exit_hook()
  if exit_hook_installed then
    return
  end
  exit_hook_installed = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("masm_dap_exit", { clear = true }),
    callback = kill_all,
  })
end

-- Spawns the backend and calls on_done(err) exactly once: nil when the
-- readiness line appeared, a reason when the process errored, exited early
-- or timed out. Output is retained per key (M._output) for diagnosis.
--
-- The stdout/stderr pipes are NOT closed at readiness: they stay open and
-- drained until the process exits. Closing them at the handshake left the
-- still-running backend with dead write ends, and Rust binaries
-- (miden-debug is one) panic on the resulting EPIPE from println! -- one
-- log line after the handshake would kill the debug session mid-flight.
---@param spec masm.DapLaunchSpec
---@param on_done fun(err: string?) called exactly once, on the main loop
---@param timeout_ms integer? defaults to READY_TIMEOUT_MS
---@param key any? children/outputs key (the port); defaults to `spec`
function M._start_adapter(spec, on_done, timeout_ms, key)
  key = key or spec -- callers without an endpoint get a private key
  kill_child(key) -- a re-launch on the same endpoint replaces its backend
  -- A fresh table per launch, closed over below: a replaced backend's still-
  -- draining pipes must not write into its successor's buffer.
  local output = {}
  outputs[key] = output
  local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
  local timer = uv.new_timer()
  -- Any of these can fail under fd exhaustion; report it like a failed
  -- spawn (the closures below may then assume non-nil handles).
  if not (stdout and stderr and timer) then
    -- Explicit per-handle closes: an ipairs over { stdout, stderr, timer }
    -- would stop at the first nil hole and leak the handles after it.
    if stdout then
      stdout:close()
    end
    if stderr then
      stderr:close()
    end
    if timer then
      timer:close()
    end
    vim.schedule(function()
      on_done("could not allocate pipes for " .. spec.cmd .. " (out of file descriptors?)")
    end)
    return
  end
  local done = false
  local function finish(err)
    if done then
      return
    end
    done = true
    timer:stop()
    timer:close()
    if err then
      kill_child(key) -- a half-started backend is useless; don't leak it
    end
    vim.schedule(function()
      on_done(err)
    end)
  end

  local handle
  handle = uv.spawn(spec.cmd, {
    args = spec.args,
    cwd = spec.cwd,
    stdio = { nil, stdout, stderr },
  }, function(code)
    local c = children[key]
    if c and c.handle == handle then
      children[key] = nil
      close_pipes(c)
    end
    if handle then
      handle:close()
    end
    finish(("%s exited (code %s) before the DAP server was ready"):format(spec.cmd, code))
  end)
  if not handle then
    timer:close()
    stdout:close()
    stderr:close()
    vim.schedule(function()
      on_done(("could not start %s (not installed?)"):format(spec.cmd))
    end)
    return
  end
  children[key] = { handle = handle, stdout = stdout, stderr = stderr }
  ensure_exit_hook()

  local output_bytes = 0
  local function on_read(_, data)
    if data then
      output[#output + 1] = data
      output_bytes = output_bytes + #data
      -- Keep the newest chunk even when it alone exceeds the cap: the tail
      -- is what error reports show.
      while output_bytes > MAX_OUTPUT_BYTES and #output > 1 do
        output_bytes = output_bytes - #output[1]
        table.remove(output, 1)
      end
      if not done and data:find(READY_PATTERN, 1, true) then
        finish(nil)
      end
    end
  end
  stdout:read_start(on_read)
  stderr:read_start(on_read)
  timer:start(timeout_ms or READY_TIMEOUT_MS, 0, function()
    finish(
      ("%s did not report readiness within %ds"):format(
        spec.cmd,
        (timeout_ms or READY_TIMEOUT_MS) / 1000
      )
    )
  end)
end

---------------------------------------------------------------------------
-- nvim-dap registration
---------------------------------------------------------------------------

local registered = false

-- The most recent `miden/uiState` push (cycle, operand stack, call stack)
-- from the adapter; the VS Code extension renders this in a tree view, here
-- :MasmDapState shows it in a float.
M._ui_state = nil

-- Failure paths resume nvim-dap's suspended coroutine with nil (which its
-- adapter validation rejects and aborts on) instead of never calling
-- `callback` -- an uncalled callback leaves the session start suspended
-- forever. Our specific reason is notified first.
local function adapter(callback, config)
  local host = config.host or "127.0.0.1"
  if config.request == "attach" then
    callback({ type = "server", host = host, port = config.port or 4711 })
    return
  end
  local port = M._launch_port(host, config.port or 4711)
  if not port then
    vim.notify("masm dap: could not allocate a local port on " .. host, vim.log.levels.ERROR)
    callback(nil)
    return
  end
  local spec, reason = M._build_launch(config, host .. ":" .. port)
  if not spec then
    vim.notify("masm dap: " .. reason, vim.log.levels.ERROR)
    callback(nil)
    return
  end
  M._start_adapter(spec, function(err)
    if err then
      local tail = table.concat(M._output(port) or {}):sub(-800)
      vim.notify("masm dap: " .. err .. (tail ~= "" and ("\n" .. tail) or ""), vim.log.levels.ERROR)
      callback(nil)
      return
    end
    callback({ type = "server", host = host, port = port })
  end, nil, port)
end

local function render_state(state)
  local lines = { "Cycle: " .. tostring(state.cycle) }
  local stack = state.current_stack or {}
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("Operand stack (%d):"):format(#stack)
  for i, v in ipairs(stack) do
    lines[#lines + 1] = ("  [%2d] %s"):format(i - 1, tostring(v))
  end
  local frames = state.callstack or {}
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("Call stack (%d):"):format(#frames)
  for _, fr in ipairs(frames) do
    local loc = fr.source_path and (fr.source_path .. ":" .. tostring(fr.line)) or ""
    lines[#lines + 1] = ("  %s  %s"):format(fr.name or "?", loc)
  end
  return lines
end

local function show_state()
  if not M._ui_state then
    vim.notify("masm dap: no VM state (is a miden debug session stopped?)", vim.log.levels.WARN)
    return
  end
  local lines = render_state(M._ui_state)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  local width = 1
  for _, l in ipairs(lines) do
    -- Display width, not byte length: operand values can be multibyte.
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(width, 80),
    height = math.min(#lines, 24),
    style = "minimal",
    border = "rounded",
  })
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, nowait = true })
  -- Grouped (and cleared per show): only one state float exists at a time,
  -- and a stray global autocmd per invocation would accumulate.
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter" }, {
    group = vim.api.nvim_create_augroup("masm_dap_state", { clear = true }),
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })
end

-- Registers the adapter, default configurations, the miden/uiState listener
-- and :MasmDapState with nvim-dap. Idempotent; safe to call from every masm
-- buffer.
---@return boolean ok
---@return string? reason why registration stayed off (:checkhealth masm)
function M.register()
  if registered then
    return true
  end
  local ok, dap = pcall(require, "dap")
  if not ok then
    return false, "nvim-dap is not installed"
  end
  registered = true

  dap.adapters.miden = adapter
  -- Defaults only: a user-defined dap.configurations.masm wins untouched.
  if not dap.configurations.masm then
    dap.configurations.masm = {
      {
        type = "miden",
        request = "launch",
        name = "Debug current file (miden-debug)",
        program = "${file}",
      },
      {
        type = "miden",
        request = "launch",
        name = "Debug transaction script (miden-client)",
        scriptPath = "${file}",
      },
      {
        type = "miden",
        request = "attach",
        name = "Attach to Miden DAP server",
        host = "127.0.0.1",
        port = 4711,
      },
    }
  end

  dap.listeners.after["event_miden/uiState"]["masm"] = function(_, body)
    M._ui_state = body
  end
  -- Kill only the ENDING session's backend (looked up by its adapter port):
  -- concurrent sessions each own one, and killing "the" child tore down
  -- whichever session launched last.
  local function cleanup(session)
    M._ui_state = nil
    -- Only LAUNCH sessions own a backend. An attach session's target on
    -- that port can be a sibling launch's live backend (nothing else could
    -- have bound the port our child owns), and its disconnect must not
    -- tear that session down.
    local cfg = session and session.config
    if not (cfg and cfg.request == "launch") then
      return
    end
    local adapter_cfg = session.adapter
    local port = adapter_cfg and tonumber(adapter_cfg.port)
    if port then
      kill_child(port)
    end
  end
  dap.listeners.after.event_terminated["masm"] = cleanup
  dap.listeners.after.event_exited["masm"] = cleanup
  dap.listeners.after.disconnect["masm"] = cleanup

  vim.api.nvim_create_user_command("MasmDapState", show_state, {
    desc = "Show the Miden VM state (cycle, operand stack, call stack) from the debug adapter",
  })
  return true
end

-- Exposed for tests and health. _kill(key) kills one backend, _kill() all.
M._render_state = render_state
---@param key any? port of the backend to kill; nil kills every backend
M._kill = function(key)
  if key ~= nil then
    kill_child(key)
  else
    kill_all()
  end
end

return M
