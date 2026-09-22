-- 编辑器报错桥（Godot -> Nvim）
--
-- 解决的问题：编辑器侧的报错（最典型的是 gdshader 编译失败）只进 Godot 的
-- Output 面板，**不会**写进 user://logs/godot.log —— 那个文件是游戏进程写的。
-- 所以 debuglog.lua 那条 tail 日志的路只能看到「跑起来的游戏」的报错，
-- 看不到你编辑 shader 时的报错。
--
-- 做法：往项目里注入一个 EditorPlugin（godot_addon/nvim_debug_bridge/），
-- 它用 OS.add_logger() 挂一个 Logger，把编辑器里的报错按 JSON 一行写到
-- user://nvim_debug_bridge.log。这里 tail 那个文件并转成诊断。
--
-- Logger._log_error 给的是**精确的** file / line / code / error_type
-- （含 ERROR_TYPE_SHADER），不需要靠报错文本反查文件。
--
-- 与 debuglog.lua 的分工：
--   * 编辑器侧（编辑时 shader/脚本报错） -> 本模块
--   * 游戏运行时（F5 的输出）           -> debuglog.lua 的日志 tail
-- 两者互补，因为游戏是另一个进程。
local config = require("godot-instance.config").options
local state = require("godot-instance.state")
local util = require("godot-instance.util")
local project = require("godot-instance.project")

local uv = util.uv
local notify = util.notify
local normalize_path = util.normalize_path
local path_key = util.path_key

local M = {}

-- 注入到项目里的插件目录名 / 相对路径
local ADDON_DIR_NAME = "nvim_debug_bridge"
local ADDON_REL = "addons/" .. ADDON_DIR_NAME
local ADDON_FILES = { "plugin.cfg", "bridge.gd" }

-- 文件里出现这个标记才认为「这是我们注入的」，否则绝不覆盖
local MANAGED_MARKER = "managed-by: godot-instance.nvim"

local BRIDGE_LOG_NAME = "nvim_debug_bridge.log"

-- 诊断命名空间。刻意和 debuglog.lua 分开：
-- 那一份会在每次游戏运行时清空重来，编辑器报错不该被游戏运行清掉。
local ns = vim.api.nvim_create_namespace("godot_instance_bridge")

local published = {
    buffers = {},
    items = {},
    seen = {},
}

local tail = {
    timer = nil,
    path = nil,
    root = nil,
    root_key = nil,
    offset = 0,
    partial = "",
}

M.state = tail
M.published = published

------------------------------------------------------------
-- 配置
------------------------------------------------------------

local function opts()
    return config.bridge or {}
end

local function enabled()
    return opts().enabled ~= false
end

------------------------------------------------------------
-- 当前项目
------------------------------------------------------------

local function current_root()
    local from_buf = project.project_root_for_buf(vim.api.nvim_get_current_buf())

    if from_buf then
        return from_buf
    end

    local from_cwd = project.project_root_for_file(vim.fn.getcwd())

    if from_cwd then
        return from_cwd
    end

    return state.active_root
end

------------------------------------------------------------
-- 注入 addon
------------------------------------------------------------

--- 插件自带的 addon 源文件在哪（随插件分发，不在项目里）。
--- @return string? dir
local function shipped_addon_dir()
    local matches = vim.api.nvim_get_runtime_file("godot_addon/" .. ADDON_DIR_NAME .. "/plugin.cfg", false)

    if type(matches) == "table" and matches[1] then
        return vim.fn.fnamemodify(matches[1], ":h")
    end

    return nil
end

--- 把源文件写到目标路径。
---
--- 复用规则：
---   * 内容一样            -> 什么都不做（复用）
---   * 内容不一样但是我们的 -> 覆盖（保持同步）
---   * 内容不一样且不是我们的 -> 不碰，报一声（可能是用户自己写的同名插件）
--- @return string status
local function sync_file(target, source)
    local wanted = vim.fn.readfile(source)

    if vim.fn.filereadable(target) == 1 then
        local existing = vim.fn.readfile(target)

        if table.concat(existing, "\n") == table.concat(wanted, "\n") then
            return "reused"
        end

        if not table.concat(existing, "\n"):find(MANAGED_MARKER, 1, true) then
            return "foreign"
        end
    end

    vim.fn.mkdir(vim.fs.dirname(target), "p")
    vim.fn.writefile(wanted, target)

    return "written"
