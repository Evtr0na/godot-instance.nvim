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
    -- path_key -> { event_key = true }。按文件分组，这样文件一变就能整组清掉。
    seen = {},
}

-- path_key -> { mtime = <快照>, hash = <内容指纹> }。
--
-- Godot 不会发「这个错已经没了」的通知，所以诊断只能靠文件过期：文件一改，
-- 它身上的旧诊断就作废。否则你改好了错误、诊断还挂在旧行号上，看起来就是
-- 「乱报错」。
--
-- 但**不能只看 mtime**：同一份代码再保存一次也会改 mtime，而这时候代码根本
-- 没修 —— 光比 mtime 会把一条正确的诊断清掉，表现就是「我没改代码，报错却
-- 自己消失了」（实测踩过）。所以再存一份内容指纹：只有内容真的变了才算过期。
local file_state = {}

--- 文件内容指纹。读不到就返回 nil（调用方会退回「只比 mtime」的老行为）。
--- @return string?
local function file_hash(path)
    local ok, lines = pcall(vim.fn.readfile, path, "b")

    if not ok or type(lines) ~= "table" then
        return nil
    end

    return vim.fn.sha256(table.concat(lines, "\n"))
end

local tail = {
    timer = nil,
    path = nil,
    root = nil,
    root_key = nil,
    offset = 0,
    partial = "",
}

-- GDScript 解析级联抑制用的时间窗记录。
-- 必须声明在这里：M.clear() 定义在下面，要在它的作用域里可见。
local parse_burst = {}

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

