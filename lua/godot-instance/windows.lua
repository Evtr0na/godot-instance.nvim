-- Windows 专用：
--   * 枚举顶层窗口标题，用来确认“某个 Godot 编辑器开的是当前项目”
--   * 启动 Godot 后把焦点抢回来（Godot 会抢前台窗口）
-- 非 Windows 平台上这些函数全部安全地返回 nil / false。
local config = require("godot-instance.config").options
local state = require("godot-instance.state")
local util = require("godot-instance.util")
local project = require("godot-instance.project")

local IS_WINDOWS = util.IS_WINDOWS
local normalize_match = util.normalize_match
local process_running = util.process_running
local now_ms = util.now_ms
local project_name_for_root = project.project_name_for_root

local M = {}

local window_title_api_state = {
    initialized = false,
    ffi = nil,
    user32 = nil,
}

local function window_title_api()
    if not IS_WINDOWS then
        return nil, nil
    end

    if window_title_api_state.initialized then
        return window_title_api_state.ffi, window_title_api_state.user32
    end

    window_title_api_state.initialized = true

    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then
        return nil, nil
    end

    -- pcall：FFI 的 C 声明是进程级的，配置重载时会重复声明。
    pcall(ffi.cdef, [[
        int EnumWindows(int (*lpEnumFunc)(void*, intptr_t), intptr_t lParam);
        int GetWindowTextLengthW(void* hWnd);
        int GetWindowTextW(void* hWnd, unsigned short* lpString, int nMaxCount);
    ]])

    local ok_user32, user32 = pcall(ffi.load, "user32")
    if not ok_user32 then
        return nil, nil
    end

    window_title_api_state.ffi = ffi
    window_title_api_state.user32 = user32
    return ffi, user32
end