end

--- 把 addon 注入项目。
--- @return table { status, dir }
function M.inject(root)
    local shipped = shipped_addon_dir()

    if not shipped then
        return { status = "no_source" }
    end

    local dir = vim.fs.joinpath(root, ADDON_REL)
    local statuses = {}

    for _, name in ipairs(ADDON_FILES) do
        local status = sync_file(vim.fs.joinpath(dir, name), vim.fs.joinpath(shipped, name))
        statuses[#statuses + 1] = status

        if status == "foreign" then
            return { status = "foreign", dir = dir }
        end
    end

    local changed = false

    for _, status in ipairs(statuses) do
        if status == "written" then
            changed = true
        end
    end

    return { status = changed and "written" or "reused", dir = dir }
end

------------------------------------------------------------
-- 在 project.godot 里勾上插件
------------------------------------------------------------

local function plugin_res_path()
    return "res://" .. ADDON_REL .. "/plugin.cfg"
end

--- 解析 enabled=PackedStringArray("a", "b") 里的条目。
local function parse_entries(line)
    local inner = line:match("PackedStringArray%s*%((.*)%)%s*$")

    if not inner then
        return {}
    end

    local out = {}

    for item in inner:gmatch('"([^"]*)"') do
        out[#out + 1] = item
    end

    return out
end

local function format_entries(entries)
    local quoted = {}

    for _, item in ipairs(entries) do
        quoted[#quoted + 1] = '"' .. item .. '"'
    end

    return "PackedStringArray(" .. table.concat(quoted, ", ") .. ")"
end

--- 幂等地把插件写进 project.godot 的 [editor_plugins] enabled。
---
--- Godot 只在启动时加载编辑器插件，所以改完要重启编辑器才生效。
--- @return string status "already" | "updated" | "no_file" | "failed"
function M.enable(root)
    local file = vim.fs.joinpath(root, "project.godot")

    if vim.fn.filereadable(file) ~= 1 then
        return "no_file"
    end

    local wanted = plugin_res_path()
    local lines = vim.fn.readfile(file)

    local section_start, section_end = nil, nil

    for i, line in ipairs(lines) do
        local header = line:match("^%s*%[([^%]]+)%]")

        if header then
            if header == "editor_plugins" then
                section_start = i
            elseif section_start and not section_end then
                section_end = i - 1
            end
        end
    end

    if section_start and not section_end then
        section_end = #lines
    end

    --------------------------------------------------------
    -- 已经有 [editor_plugins]：在段里找 enabled
    --------------------------------------------------------

    if section_start then
        for i = section_start, section_end do
            local key, value = lines[i]:match("^%s*([%w_/]+)%s*=%s*(.*)$")

            if key == "enabled" then
                local entries = parse_entries(value)

                for _, entry in ipairs(entries) do
                    if entry == wanted then
                        return "already"
                    end
                end

                table.insert(entries, wanted)
                lines[i] = "enabled=" .. format_entries(entries)

                vim.fn.writefile(lines, file)

                return "updated"
            end
        end

        -- 段在但没有 enabled：插在段头后面
        table.insert(lines, section_start + 1, "enabled=" .. format_entries({ wanted }))
        table.insert(lines, section_start + 1, "")

        vim.fn.writefile(lines, file)

        return "updated"
    end

    --------------------------------------------------------
    -- 没有这个段：追加
    --------------------------------------------------------

    if #lines > 0 and lines[#lines] ~= "" then
        lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "[editor_plugins]"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "enabled=" .. format_entries({ wanted })

    vim.fn.writefile(lines, file)

    return "updated"
end

------------------------------------------------------------
-- 桥日志
------------------------------------------------------------

local function bridge_log_path(root)
    local configured = opts().log_path

    if configured and configured ~= "" then
        return configured
    end

    local dir = project.user_data_dir(root)

    if not dir then
        return nil
    end

    return vim.fs.joinpath(dir, BRIDGE_LOG_NAME)
end

------------------------------------------------------------
-- 诊断
------------------------------------------------------------

local SEVERITY = {
    [0] = vim.diagnostic.severity.ERROR, -- ERROR_TYPE_ERROR
    [1] = vim.diagnostic.severity.WARN, -- ERROR_TYPE_WARNING
    [2] = vim.diagnostic.severity.ERROR, -- ERROR_TYPE_SCRIPT
    [3] = vim.diagnostic.severity.ERROR, -- ERROR_TYPE_SHADER
}

local TYPE_NAME = {
    [0] = "ERROR",
    [1] = "WARNING",
    [2] = "SCRIPT",
    [3] = "SHADER",
}

local function add_diagnostic(path, item)
    local key = path_key(path)

    if not key then
        return
    end

    local bufnr = published.buffers[key]

    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        if vim.fn.filereadable(path) ~= 1 then
            return
        end

        bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)
        published.buffers[key] = bufnr
    end

    local list = published.items[key] or {}
    list[#list + 1] = item
    published.items[key] = list

    vim.diagnostic.set(ns, bufnr, list)
end

--- 清掉桥发布的诊断（不动 debuglog 那份）。
function M.clear()
    for _, bufnr in pairs(published.buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.diagnostic.reset(ns, bufnr)
        end
    end

    published.buffers = {}
    published.items = {}
    published.seen = {}
end

--- 桥发布的诊断，扁平化。
--- debuglog.lua 的展示会合并它（只影响展示，不影响各自的清空时机）。
function M.diagnostics()
    local out = {}

    for key, list in pairs(published.items) do
        local bufnr = published.buffers[key]

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            for _, item in ipairs(list) do
                out[#out + 1] = {
                    bufnr = bufnr,
                    path = vim.api.nvim_buf_get_name(bufnr),
                    item = item,
                }
            end
        end
    end

    return out
end

function M.count()
    return #M.diagnostics()
end

------------------------------------------------------------
-- 事件 -> 诊断
------------------------------------------------------------

--- 从事件里定出 (绝对路径, 行号)。
---
--- 优先用 Logger 直接给的 file：它是精确的，而且 shader 报错会带
--- res://xxx.gdshader。只有它是引擎路径（servers/、core/、./...）时，
--- 才退回 script_backtraces 里第一个 res:// 帧。
--- @return string? path, number? lnum
local function resolve_location(event, root)
    local file = event.file or ""

    if file:match("^res://") then
        local rel = file:gsub("^res://", "")
        local path = normalize_path(vim.fs.joinpath(root, rel))

        if path then
            return path, tonumber(event.line) or 1
        end
    end

    for _, frames in ipairs(event.backtraces or {}) do
        for _, frame in ipairs(frames) do
            local f = frame.file or ""

            if f:match("^res://") then
                local path = normalize_path(vim.fs.joinpath(root, (f:gsub("^res://", ""))))

                if path then
                    return path, tonumber(frame.line) or 1
                end
            end
        end
    end

    return nil, nil
end

local function handle_event(event, root)
    if event.kind ~= "error" then
        return
    end

    local error_type = tonumber(event.type) or 0

    --------------------------------------------------------
    -- 去重：同一个 (类型, 文件, 行, 消息) 只发一次。
    -- shader 会反复重编译，不去重会把诊断刷爆。
    --------------------------------------------------------

    local key = table.concat({
        tostring(error_type),
        tostring(event.file),
        tostring(event.line),
        tostring(event.code),
    }, "\1")

    if published.seen[key] then
        return
    end

    published.seen[key] = true

    local path, lnum = resolve_location(event, root)

    if not path then
        return
    end

    local message = event.code

    if not message or message == "" then
        message = event.rationale
    end

    if not message or message == "" then
        message = "Godot 报错（没有消息文本）"
    end

    add_diagnostic(path, {
        lnum = math.max((lnum or 1) - 1, 0),
        col = 0,
        severity = SEVERITY[error_type] or vim.diagnostic.severity.ERROR,
        message = message,
        source = "godot-editor",
        code = TYPE_NAME[error_type] or "ERROR",
        user_data = {
            func = event.func,
            rationale = event.rationale,
        },
    })
end

------------------------------------------------------------
-- tail
------------------------------------------------------------

local function poll()
    local path = tail.path

    if not path or vim.fn.filereadable(path) ~= 1 then
        return
    end

    local file = io.open(path, "rb")

    if not file then
        return
    end

    local size = file:seek("end") or 0

    --------------------------------------------------------
    -- 变小 = 编辑器重启了（addon 在 _enter_tree 里会截断日志）。
    -- 那一轮的诊断已经过期，清掉重来。
    --------------------------------------------------------

    if size < tail.offset then
        tail.offset = 0
        tail.partial = ""
        M.clear()
    end

    if size == tail.offset then
        file:close()
        return
    end

    file:seek("set", tail.offset)

    local data = file:read("*a") or ""

    tail.offset = size
    file:close()

    local text = tail.partial .. data
    local lines = vim.split(text, "\r?\n", { plain = false })

    if text:sub(-1) ~= "\n" then
        tail.partial = table.remove(lines) or ""
    else
        tail.partial = ""

        if lines[#lines] == "" then
            table.remove(lines)
        end
    end

    for _, line in ipairs(lines) do
        if line ~= "" then
            local ok, event = pcall(vim.json.decode, line)

            if ok and type(event) == "table" then
                handle_event(event, tail.root)
            end
        end
    end
end

local function ensure_timer()
    if tail.timer then
        return
    end

    local interval = opts().interval_ms or 200
    local timer = uv.new_timer()

    if not timer then
        return
    end

    tail.timer = timer

    timer:start(interval, interval, vim.schedule_wrap(function()
        local ok, err = pcall(poll)

        if not ok then
            timer:stop()
            tail.timer = nil
            notify("编辑器报错桥轮询出错：\n" .. tostring(err), vim.log.levels.ERROR)
        end
    end))
end

------------------------------------------------------------
-- 对外
------------------------------------------------------------

--- 对齐当前项目：注入 addon、勾上插件、开始 tail。
---
--- 注入写文件是幂等的（内容一样就跳过），所以重复调用没关系。
--- @return table
function M.sync()
    if not enabled() then
        return { status = "disabled" }
    end

    local root = current_root()

    if not root then
        return { status = "no_project" }
    end

    local key = path_key(root)

    if key == tail.root_key and tail.path then
        return { status = "same", root = root }
    end

    tail.root = root
    tail.root_key = key
    tail.offset = 0
    tail.partial = ""
    M.clear()

    local result = { root = root }

    if opts().inject ~= false then
        local injected = M.inject(root)
        result.inject = injected.status
        result.dir = injected.dir
    end

    if opts().auto_enable ~= false then
        result.enable = M.enable(root)
    end

    tail.path = bridge_log_path(root)

    if tail.path then
        ensure_timer()
    end

    return result
end

--- 项目里是否已经勾上了这个插件（只读检查）。
--- @return boolean
function M.is_enabled(root)
    if not root then
        return false
    end

    local file = vim.fs.joinpath(root, "project.godot")

    if vim.fn.filereadable(file) ~= 1 then
        return false
    end

    local wanted = plugin_res_path()

    for _, line in ipairs(vim.fn.readfile(file)) do
        if line:find(wanted, 1, true) then
            return true
        end
    end

    return false
end

--- 状态快照（health / 命令用）。
function M.info()
    local root = tail.root

    return {
        root = root,
        path = tail.path,
        exists = tail.path ~= nil and vim.fn.filereadable(tail.path) == 1,
        count = M.count(),
        addon = root and vim.fs.joinpath(root, ADDON_REL) or nil,
        injected = root ~= nil
            and vim.fn.filereadable(vim.fs.joinpath(root, ADDON_REL, "bridge.gd")) == 1,
        enabled = M.is_enabled(root),
    }
end

--- 引导：进入 Godot 项目时自动对齐。
function M.setup()
    local group = vim.api.nvim_create_augroup("godot_instance_bridge", { clear = true })

    vim.api.nvim_create_autocmd({ "BufEnter", "VimEnter" }, {
        group = group,
        callback = function()
            pcall(M.sync)
        end,
    })
end

return M
