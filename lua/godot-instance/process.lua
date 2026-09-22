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
-- stdio = { nil, nil, nil } 在 luv 里是 UV_IGNORE，Godot 自己的输出不会写进
-- Nvim 的终端。
--
-- ---------------------------------------------------------------------------
-- 为什么还要再套一层 cmd.exe（config.console_wrapper）
-- ---------------------------------------------------------------------------
-- 上面那句只管得住**编辑器自己**。真正把游戏输出灌进 Nvim 的是另一条路径：
--
--   * Godot 在 Windows 上启动（OS_Windows 构造函数，非 CONSOLE 子系统构建）
--     会无条件调用 RedirectIOToConsole()：
--         if (AttachConsole(ATTACH_PARENT_PROCESS)) {
--             RedirectStream("CONOUT$", "w", stdout, STD_OUTPUT_HANDLE);
--             RedirectStream("CONOUT$", "w", stderr, STD_ERROR_HANDLE);
--         }
--     RedirectStream 只在「CRT 里的流还不是有效句柄」时才改道。
--   * 编辑器是我们 spawn 的、stdio 给了 NUL（有效句柄），所以它自己没事 ——
--     但它先 AttachConsole 到了**父进程（Nvim）的控制台**上。
--   * 编辑器 F5 起的游戏走的是 Godot 内部的 create_process()：STARTUPINFO
--     被 ZeroMemory、bInheritHandles=false，于是游戏拿到的是 **NULL** 句柄 ——
--     正好满足上面那个条件。游戏的 stdout/stderr 于是接到「编辑器挂着的那个
--     控制台」，也就是 **Nvim 的终端**。
--
-- 结果就是实测到的现象：游戏一跑，输出从第 0 列盖在 Nvim 画面上，字符级错乱
-- （实测：attach 之后控制台进程列表里能查到 Godot 编辑器的 PID）。
--
-- 让一个 detached 的 cmd.exe 当父进程就断了这条链：cmd 没有控制台 →
-- 编辑器 AttachConsole(父进程=cmd) 失败 → 编辑器没有控制台 → 游戏也挂不上
-- 任何控制台 → 输出只进 user://logs/godot.log（那才是插件真正在看的东西）。
--
-- 附带好处：cmd /c 会等子进程退出，所以 on_exit、存活判断、:GodotStop 的
-- 时序语义都不变（cmd 也会把子进程的退出码透传出来）。
local DEFAULT_CMD = "C:\\Windows\\System32\\cmd.exe"

--- cmd.exe 的绝对路径（优先 COMSPEC）。
local function cmd_exe()
    local comspec = uv.os_getenv("COMSPEC")

    if comspec and comspec ~= "" and vim.fn.filereadable(comspec) == 1 then
        return comspec
    end

    return DEFAULT_CMD
end

--- 能不能用 cmd 中间层。
---
--- 两个硬性前提：
---
---   1. **中间层必须 detached**（没有控制台），否则它自己就继承了 Nvim 的
---      控制台，Godot 照样挂得上去 —— 实测：keep_alive = false 时中间层
---      出现在控制台进程列表里，修复完全失效。而 detached 与 keep_alive
---      是同一个开关，所以中间层只在 keep_alive = true 时可用。
---      （keep_alive = false 的语义是「Godot 不许活过 Nvim」，靠 libuv 的
---      job object 实现，而 job object 里的进程会继承控制台，两者不可兼得。）
---   2. Godot 路径里不能有空格：cmd /c 遇到「命令行以引号开头」的规则会把
---      首尾引号吃掉，路径就断了。那种情况退回直连（会污染终端，但不至于
---      起不来）。
local function wrapper_usable()
    if not IS_WINDOWS or config.console_wrapper == false then
        return false
    end

    if config.keep_alive ~= true then
        return false
    end

    local exe = tostring(config.godot_path or "")

    if exe == "" or exe:find("%s") then
        return false
    end

    return vim.fn.filereadable(cmd_exe()) == 1
end

