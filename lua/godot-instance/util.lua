-- 低层工具：路径规范化、通知、进程/端口存活探测、uv handle 工具。
local uv = vim.uv

local IS_WINDOWS = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
local HOST = "127.0.0.1"

local M = {}

M.uv = uv
M.IS_WINDOWS = IS_WINDOWS
M.HOST = HOST

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "Godot Instance" })
end

local function notify_unless_silent(opts, message, level)
    if not (opts and opts.silent) then
        notify(message, level)
    end
end

local function normalize_slashes(path)
    return path:gsub("\\", "/")
end

local function normalize_path(path)
    if not path or path == "" then
        return nil
    end

    local full = vim.fn.fnamemodify(path, ":p")
    full = vim.fs.normalize(full)
    full = normalize_slashes(full)

    if full ~= "/" and not full:match("^%a:/$") then
        full = full:gsub("/+$", "")
    end

    return full
end

local function path_key(path)
    path = normalize_path(path)
    if not path then
        return nil
    end

    if IS_WINDOWS then
        return path:lower()
    end

    return path
end

local function same_path(a, b)
    local ka = path_key(a)
    local kb = path_key(b)
    return ka ~= nil and kb ~= nil and ka == kb
end

local function pid_alive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 0 then
        return false
    end

    -- uv.kill(pid, 0) 在 Windows 上就是一次 OpenProcess 存活检查。
    local ok, result = pcall(uv.kill, pid, 0)
    return ok and result ~= nil
end
-- 同步 TCP 探测。本机端口被拒绝是即时的（实测 < 1ms），所以可以直接
-- 放在启动路径上，不需要异步等待。
local function tcp_reachable(port)
    port = tonumber(port)
    if not port then
        return false
    end

    local ok, channel = pcall(vim.fn.sockconnect, "tcp", string.format("%s:%d", HOST, port), { rpc = false })
    if not ok or type(channel) ~= "number" or channel <= 0 then
        return false
    end

    pcall(vim.fn.chanclose, channel)
    return true
end

local function normalize_match(text)
    return (tostring(text):lower():gsub("[^%w]", ""))
end

local function close_handle(handle)
    if not handle then
        return
    end

    pcall(function()
        if not handle:is_closing() then
            handle:close()
        end
    end)
end

local function now_ms()
    return uv.hrtime() / 1000000
end

local function process_running(process)
    if not process then
        return false
    end

    local ok, closing = pcall(process.is_closing, process)
    return ok and not closing
end

-- 查找随插件分发的脚本（scripts/ 目录）。
--- @param name string
--- @return string?
function M.script_path(name)
    local matches = vim.api.nvim_get_runtime_file("scripts/" .. name, false)
    if type(matches) == "table" and matches[1] then
        return matches[1]
    end

    return nil
end

M.notify = notify
M.notify_unless_silent = notify_unless_silent
M.normalize_slashes = normalize_slashes
M.normalize_path = normalize_path
M.path_key = path_key
M.same_path = same_path
M.pid_alive = pid_alive
M.tcp_reachable = tcp_reachable
M.normalize_match = normalize_match
M.close_handle = close_handle
M.now_ms = now_ms
M.process_running = process_running

return M