local function normalized_window_titles()
    local ffi, user32 = window_title_api()
    if not ffi or not user32 then
        return nil
    end

    local titles = {}

    local callback = ffi.cast("int (*)(void*, intptr_t)", function(hwnd)
        local length = user32.GetWindowTextLengthW(hwnd)

        if length > 0 then
            local buffer = ffi.new("unsigned short[?]", length + 1)
            local copied = user32.GetWindowTextW(hwnd, buffer, length + 1)

            if copied > 0 then
                local chars = {}
                for index = 0, copied - 1 do
                    local code = buffer[index]
                    local is_digit = code >= 48 and code <= 57
                    local is_upper = code >= 65 and code <= 90
                    local is_lower = code >= 97 and code <= 122

                    if is_digit or is_upper or is_lower then
                        chars[#chars + 1] = string.char(is_upper and code + 32 or code)
                    end
                end
                titles[#titles + 1] = table.concat(chars)
            end
        end

        return 1
    end)

    local ok = pcall(user32.EnumWindows, callback, 0)
    if not ok then
        return nil
    end

    return titles
end

local function external_editor_serves_project(root)
    local wanted = normalize_match(project_name_for_root(root))

    -- 项目名太短（或不是 ASCII）时无法可靠校验，宁可退回托管启动。
    if #wanted < 3 then
        return false
    end

    local titles = normalized_window_titles()
    if not titles then
        return false
    end

    for _, title in ipairs(titles) do
        -- 同时要求出现项目名和 "godot"：Godot 编辑器标题是
        -- "<scene> - <项目名> - Godot Engine"，而某个终端的标题可能只是
        -- 恰好包含项目目录名，那种情况不算数。
        if title:find(wanted, 1, true) and title:find("godot", 1, true) then
            return true
        end
    end

    return false
end
local windows_focus_api_state = {
    initialized = false,
    ffi = nil,
    user32 = nil,
    kernel32 = nil,
}

local function windows_focus_api()
    if not IS_WINDOWS then
        return nil, nil
    end

    if windows_focus_api_state.initialized then
        return windows_focus_api_state.ffi, windows_focus_api_state.user32, windows_focus_api_state.kernel32
    end

    windows_focus_api_state.initialized = true

    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then
        return nil, nil
    end

    -- pcall keeps this safe across config reloads, because LuaJIT FFI C
    -- declarations are global to the process and may already exist.
    pcall(ffi.cdef, [[
        void* GetForegroundWindow(void);
        int SetForegroundWindow(void* hWnd);
        int IsWindow(void* hWnd);
        int BringWindowToTop(void* hWnd);
        int AttachThreadInput(unsigned long idAttach, unsigned long idAttachTo, int fAttach);
        unsigned long GetWindowThreadProcessId(void* hWnd, unsigned long* lpdwProcessId);
        unsigned long GetCurrentThreadId(void);
    ]])

    local ok_user32, user32 = pcall(ffi.load, "user32")
    local ok_kernel32, kernel32 = pcall(ffi.load, "kernel32")
    if not ok_user32 or not ok_kernel32 then
        return nil, nil, nil
    end

    local ok_probe = pcall(function()
        return user32.GetForegroundWindow
            and user32.SetForegroundWindow
            and user32.IsWindow
            and user32.BringWindowToTop
            and user32.AttachThreadInput
            and user32.GetWindowThreadProcessId
            and kernel32.GetCurrentThreadId
    end)
    if not ok_probe then
        return nil, nil, nil
    end

    windows_focus_api_state.ffi = ffi
    windows_focus_api_state.user32 = user32
    windows_focus_api_state.kernel32 = kernel32
    return ffi, user32, kernel32
end

local function capture_foreground_window()
    if not config.preserve_focus_on_start then
        return nil
    end

    local ffi, user32, kernel32 = windows_focus_api()
    if not ffi or not user32 or not kernel32 then
        return nil
    end

    local ok, hwnd = pcall(user32.GetForegroundWindow)
    if not ok or hwnd == nil or hwnd == ffi.NULL then
        return nil
    end

    return {
        ffi = ffi,
        user32 = user32,
        kernel32 = kernel32,
        hwnd = hwnd,
    }
end

local function foreground_process_id(focus, hwnd)
    local pid = focus.ffi.new("unsigned long[1]")
    local ok, thread_id = pcall(focus.user32.GetWindowThreadProcessId, hwnd, pid)
    if not ok or thread_id == 0 then
        return nil
    end

    return tonumber(pid[0])
end

local function restore_foreground_window(focus, foreground)
    local ok_window, is_window = pcall(focus.user32.IsWindow, focus.hwnd)
    if not ok_window or is_window == 0 then
        return false
    end

    local ok_set, set_result = pcall(focus.user32.SetForegroundWindow, focus.hwnd)
    if ok_set and set_result ~= 0 then
        return true
    end

    -- Windows can reject SetForegroundWindow because of its foreground-lock
    -- rules. Temporarily attach Nvim's input thread to the current foreground
    -- thread and the terminal window thread, retry, then immediately detach.
    local ok_current, current_thread = pcall(focus.kernel32.GetCurrentThreadId)
    if not ok_current or current_thread == 0 then
        return false
    end

    local foreground_thread = nil
    if foreground and foreground ~= focus.ffi.NULL then
        local ok_fg, thread_id = pcall(focus.user32.GetWindowThreadProcessId, foreground, nil)
        if ok_fg and thread_id ~= 0 then
            foreground_thread = thread_id
        end
    end

    local ok_target, target_thread = pcall(focus.user32.GetWindowThreadProcessId, focus.hwnd, nil)
    if not ok_target or target_thread == 0 then
        return false
    end

    local attached = {}
    local function attach(thread_id)
        if not thread_id or thread_id == 0 or thread_id == current_thread then
            return
        end

        local ok_attach, attached_ok = pcall(focus.user32.AttachThreadInput, current_thread, thread_id, 1)
        if ok_attach and attached_ok ~= 0 then
            table.insert(attached, thread_id)
        end
    end

    attach(foreground_thread)
    attach(target_thread)

    pcall(focus.user32.BringWindowToTop, focus.hwnd)
    local ok_retry, retry_result = pcall(focus.user32.SetForegroundWindow, focus.hwnd)

    for index = #attached, 1, -1 do
        pcall(focus.user32.AttachThreadInput, current_thread, attached[index], 0)
    end

    return ok_retry and retry_result ~= 0
end

local function guard_focus_after_godot_launch(focus, process, pid)
    if not focus or not process or not pid then
        return
    end

    local timeout_ms = math.max(tonumber(config.focus_guard_timeout_ms) or 0, 0)
    local poll_ms = math.max(tonumber(config.focus_guard_poll_ms) or 40, 10)
    if timeout_ms == 0 then
        return
    end

    local deadline = now_ms() + timeout_ms
    local godot_pid = tonumber(pid)

    local function check()
        if state.godot_process ~= process or not process_running(process) then
            return
        end

        if now_ms() >= deadline then
            return
        end

        local ok, foreground = pcall(focus.user32.GetForegroundWindow)
        if not ok or foreground == nil or foreground == focus.ffi.NULL then
            vim.defer_fn(check, poll_ms)
            return
        end

        -- As long as Nvim's terminal is still in front, keep watching for the
        -- Godot editor's first activation.
        if foreground == focus.hwnd then
            vim.defer_fn(check, poll_ms)
            return
        end

        local foreground_pid = foreground_process_id(focus, foreground)
        if foreground_pid == godot_pid then
            -- Godot itself took focus. Restore the exact window that was in
            -- front before launch, then stop watching so later intentional
            -- Alt-Tab/mouse/GlazeWM focus changes are never fought.
            restore_foreground_window(focus, foreground)
            return
        end

        -- Some other window became foreground first. Treat that as an
        -- intentional user/window-manager focus change and do not interfere.
    end

    vim.schedule(check)
end

M.window_title_api = window_title_api
M.normalized_window_titles = normalized_window_titles
M.external_editor_serves_project = external_editor_serves_project
M.windows_focus_api = windows_focus_api
M.capture_foreground_window = capture_foreground_window
M.guard_focus_after_godot_launch = guard_focus_after_godot_launch

return M
