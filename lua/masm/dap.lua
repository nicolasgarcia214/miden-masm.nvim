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

local uv = vim.uv or vim.loop

local READY_PATTERN = "DAP server listening"
local READY_TIMEOUT_MS = 15000

---------------------------------------------------------------------------
-- Launch plumbing (UI-free, exercised directly by tests)
---------------------------------------------------------------------------

-- Maps a launch configuration to the backend argv. Returns
-- { cmd, args, cwd } or nil and a reason. `addr` is "host:port".
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
function M._free_port(host, preferred)
  local function try(port)
    local tcp = uv.new_tcp()
    local ok = tcp:bind(host, port) == 0
    local bound = ok and tcp:getsockname() or nil
    tcp:close()
    return ok and bound and bound.port or nil
  end
  return try(preferred) or try(0)
end

-- The spawned backend process, kept so a new launch (or session end)
-- replaces rather than leaks it.
local child

local function kill_child()
  if child then
    child:kill("sigterm")
    child = nil
  end
end

-- Spawns the backend and calls on_done(err) exactly once: nil when the
-- readiness line appeared, a reason when the process errored, exited early
-- or timed out. Output is retained in M._last_output for diagnosis.
function M._start_adapter(spec, on_done, timeout_ms)
  kill_child()
  M._last_output = {}
  local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
  local timer = uv.new_timer()
  local done = false
  local function finish(err)
    if done then
      return
    end
    done = true
    timer:stop()
    timer:close()
    stdout:close()
    stderr:close()
    if err then
      kill_child() -- a half-started backend is useless; don't leak it
    end
    vim.schedule(function()
      on_done(err)
    end)
  end

  local handle
  handle, _ = uv.spawn(spec.cmd, {
    args = spec.args,
    cwd = spec.cwd,
    stdio = { nil, stdout, stderr },
  }, function(code)
    if handle then
      handle:close()
    end
    if child == handle then
      child = nil
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
  child = handle

  local function on_read(_, data)
    if data then
      M._last_output[#M._last_output + 1] = data
      if data:find(READY_PATTERN, 1, true) then
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
  local port = M._free_port(host, config.port or 4711)
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
      local tail = table.concat(M._last_output or {}):sub(-800)
      vim.notify("masm dap: " .. err .. (tail ~= "" and ("\n" .. tail) or ""), vim.log.levels.ERROR)
      callback(nil)
      return
    end
    callback({ type = "server", host = host, port = port })
  end)
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
    width = math.max(width, #l)
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
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter" }, {
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
-- buffer. Returns true, or false and a reason (shown by :checkhealth masm).
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
  local function cleanup()
    M._ui_state = nil
    kill_child()
  end
  dap.listeners.after.event_terminated["masm"] = cleanup
  dap.listeners.after.event_exited["masm"] = cleanup
  dap.listeners.after.disconnect["masm"] = cleanup

  vim.api.nvim_create_user_command("MasmDapState", show_state, {
    desc = "Show the Miden VM state (cycle, operand stack, call stack) from the debug adapter",
  })
  return true
end

-- Exposed for tests and health.
M._render_state = render_state
M._kill = kill_child

return M
