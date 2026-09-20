-- 托管 Godot 进程：启动（uv.spawn）、等待 LSP 端口、优雅关闭 / 强杀。
--
-- 这里刻意不用 vim.system：
--   * 它硬编码 hide = true，libuv 会据此设置 STARTF_USESHOWWINDOW + SW_HIDE，
--     Godot 的编辑器窗口会以隐藏状态创建（看不见，而且没有 MainWindowHandle，
--     导致优雅关闭直接失败）。
--   * 它不暴露 process handle，没法 unref。
local uv = vim.uv

local config = require("godot-instance.config").options
local state = require("godot-instance.state")
local util = require("godot-instance.util")
local records = require("godot-instance.records")
local windows = require("godot-instance.windows")
local lsp = require("godot-instance.lsp")

local HOST = util.HOST
local IS_WINDOWS = util.IS_WINDOWS
local close_handle = util.close_handle
local now_ms = util.now_ms
local notify = util.notify
local pid_alive = util.pid_alive
local process_running = util.process_running
local script_path = util.script_path
local record_instance = records.record_instance
local forget_instance = records.forget_instance
local capture_foreground_window = windows.capture_foreground_window
local guard_focus_after_godot_launch = windows.guard_focus_after_godot_launch
local disable_lsp = lsp.disable_lsp
local enable_lsp = lsp.enable_lsp

local M = {}

local function port_is_open(port, callback)
    local tcp = uv.new_tcp()
    if not tcp then
        vim.schedule(function()
            callback(false)
        end)
        return
    end

    local finished = false

    local function finish(open)
        if finished then
            return
        end

        finished = true
        close_handle(tcp)
        vim.schedule(function()
            callback(open)
        end)
    end

    local ok, request = pcall(function()
        return tcp:connect(HOST, port, function(err)
            finish(err == nil)
        end)
    end)

    if not ok or request == nil then
        finish(false)
    end
end

local function wait_for_port(port, expected_open, timeout_ms, generation, callback)
    local deadline = now_ms() + timeout_ms

    local function check()
        if generation ~= state.generation then
            return
        end

        port_is_open(port, function(open)
            if generation ~= state.generation then
                return
            end

            if open == expected_open then
                callback(true)
                return
            end

            if now_ms() >= deadline then
                callback(false)
                return
            end

            vim.defer_fn(check, math.max(tonumber(config.lsp_port_poll_ms) or 25, 10))
        end)
    end

    check()
end
-- 当前项目“托管的”Godot 的 pid。
-- 复用外部编辑器（你自己开的那个）时返回 nil —— 那个进程不归我们管。
local function managed_pid()
    if process_running(state.godot_process) then
        return tonumber(state.godot_process_pid)
    end

    if state.adopted and state.adopted.source == "managed" then
        local pid = tonumber(state.adopted.pid)
        if pid_alive(pid) then
            return pid
        end
    end

    return nil
end

local function managed_alive()
    return managed_pid() ~= nil
end

local function instance_source_label()
    if state.adopted then
        if state.adopted.source == "external" then
            return "external editor (reused)"
        end

        return string.format("managed (reused, pid %s)", tostring(state.adopted.pid or "?"))
    end

    if process_running(state.godot_process) then
        return "managed (launched by this Nvim)"
    end

    return "-"
end

local windows_focus_api_state = {
    initialized = false,
    ffi = nil,
    user32 = nil,
    kernel32 = nil,
}

local function wait_for_pid_exit(pid, timeout_ms, generation, callback)
    local deadline = now_ms() + timeout_ms

    local function check()
        if generation ~= state.generation then
            return
        end

        if not pid_alive(pid) then
            callback(true)
            return
        end

        if now_ms() >= deadline then
            callback(false)
            return
        end

        vim.defer_fn(check, 150)
    end

    check()
end
-- 关闭助手随插件分发（scripts/godot-close.ps1），用 runtime 查找定位，
-- 所以插件放在哪个目录都能用。
local function close_helper_path()
    return script_path("godot-close.ps1")
end

local function request_normal_close(pid, callback)
    if not pid_alive(pid) then
        callback(true)
        return
    end

    if not IS_WINDOWS then
        callback(false, "normal window close helper is only configured for Windows")
        return
    end

    local helper = close_helper_path()
    if vim.fn.filereadable(helper) ~= 1 then
        callback(false, "missing helper: " .. helper)
        return
    end

    local ok, system_or_error = pcall(vim.system, {
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        helper,
        "-ProcessId",
        tostring(pid),
    }, {
        text = true,
    }, function(result)
        vim.schedule(function()
            if not pid_alive(pid) then
                callback(true)
                return
            end

            if result.code ~= 0 then
                local detail = result.stderr or result.stdout or ""
                callback(false, detail ~= "" and detail or ("close helper exited with code " .. result.code))
                return
            end

            callback(true)
        end)
    end)

    if not ok then
        callback(false, tostring(system_or_error))
    end
end

local function force_kill_pid(pid)
    if not pid_alive(pid) then
        return
    end

    pcall(uv.kill, pid, "sigterm")
end