--- 用 Godot 自己校验注入的 addon 能不能解析。
---
--- 这一步非常有必要：bridge.gd 一旦有语法错误，EditorPlugin 会**静默加载失败**，
--- 结果是「插件看起来装了、桥日志也不长、但一条报错都抓不到」—— 极难排查。
--- （实测踩过：一个编辑事故把 `var out := []` 拼到了 func 声明同一行。）
---
--- 只在真的写入文件之后跑（约 1 秒），不是每次进项目都跑。
--- @return string status, string? detail
function M.validate(root)
    if not root then
        return "no_project"
    end

    local script = vim.fs.joinpath(root, ADDON_REL, "bridge.gd")

    if vim.fn.filereadable(script) ~= 1 then
        return "missing"
    end

    local godot = config.godot_path

    if not godot or vim.fn.executable(godot) ~= 1 then
        return "no_godot"
    end

    local ok, result = pcall(function()
        return vim
            .system({
                godot,
                "--headless",
                "--check-only",
                "--script",
                script,
            }, { text = true })
            :wait()
    end)

    if not ok or type(result) ~= "table" then
        return "check_failed", tostring(result)
    end

    if result.code == 0 then
        return "ok"
    end

    return "invalid", (result.stdout or "") .. (result.stderr or "")
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

    --------------------------------------------------------
    -- 刚写过文件才校验（约 1 秒）。校验不过就大声报出来 ——
    -- 否则表现是「插件装了但一条报错都抓不到」，根本猜不到是语法错。
    --------------------------------------------------------

    if changed then
        local status, detail = M.validate(root)

        if status == "invalid" then
            notify(
                "注入的 Godot 插件有语法错误，编辑器会静默加载失败（一条报错都抓不到）：\n"
                    .. tostring(detail),
                vim.log.levels.ERROR
            )

            return { status = "invalid_addon", dir = dir, detail = detail }
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

    --------------------------------------------------------
    -- 钳住越界的行号。
    --
    -- Godot 的解析器恢复失败时会报出**超出文件末尾**的行号（实测 196 行的
    -- 文件报 198）。不钳的话诊断会指到一个不存在的位置，看起来就像乱报。
    --------------------------------------------------------

    if vim.api.nvim_buf_is_loaded(bufnr) then
        local total = vim.api.nvim_buf_line_count(bufnr)

        if total > 0 and item.lnum > total - 1 then
            item.user_data = item.user_data or {}
            item.user_data.clamped_from = item.lnum + 1
            item.user_data.clamped = true
            item.lnum = total - 1
        end
    end

    local list = published.items[key] or {}
    list[#list + 1] = item
    published.items[key] = list

    vim.diagnostic.set(ns, bufnr, list)

    -- 返回钳过之后的行号（1-based），调用方展示时用它，
    -- 免得面板里出现「198 行的文件报 198」这种越界数字
    return item.lnum + 1
end

--- 清掉某个文件的诊断 + 去重记录。
---
--- 去重记录必须一起清：否则「改好 → 又写坏成同样的错」会被去重挡住，
--- 表现就是"故意写错但没报"。
local function clear_file(path)
    local key = path_key(path)

    if not key then
        return
    end

    local bufnr = published.buffers[key]

    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.diagnostic.reset(ns, bufnr)
    end

    published.buffers[key] = nil
    published.items[key] = nil
    published.seen[key] = nil
    file_state[key] = nil
end

--- 文件改动过就把它身上的旧诊断作废。
---
--- 每轮 poll 都会检查一遍：改了文件但 Godot 没再报错（说明修好了），
--- 旧诊断就会被清掉。
---
--- 注意 file_state 一律用 path_key 做键，**不要**用路径字符串：
--- 事件里的路径（normalize_path 后的 res:// 展开）和 buffer 名字可能是同
--- 一个文件的不同写法，混用键的话 known 永远是 nil，过期检查就静默失效 ——
--- 表现正是「改好了诊断还挂着，只有重启 Nvim 才消失」。
---
--- 而且 mtime 变了**不等于**内容变了：只是又保存了一次同样的代码时，诊断
--- 必须留着（否则看着就是「没改代码报错却消失了」）。所以这里再比一次内容
--- 指纹，指纹一样就只把 mtime 快照往前推，不做清理。
local function expire_changed_files()
    local stale = {}

    for key, bufnr in pairs(published.buffers) do
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            local path = vim.api.nvim_buf_get_name(bufnr)
            local stamp = vim.fn.getftime(path)
            local known = file_state[key]

            if stamp > 0 and known and known.mtime and stamp ~= known.mtime then
                local now_hash = file_hash(path)

                if known.hash and now_hash and known.hash == now_hash then
                    -- 内容没变：保留诊断，只更新 mtime 快照，
                    -- 免得下一轮又去读一遍文件
                    known.mtime = stamp
                else
                    stale[#stale + 1] = path
                end
            end
        end
    end

    for _, path in ipairs(stale) do
        clear_file(path)
    end
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
    file_state = {}
    parse_burst = {}
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

            -- 跳过桥自己 addon 的帧。
            --
            -- 强制编译是我们发起的，所以引擎级联错的 backtrace 里第一个
            -- res:// 帧往往就是 addons/nvim_debug_bridge/bridge.gd —— 拿它
            -- 当位置的话，诊断会指到桥自己的代码上（实测踩过）。
            if f:match("^res://") and not f:find("addons/nvim_debug_bridge/", 1, true) then
                local path = normalize_path(vim.fs.joinpath(root, (f:gsub("^res://", ""))))

                if path then
                    return path, tonumber(frame.line) or 1
                end
            end
        end
    end

    return nil, nil
end

------------------------------------------------------------
-- GDScript 解析级联抑制
--
-- 一个真正的语法错会让解析器恢复失败，然后吐出一堆下游假错。
-- 实测 step_01.gd 里一个未闭合的 func 会报出 7 条，行号散落在 154~198
-- （198 还超出了文件总行数 196），看起来就像"乱报错"。
--
-- 只留每条「解析轮次」的第一条 —— 第一条通常就是根因。
-- 用 (文件, func) + 时间窗来判定"同一轮"，所以改好再写坏会重新报。
------------------------------------------------------------

local function is_script_parse_error(event, error_type)
    -- ERROR_TYPE_SCRIPT == 2，且解析阶段的 func 固定是 GDScript::reload
    -- （运行时脚本错的 func 是别的名字，那种不该被吞掉）
    return error_type == 2 and (event.func or "") == "GDScript::reload"
end

--- 这是不是「编辑器侧的 GDScript 报错」。
---
--- 这类报错和 godotdev.nvim 的 LSP 诊断是同一批内容（同一个 GDScript
--- 解析器、同一份语法分析结果），两边都报就是重复。默认不发（见
--- config.bridge.script_errors）。
---
--- 注意：这里只影响**编辑器**侧。游戏跑起来之后的脚本报错是游戏进程写的，
--- 走 debuglog.lua 那条 godot.log 的路，不受这里影响 —— 那才是你要的
--- 「运行以后的调试报错」。
--- @return boolean
local function is_editor_script_error(event, error_type)
    -- ERROR_TYPE_SCRIPT
    if error_type == 2 then
        return true
    end

    -- 少数情况下解析错会以 ERROR_TYPE_ERROR 出来，用 func 兜一层
    local func = event.func or ""

    if func:match("^GDScript::") or func:match("^GDScriptLanguage::") then
        return true
    end

    return false
end

--- @return boolean true = 这是同一轮解析的后续假错，应该丢掉
local function collapse_burst(event)
    if opts().collapse_script_parse_errors == false then
        return false
    end

    local key = (event.file or "") .. "\1" .. (event.func or "")
    local now = util.now_ms()
    local window = opts().parse_burst_window_ms or 3000
    local last = parse_burst[key]

    if last and (now - last) < window then
        return true
    end

    parse_burst[key] = now

    return false
end

local function handle_event(event, root)
    if event.kind ~= "error" then
        return
    end

    local error_type = tonumber(event.type) or 0

    --------------------------------------------------------
    -- 编辑器侧的 GDScript 报错默认不发。
    --
    -- 它和 godotdev.nvim 的 LSP 诊断是同一份东西（同一个解析器、同一批
    -- 语法错误），两边都出就是重复，而且对你已经知道的问题再喊一遍毫无
    -- 价值。游戏运行以后的脚本报错走 debuglog 那条路，不在这里。
    --
    -- 放在定位之前：省掉一次 backtrace 扫描，也不占用去重名额。
    --------------------------------------------------------

    if opts().script_errors ~= true and is_editor_script_error(event, error_type) then
        return
    end

    --------------------------------------------------------
    -- 先定位。引擎路径（servers/、core/、./...）在这里就被丢掉了，
    -- 不该占用去重名额。
    --------------------------------------------------------

    local path, lnum = resolve_location(event, root)

    if not path then
        return
    end

    local pkey = path_key(path)

    if not pkey then
        return
    end

    --------------------------------------------------------
    -- 过期事件直接丢。
    --
    -- 事件带的是「报错时那个源文件的 mtime」，跟当前 mtime 精确比对：
    -- 不相等就说明文件后来被改过，这条报错属于**旧版本**，丢掉。
    --
    -- 两边都是 OS stat 出来的同一个值，所以没有时区/时钟偏差问题 ——
    -- 早先用墙上时间戳比就踩过这个坑（PowerShell 的 %s 带时区偏移，
    -- 导致刚报的错被判成过期，或者旧错判成新错）。
    --------------------------------------------------------

    local current_mtime = vim.fn.getftime(path)
    local event_mtime = tonumber(event.mtime) or 0

    if event_mtime ~= 0 and current_mtime > 0 and current_mtime ~= event_mtime then
        ----------------------------------------------------
        -- mtime 不一致 **不等于** 内容变了：同一份代码再保存一次也会改
        -- mtime。那种情况这条报错依然有效，不能丢（丢了就是「我没动代码，
        -- 报错却消失了」）。
        --
        -- 只有「内容指纹也对不上」才说明这份报错属于旧版本，丢掉。
        -- 没有指纹记录（第一次见到这个文件）时保守丢掉：反正改完再触发
        -- 一次编译就会重新报上来。
        ----------------------------------------------------

        local known = file_state[pkey]
        local now_hash = file_hash(path)

        if not (known and known.hash and now_hash and known.hash == now_hash) then
            return
        end
    end

    --------------------------------------------------------
    -- 去重：同一个文件的 (类型, 行, 消息) 只发一次。
    -- shader 会反复重编译，不去重会把诊断刷爆。
    --
    -- 按文件分组存，这样文件一改就能整组清掉（见 clear_file）。
    --------------------------------------------------------

    local seen = published.seen[pkey] or {}
    local key = table.concat({
        tostring(error_type),
        tostring(lnum),
        tostring(event.code),
    }, "\1")

    if seen[key] then
        return
    end

    seen[key] = true
    published.seen[pkey] = seen

    -- 基准时间用**事件里的 mtime**（报错那一刻的文件状态），不是当前 mtime：
    -- 用当前 mtime 的话，poll 里的 expire 永远发现不了"文件后来变了"
    -- （快照就是刚拍的）。旧事件没有 mtime 才退回当前值。
    --
    -- 键用 pkey（和 published.buffers 同一套键），见 expire_changed_files。
    -- hash 一起记：mtime 变了但内容没变时，诊断要留着（见上面那个检查）。
    file_state[pkey] = {
        mtime = event_mtime ~= 0 and event_mtime or current_mtime,
        hash = file_hash(path),
    }

    local message = event.code

    if not message or message == "" then
        message = event.rationale
    end

    if not message or message == "" then
        message = "Godot 报错（没有消息文本）"
    end

    local type_name = TYPE_NAME[error_type] or "ERROR"

    --------------------------------------------------------
    -- 解析级联抑制。
    --
    -- 一个真正的语法错会让 GDScript 解析器恢复失败，然后吐出一堆下游假错
    -- （实测：step_01.gd 里一个未闭合的 func 报出 7 条，行号散落在
    -- 154~198）。只留每条「解析轮次」的第一条 —— 第一条通常就是根因。
    --------------------------------------------------------

    if is_script_parse_error(event, error_type) and collapse_burst(event) then
        return
    end

    local shown_lnum = add_diagnostic(path, {
        lnum = math.max((lnum or 1) - 1, 0),
        col = 0,
        severity = SEVERITY[error_type] or vim.diagnostic.severity.ERROR,
        message = message,
        source = "godot-editor",
        code = type_name,
        user_data = {
            func = event.func,
            rationale = event.rationale,
        },
    }) or (lnum or 1)

    --------------------------------------------------------
    -- 也写进调试面板，这样 <leader>gD 就能实时看到编辑器报错。
    -- （面板按 (类型,文件,行,消息) 去重，所以不会刷屏。）
    --------------------------------------------------------

    if opts().show_in_panel ~= false then
        vim.schedule(function()
            pcall(function()
                require("godot-instance.debuglog").append_panel({
                    ("[editor/%s] %s:%d  %s"):format(
                        type_name,
                        event.file or path,
                        shown_lnum,
                        message
                    ),
                })
            end)
        end)
    end
end

------------------------------------------------------------
-- tail
------------------------------------------------------------

local function poll()
    local path = tail.path

    --------------------------------------------------------
    -- 先让改动过的文件上的旧诊断作废，再处理这一批新事件。
    --
    -- 顺序很重要：文件一改（不论修好还是写坏），旧诊断先清掉；
    -- 随后 Godot 如果报了新错，就会重新加上。这样诊断始终对应当前
    -- 这一版文件，不会像之前那样挂着 17:32 的旧行号。
    --
    -- 注意这个检查要在「没有新事件」时也跑（下面 size == offset 会
    -- return），所以放在最前面。
    --------------------------------------------------------

    expire_changed_files()

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
--- 注入/启用**每次都会跑**（都是读几个小文件，很便宜），不能只跑一次：
--- Godot 在「插件加载失败」或「首次导入新项目、插件还没被发现」时，会把
--- 条目从 project.godot 的 [editor_plugins] 里**删掉**。只跑一次的话就再也
--- 补不回来了，表现是「插件怎么都不生效」。
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
    local same = (key == tail.root_key) and tail.path ~= nil

    if not same then
        tail.root = root
        tail.root_key = key
        tail.offset = 0
        tail.partial = ""
        M.clear()
    end

    local result = { root = root, same = same }

    if opts().inject ~= false then
        local injected = M.inject(root)
        result.inject = injected.status
        result.dir = injected.dir

        if injected.status == "invalid_addon" then
            result.status = "invalid_addon"
            return result
        end
    end

    if opts().auto_enable ~= false then
        result.enable = M.enable(root)
    end

    if not same then
        tail.path = bridge_log_path(root)

        if tail.path then
            ensure_timer()
        end
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