--- 查某个进程的 Godot 子进程 PID（中间层用）。
--- @return integer?
local function query_child_pid(parent_pid)
    local command = table.concat({
        "$ErrorActionPreference = 'SilentlyContinue';",
        ("$p = Get-CimInstance Win32_Process -Filter 'ParentProcessId=%d'"):format(parent_pid),
        "| Where-Object { $_.Name -like 'Godot*' } | Select-Object -First 1;",
        "if ($p) { [Console]::Out.Write($p.ProcessId) }",
    }, " ")

    local ok, result = pcall(function()
        return vim
            .system({
                "powershell.exe",
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                command,
            }, { text = true })
            :wait(4000)
    end)

    if not ok or type(result) ~= "table" then
        return nil
    end

    return tonumber(tostring(result.stdout or ""):match("%d+"))
end

--- 中间层给的是 cmd 的 PID，换成真正的 Godot PID。
---
--- 焦点守卫是按「前台窗口的 PID」比对的，godot-close.ps1 要 Godot 的
--- MainWindowHandle，实例记录也用它 —— 拿 cmd 的 PID 三样都会坏。
--- 子进程是 cmd 起来之后才出现的，所以这里要重试几次。
--- @return integer?
local function resolve_child_pid(parent_pid)
    if not parent_pid then
        return nil
    end

    -- 这两个实现都要阻塞事件循环（vim.wait / vim.system:wait），而 fast event
    -- 上下文里不允许阻塞。正常路径（:GodotStart / activate）都是用户上下文，
    -- 但万一从 luv 回调里走到这里，宁可退回中间层 PID 也不要抛错。
    if vim.in_fast_event() then
        return nil
    end

    for _ = 1, 6 do
        local pid = query_child_pid(parent_pid)

        if pid then
            return pid
        end

        vim.wait(150, function()
            return false
        end)
    end

    return nil
end

local function spawn_godot(root, lsp_port, dap_port, on_exit)
    local godot_args = {
        "--editor",
        "--path",
        root,
        "--lsp-port",
        tostring(lsp_port),
        "--dap-port",
        tostring(dap_port),
    }

    local exe = config.godot_path
    local args = godot_args
    local wrapped = wrapper_usable()

    if wrapped then
        exe = cmd_exe()
        args = { "/c", config.godot_path }
        vim.list_extend(args, godot_args)
    end

    local handle, pid_or_error = uv.spawn(exe, {
        args = args,
        cwd = root,
        stdio = { nil, nil, nil },
        -- keep_alive：让 Godot 活过 Nvim。
        --
        -- detached = false 时 libuv 会把子进程放进 job object，父进程一退出
        -- 就把它杀掉，于是每次启动 Nvim 都要重新冷启动一个编辑器。
        --
        -- 注意 detached 对上面那条控制台链的修复没有贡献：AttachConsole(
        -- ATTACH_PARENT_PROCESS) 挂的是**父进程**的控制台，跟自己的
        -- DETACHED_PROCESS 无关。真正起作用的是「父进程没有控制台」。
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

    return handle, tonumber(pid_or_error), wrapped
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
    local wrapped
    process, godot_pid, wrapped = spawn_godot(root, lsp_port, dap_port, on_exit)

    if not process then
        callback(false, tostring(godot_pid), "launch")
        return
    end

    --------------------------------------------------------
    -- 套了中间层的话，spawn 给的是 cmd 的 PID，换成真正的 Godot PID。
    --
    -- 必须在 guard_focus_after_godot_launch 之前换掉：那个守卫是拿「前台
    -- 窗口的 PID」跟 godot_pid 比的，拿 cmd 的 PID 永远比不上，结果就是
    -- 「preserve_focus_on_start 失效、Godot 把焦点抢走」。
    --
    -- cmd /c 会一直等到子进程退出，所以 process handle（存活判断、on_exit）
    -- 的语义不受影响。
    --------------------------------------------------------

    if wrapped then
        local real_pid = resolve_child_pid(godot_pid)

        if real_pid then
            godot_pid = real_pid
        else
            notify(
                "没能解析出 Godot 的真实 PID（中间层超时）；焦点守卫和优雅关闭可能不生效。",
                vim.log.levels.WARN
            )
        end
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