local function close_managed_godot(opts, callback)
    opts = opts or {}

    -- opts.pid 用于“关掉切换之前的那个实例”，此时 state 里已经是新实例了。
    local pid = tonumber(opts.pid) or managed_pid()
    if not pid then
        state.godot_process = nil
        state.godot_process_pid = nil
        callback(true)
        return
    end

    local generation = state.generation

    local function finish()
        if process_running(state.godot_process) and tonumber(state.godot_process_pid) == pid then
            state.godot_process = nil
            state.godot_process_pid = nil
        end

        if state.adopted and state.adopted.source == "managed" and tonumber(state.adopted.pid) == pid then
            state.adopted = nil
        end
    end

    if opts.force then
        force_kill_pid(pid)
        wait_for_pid_exit(pid, config.force_close_timeout_ms, generation, function(exited)
            if not exited and pid_alive(pid) then
                pcall(uv.kill, pid, "sigkill")
            end

            wait_for_pid_exit(pid, config.force_close_timeout_ms, generation, function(exited_after_kill)
                if exited_after_kill then
                    finish()
                    callback(true)
                else
                    callback(false, "Godot process did not exit after force close")
                end
            end)
        end)
        return
    end

    request_normal_close(pid, function(close_requested, err)
        if not close_requested then
            callback(false, err)
            return
        end

        wait_for_pid_exit(pid, config.close_timeout_ms, generation, function(exited)
            if exited then
                finish()
                callback(true)
                return
            end

            callback(false, "Godot is still running. Finish or cancel its save/close dialog, then retry. Use ! only if you accept losing unsaved Godot editor changes.")
        end)
    end)
end
-- 用 uv.spawn 而不是 vim.system 启动 Godot，原因有两个：
--
--   1. vim.system 硬编码了 hide = true，libuv 会据此设置
--      STARTF_USESHOWWINDOW + SW_HIDE。结果是 Godot 的编辑器窗口以隐藏状态
--      创建：你看不到它，而且它没有 MainWindowHandle，于是
--      scripts/godot-close.ps1（:GodotStop / :GodotRestart 的优雅关闭）
--      会报 "has no main window handle" 直接失败。
--   2. vim.system 不暴露 process handle，没法 unref。
--
-- stdio = { nil, nil, nil } 在 luv 里是 UV_IGNORE，Godot 的输出不会写进
-- Nvim 的终端。
local function spawn_godot(root, lsp_port, dap_port, on_exit)
    local handle, pid_or_error = uv.spawn(config.godot_path, {
        args = {
            "--editor",
            "--path",
            root,
            "--lsp-port",
            tostring(lsp_port),
            "--dap-port",
            tostring(dap_port),
        },
        cwd = root,
        stdio = { nil, nil, nil },
        -- keep_alive：让 Godot 活过 Nvim。
        --
        -- detached = false 时 libuv 会把子进程放进 job object，父进程一退出
        -- 就把它杀掉，于是每次启动 Nvim 都要重新冷启动一个编辑器。
        detached = config.keep_alive == true,
        -- 这里绝对不要加 hide，理由见上面第 1 条。
    }, function(code)
        on_exit(code)
    end)

    if not handle then
        return nil, tostring(pid_or_error)
    end

    if config.keep_alive == true then
        -- libuv 文档：detached 的子进程仍然会让父进程的事件循环保持存活，
        -- 除非父进程对它的 process handle 调用 unref。
        pcall(function()
            handle:unref()
        end)
    end

    return handle, tonumber(pid_or_error)
end

local function start_godot(root, generation, callback)
    local project_file = vim.fs.joinpath(root, "project.godot")
    if vim.fn.filereadable(project_file) ~= 1 then
        callback(false, "project.godot not found: " .. root, "launch")
        return
    end

    -- 固定住这一代实例的端口：启动过程中 state 里的端口不应该再变。
    local lsp_port = state.lsp_port
    local dap_port = state.dap_port

    local foreground_before_launch = capture_foreground_window()

    local process

    local function on_exit(code)
        vim.schedule(function()
            if state.godot_process ~= process then
                return
            end

            state.godot_process = nil
            state.godot_process_pid = nil
            forget_instance(root)
            disable_lsp()

            if code ~= nil and code ~= 0 then
                notify("Managed Godot exited with code " .. tostring(code), vim.log.levels.WARN)
            end
        end)
    end

    local godot_pid
    process, godot_pid = spawn_godot(root, lsp_port, dap_port, on_exit)

    if not process then
        callback(false, tostring(godot_pid), "launch")
        return
    end

    state.godot_process = process
    state.godot_process_pid = godot_pid

    guard_focus_after_godot_launch(foreground_before_launch, process, godot_pid)

    wait_for_port(lsp_port, true, config.startup_timeout_ms, generation, function(ready)
        if generation ~= state.generation then
            return
        end

        if not ready then
            callback(false, string.format(
                "Godot started, but LSP port %d did not become ready. The project remains owned by this Nvim; fix Godot's TCP LSP setting and run :GodotRestart.",
                lsp_port
            ), "lsp_timeout")
            return
        end

        -- 记下来，好让下一个 Nvim（或者 Nvim 重开之后）直接复用。
        if process_running(process) and godot_pid then
            record_instance(root, godot_pid, lsp_port, dap_port)
        end

        enable_lsp()
        callback(true)
    end)
end

M.port_is_open = port_is_open
M.wait_for_port = wait_for_port
M.managed_pid = managed_pid
M.managed_alive = managed_alive
M.instance_source_label = instance_source_label
M.wait_for_pid_exit = wait_for_pid_exit
M.close_helper_path = close_helper_path
M.request_normal_close = request_normal_close
M.force_kill_pid = force_kill_pid
M.close_managed_godot = close_managed_godot
M.spawn_godot = spawn_godot
M.start_godot = start_godot

return M

