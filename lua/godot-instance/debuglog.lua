-- 调试日志：把 Godot 的调试输出接进 Nvim。
--
-- 解决的问题
-- ----------
-- 在 Godot 编辑器里按 F5 / F6 启动游戏时，游戏的 stdout/stderr 被编辑器
-- 自己吞掉写进它的 Debugger 面板，Nvim 这边什么都看不到。godotdev.nvim 的
-- run console 只能抓「Nvim 自己启动」的游戏（它是父进程才能拿到管道），
-- 所以那条路覆盖不到 F5/F6。
--
-- 通道
-- ----
-- Godot 桌面平台默认开启文件日志（debug/file_logging/enable_file_logging.pc
-- 默认 true），游戏进程会把 print / push_error / SCRIPT ERROR /
-- GDScript backtrace 逐行 flush 写进：
--
--     <user_data_dir>/logs/godot.log
--
-- 编辑器 F5/F6 启动的游戏同样写这个文件，所以只要 tail 它，不管游戏是谁
-- 启动的都能拿到报错。实测每行毫秒级落盘，不是退出才写。
--
-- 两条出口
-- --------
--   1. 面板（:GodotDebugLog）—— 原始日志，行为和 Godot 自己的 Output 面板一致
--   2. 诊断（vim.diagnostic）—— 把报错解析成真正的 LSP 诊断，于是
--      Trouble / vim.diagnostic.jump / 行号符号 / 内联提示全都直接可用
local config = require("godot-instance.config").options
local state = require("godot-instance.state")
local util = require("godot-instance.util")
local project = require("godot-instance.project")

local uv = util.uv
local notify = util.notify
local normalize_path = util.normalize_path
local path_key = util.path_key

local M = {}

-- 运行期状态。health.lua 会读它做体检。
M.state = {
    buf = nil,
    win = nil,
    timer = nil,
    path = nil,
    root = nil,
    root_key = nil,
    offset = 0,
    partial = "",
    total = 0,
    last_run_at = nil,
    rotated = false,
    last_redraw_at = nil,
}

------------------------------------------------------------
-- 配置读取
--
-- 不要在模块加载时把 config.debuglog 整张表别名下来：config.setup() 是
-- 就地合并，但 debuglog 这个子表会被换成合并后的新表。
------------------------------------------------------------

local function opts()
    return config.debuglog or {}
end

local function diagnostics_enabled()
    local d = opts().diagnostics

    return d == nil or d.enabled ~= false
end

------------------------------------------------------------
-- 项目定位
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

    -- 兜底：这个 Nvim 托管的项目。用户可能在项目外的 buffer 里按快捷键。
    return state.active_root
end

------------------------------------------------------------
-- 日志路径
------------------------------------------------------------

local function log_file_for_root(root)
    if not root then
        return nil
    end

    local configured = opts().log_path

    if configured and configured ~= "" then
        return configured
    end

    local dir = project.user_data_dir(root)

    if not dir then
        return nil
    end

    return vim.fs.joinpath(dir, "logs", "godot.log")
end

--- 推导日志路径。
---
--- 直接按项目名算出路径就返回，**不管文件是否已经存在** —— 游戏第一次跑
--- 之前它本来就不存在，定时器会自己等到它出现。
---
--- 只有算出来的路径不存在、又能在 app_userdata 里按归一化名字精确匹配到
--- 时，才用匹配结果兜住 Godot sanitize 规则的差异。绝不用「最近改动的
--- 那个」兜底：那会安静地连到别的项目的日志上（实测踩过）。
local function resolve_log_path(root)
    local configured = opts().log_path

    if configured and configured ~= "" then
        return configured
    end

    local path = log_file_for_root(root)

    if path and vim.fn.filereadable(path) == 1 then
        return path
    end

    local dir = project.user_data_dir(root)
    local name = dir and vim.fs.basename(dir)

    if dir and name and name ~= "" then
        local parent = vim.fs.dirname(dir)
        local target = util.normalize_match(name)

        for _, candidate in ipairs(vim.fn.glob(parent .. "/*/logs/godot.log", false, true)) do
            local dirname = vim.fn.fnamemodify(vim.fn.fnamemodify(candidate, ":h:h"), ":t")

            if util.normalize_match(dirname) == target then
                return candidate
            end
        end
    end

    return path
end

-- 前向声明：定义在下面的「诊断：解析」段。sync_root() 要用它重置解析状态，
-- 而 sync_root() 在上面，所以这里必须先占位，否则闭包抓到的是全局 nil。
local reset_parse

--- 项目切换时重新推导日志路径。
---
--- 判断是否切换必须以「解析出来的日志路径」为准，不能比项目根字符串：
--- getcwd() 给 `D:\a\b`，buffer 文件名给 `D:/a/b`，同一个目录两种写法，
--- 按字符串比会把「打开第一个 .gd 文件」误判成换项目，offset 清零重读，
--- 日志就重复一整遍（实测踩过）。
local function sync_root()
    local root = current_root()
    local key = root and path_key(root) or nil

    -- 根没变就直接沿用，别每次都去 glob app_userdata
    if key == M.state.root_key and M.state.path then
        return M.state.path
    end

    local path = resolve_log_path(root)

    if path ~= M.state.path then
        M.state.offset = 0
        M.state.partial = ""
        reset_parse()
    end

    M.state.root = root
    M.state.root_key = key
    M.state.path = path

    return path
end

------------------------------------------------------------
-- 诊断：解析
------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("godot_instance_debuglog")

-- 报错行的前缀白名单。
--
-- 注意：Lua 模式里没有 | 交替，所以不能写成
-- "^%s*(SCRIPT ERROR|ERROR|...):" —— 那样 | 是字面量，永远匹配不上。
-- 这里先粗捕获 "全大写+空格:" 的前缀，再用白名单过滤。
local ERROR_KINDS = {
    ["ERROR"] = true,
    ["SCRIPT ERROR"] = true,
    ["SHADER ERROR"] = true,
    ["USER ERROR"] = true,
    ["WARNING"] = true,
    ["USER WARNING"] = true,
}

-- ERROR: xxx / SCRIPT ERROR: xxx / SHADER ERROR: xxx / WARNING: xxx
local ERROR_PATTERN = "^%s*([A-Z][A-Z ]*):%s*(.-)%s*$"

--    at: _ready (res://main.gd:7)
--        [0] _ready (res://main.gd:7)
--    at: (null) (res://broken.gdshader:4)     <- 真实渲染器下的 shader 报错
local AT_LINE = "^%s*at:"
local FRAME_LINE = "^%s*%[%d+%]"

-- Godot 报 shader 错时会在 SHADER ERROR 之前把出错的源码打出来，
-- 用 E 标出出错行：
--
--     --Main Shader--               <- headless/dummy 渲染器：固定标签，没路径
--         2 | 
--         3 | void fragment() {
--     E   4->  COLOR = vec4(undeclared_variable, 0.0, 0.0, 1.0);
--         5 | }
--     SHADER ERROR: Unknown identifier in expression: '...'.
--        at: (null) (:4)
--
-- 实测真实 Vulkan 渲染器下段头会写成 `--res://foo.gdshader--`，at: 行也
-- 带路径，那种情况走下面的 parse_location 就够了。只有 dummy 渲染器
-- （headless）才两头都没有文件名，那时才需要拿出错行源码去反查。
local SHADER_HEADER_PATTERN = "^%-%-.-%-%-%s*$"
local SHADER_MARK_PATTERN = "^E%s+(%d+)->%s?(.*)$"

-- 资源类报错会把文件写进消息里：
--     ERROR: Parse Error: ... [Resource file res://main.tscn:9]
local RESOURCE_FILE_PATTERN = "%[Resource file (res://[^:]+):(%d+)%]"

local SEVERITY = {
    ["ERROR"] = vim.diagnostic.severity.ERROR,
    ["SCRIPT ERROR"] = vim.diagnostic.severity.ERROR,
    ["SHADER ERROR"] = vim.diagnostic.severity.ERROR,
    ["USER ERROR"] = vim.diagnostic.severity.ERROR,
    ["WARNING"] = vim.diagnostic.severity.WARN,
    ["USER WARNING"] = vim.diagnostic.severity.WARN,
}

-- 正在攒的报错块：{ kind, message, locations = { { func, file, lnum }, ... } }
local pending = nil

-- 最近一次 shader 出错行（来自上面的 E 标记），用于反查文件
local shader_mark = nil

-- 已发布的诊断：path_key -> bufnr，path_key -> { diagnostic, ... }
local published = {
    buffers = {},
    items = {},
    -- path_key -> { mtime = <发布时间>, hash = <内容指纹> }。
    --
    -- 游戏日志里的报错属于**过去那一轮运行**。你把脚本改好之后，旧报错就
    -- 已经不对应当前这一版代码了，但它还挂在诊断列表里 —— 而日志文件不会
    -- 因此变化，`clear_diagnostics` 又只在「新的一轮运行」时才跑，于是表现
    -- 就是「明明改对了还在报，只有重启 Nvim 才消失」。
    --
    -- 只看 mtime 不够：同一份代码再保存一次也会改 mtime，那时候代码没改，
    -- 诊断不该消失（否则就是「我没动代码，报错却自己没了」）。所以连内容
    -- 指纹一起记，只有内容真的变了才作废。
    stamps = {},
}

--- 文件内容指纹。读不到就返回 nil。
--- @return string?
local function file_hash(path)
    local ok, lines = pcall(vim.fn.readfile, path, "b")

    if not ok or type(lines) ~= "table" then
        return nil
    end

    return vim.fn.sha256(table.concat(lines, "\n"))
end

-- 其它诊断来源（编辑器报错桥）。只在展示时并入，不参与清空。
local extra_sources = {}

--- 注册一个额外的诊断来源。
--- @param fn fun(): table[] 返回 { bufnr, path, item } 列表
function M.register_diagnostics(fn)
    for _, existing in ipairs(extra_sources) do
        if existing == fn then
            return
        end
    end

    extra_sources[#extra_sources + 1] = fn
end

function reset_parse()
    pending = nil
    shader_mark = nil
end

--- 从 at: / [N] 行里取出位置。
---
--- 不能要求文件名紧跟在第一个括号里：shader 报错会写成
---     at: (null) (res://broken.gdshader:4)
--- 所以直接在这一行里找 res://path:N，找不到再退回任意 (file:line)。
--- @return table? { file, lnum, func }
local function parse_location(line)
    if not (line:match(AT_LINE) or line:match(FRAME_LINE)) then
        return nil
    end

    local func = line:match("^%s*at:%s*(.-)%s*%(") or line:match("^%s*%[%d+%]%s*(.-)%s*%(") or ""

    local res, lnum = line:match("(res://[^%s:)]+):(%d+)")

    if res then
        return { file = res, lnum = tonumber(lnum), func = func }
    end

    local file, plain = line:match("%(([^()]-):(%d+)%)")

    if file then
        return { file = file, lnum = tonumber(plain), func = func }
    end

    return nil
end

--- res://main.gd -> <root>/main.gd
local function res_to_path(res)
    if not res or not res:match("^res://") then
        return nil
    end

    local root = M.state.root

    if not root then
        return nil
    end

    return normalize_path(vim.fs.joinpath(root, (res:gsub("^res://", ""))))
end

------------------------------------------------------------
-- gdshader 报错的文件反查
--
-- Godot 的 shader 报错不带文件名，只能拿出错行的源码文本去项目里的
-- shader 文件对（详见 SHADER_MARK_PATTERN 上面的注释）。
------------------------------------------------------------

-- 项目里所有 Godot shader 源文件（含 include），按 root 缓存
local shader_files_cache = { root = nil, files = nil }

local function project_shader_files()
    local root = M.state.root

    if not root then
        return {}
    end

    if shader_files_cache.root == root and shader_files_cache.files then
        return shader_files_cache.files
    end

    local files = {}

    for _, pattern in ipairs({ "**/*.gdshader", "**/*.gdshaderinc" }) do
        for _, file in ipairs(vim.fn.globpath(root, pattern, false, true)) do
            files[#files + 1] = file
        end
    end

    shader_files_cache.root = root
    shader_files_cache.files = files

    return files
end

-- 反查结果缓存：key -> path | false
local shader_lookup_cache = {}

--- 用「出错行的源码文本 + 行号」反查是哪个 shader 文件。
---
--- 行号对得上、内容也一致的文件只有一个才认定；对不上或有歧义就不猜
--- （宁可没有诊断，也不要指到错误的文件上）。
--- @return string?
local function resolve_shader_file(lnum, text)
    lnum = tonumber(lnum)
    text = text and vim.trim(text) or ""

    if not lnum or text == "" then
        return nil
    end

    local key = lnum .. "\0" .. text
    local cached = shader_lookup_cache[key]

    if cached ~= nil then
        return cached or nil
    end

    local matches = {}

    for _, file in ipairs(project_shader_files()) do
        -- 只读到出错行为止，别为了对一行把整个文件读进来
        local ok, lines = pcall(vim.fn.readfile, file, "", lnum)

        if ok and type(lines) == "table" and lines[lnum] and vim.trim(lines[lnum]) == text then
            matches[#matches + 1] = normalize_path(file)

            if #matches > 1 then
                break
            end
        end
    end

    if #matches == 1 then
        shader_lookup_cache[key] = matches[1]
        return matches[1]
    end

    shader_lookup_cache[key] = false

    return nil
end

local function add_diagnostic(path, item)
    local key = path_key(path)

    if not key then
        return
    end

    local bufnr = published.buffers[key]

    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        -- 诊断必须挂在 buffer 上，Trouble / 跳转才有东西可指。
        -- 文件读不到就别造 buffer 了，省得留一堆空壳。
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

    --------------------------------------------------------
    -- 记下发布时的 mtime + 内容指纹：这条诊断描述的是**这一版**文件。
    -- 文件之后真的改动了（见 expire_changed_files），它就作废。
    --------------------------------------------------------

    if published.stamps[key] == nil then
        published.stamps[key] = {
            mtime = vim.fn.getftime(path),
            hash = file_hash(path),
        }
    end

    vim.diagnostic.set(ns, bufnr, list)
end

--- 清掉某个文件的诊断。
local function clear_diagnostics_for(path)
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
    published.stamps[key] = nil
end

--- 文件改动过就把它身上的旧诊断作废。
---
--- 每轮 poll 都会检查：改好了但游戏没有重新跑（日志没有新增），旧报错
--- 仍然挂在列表里 —— 这里负责把它清掉。
---
--- mtime 变了**不等于**内容变了：又保存了一次同样的代码时，诊断要留着。
local function expire_changed_files()
    local stale = {}

    for key, bufnr in pairs(published.buffers) do
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            local path = vim.api.nvim_buf_get_name(bufnr)
            local stamp = vim.fn.getftime(path)
            local known = published.stamps[key]

            if stamp > 0 and known and known.mtime and stamp ~= known.mtime then
                local now_hash = file_hash(path)

                if known.hash and now_hash and known.hash == now_hash then
                    -- 内容没变（只是又保存了一次）：保留诊断，只推进 mtime 快照
                    known.mtime = stamp
                else
                    stale[#stale + 1] = path
                end
            end
        end
    end

    for _, path in ipairs(stale) do
        clear_diagnostics_for(path)
    end
end

local function emit(path, lnum, block, user_data)
    add_diagnostic(path, {
        lnum = math.max((tonumber(lnum) or 1) - 1, 0),
        col = 0,
        severity = SEVERITY[block.kind] or vim.diagnostic.severity.ERROR,
        message = block.message,
        source = "godot",
        code = block.kind,
        user_data = user_data or {},
    })
end

--- 把 pending 里的报错发布成诊断。
---
--- 位置按可靠性依次尝试：
---   1. 栈帧里的 res:// —— 最准
---   2. 消息里带的 [Resource file res://path:N]
---   3. gdshader：拿出错行源码反查文件
---
--- 引擎路径（core/...、modules/...）在磁盘上根本不存在，永远不用。
local function publish_pending()
    local block = pending

    if not block or not diagnostics_enabled() then
        return false
    end

    --------------------------------------------------------
    -- 1) 栈帧
    --------------------------------------------------------

    for _, loc in ipairs(block.locations) do
        local path = res_to_path(loc.file)

        if path then
            emit(path, loc.lnum, block, { func = loc.func })
            return true
        end
    end

    --------------------------------------------------------
    -- 2) 消息里的资源路径
    --------------------------------------------------------

    local res, lnum = block.message:match(RESOURCE_FILE_PATTERN)

    if res then
        local path = res_to_path(res)

        if path then
            emit(path, lnum, block)
            return true
        end
    end

    --------------------------------------------------------
    -- 3) gdshader 反查
    --------------------------------------------------------

    if block.kind == "SHADER ERROR" and block.shader_mark then
        local path = resolve_shader_file(block.shader_mark.lnum, block.shader_mark.text)

        if path then
            emit(path, block.shader_mark.lnum, block, { shader = true })
            return true
        end
    end

    return false
end

local function pending_has_location()
    if not pending then
        return false
    end

    for _, loc in ipairs(pending.locations) do
        if loc.file:match("^res://") then
            return true
        end
    end

    if pending.message and pending.message:match(RESOURCE_FILE_PATTERN) then
        return true
    end

    return pending.kind == "SHADER ERROR" and pending.shader_mark ~= nil
end

--- 报错块确定结束了（下一条报错开始）：能发布就发布，然后丢掉。
local function finish_block()
    if pending then
        publish_pending()
        pending = nil
    end
end

--- 一批日志读完：攒够位置就发布，但没攒够的留着等下一批 ——
--- 日志是逐行 flush 的，一次 poll 很可能只拿到 "ERROR:" 那一行。
local function publish_if_ready()
    if pending_has_location() then
        publish_pending()
        pending = nil
    end
end

local function feed_line(line)
    --------------------------------------------------------
    -- shader 源码片段：记住被 E 标出的出错行（后面反查文件要用）
    --------------------------------------------------------

    local mark_lnum, mark_text = line:match(SHADER_MARK_PATTERN)

    if mark_lnum then
        shader_mark = { lnum = tonumber(mark_lnum), text = mark_text }
    elseif line:match(SHADER_HEADER_PATTERN) then
        shader_mark = nil
    end

    local kind, message = line:match(ERROR_PATTERN)

    if kind and ERROR_KINDS[kind] then
        finish_block()
        pending = {
            kind = kind,
            message = message,
            locations = {},
            -- 出错行在 SHADER ERROR 之前打出，所以这时已经攒到了
            shader_mark = shader_mark,
        }
        return
    end

    if not pending then
        return
    end

    local loc = parse_location(line)

    if loc then
        pending.locations[#pending.locations + 1] = loc
    end
end

------------------------------------------------------------
-- 诊断：对外操作
------------------------------------------------------------

--- 清掉本插件发布的全部诊断（不动别的来源）。
function M.clear_diagnostics()
    for _, bufnr in pairs(published.buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.diagnostic.reset(ns, bufnr)
        end
    end

    published.buffers = {}
    published.items = {}
    published.stamps = {}

    if vim.diagnostic.reset then
        pcall(vim.diagnostic.reset, ns)
    end
end

--- 本插件发布的全部诊断，扁平化后的列表。
--- @return table[] { bufnr, path, item }
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

    --------------------------------------------------------
    -- 并入其它来源（编辑器报错桥）。
    -- 只影响展示（diagnostics / quickfix / :GodotDebugErrors），
    -- 不影响清空时机：编辑器报错不该被「游戏又跑了一次」清掉。
    --------------------------------------------------------

    for _, fn in ipairs(extra_sources) do
        local ok, extra = pcall(fn)

        if ok and type(extra) == "table" then
            for _, entry in ipairs(extra) do
                out[#out + 1] = entry
            end
        end
    end

    table.sort(out, function(a, b)
        if a.path == b.path then
            return a.item.lnum < b.item.lnum
        end

        return a.path < b.path
    end)

    return out
end

--- 诊断条数。
function M.count()
    return #M.diagnostics()
end

--- 当前状态快照（health.lua 用）。
--- @return table { root, path, exists, count }
function M.info()
    local path = M.state.path or sync_root()

    return {
        root = M.state.root,
        path = path,
        exists = path ~= nil and vim.fn.filereadable(path) == 1,
        count = M.count(),
    }
end

------------------------------------------------------------
-- 展示：Trouble 优先，quickfix 兜底
------------------------------------------------------------

local function trouble_available()
    if vim.fn.exists(":Trouble") == 2 then
        return true
    end

    -- trouble 常常是 lazy 的（cmd = "Trouble"），require 会把它拉起来。
    -- 没装的话这里直接失败，于是回退到 quickfix —— 不构成硬依赖。
    local ok = pcall(require, "trouble")

    return ok and vim.fn.exists(":Trouble") == 2
end

--- 把 Godot 报错灌进 quickfix（不依赖任何插件）。
function M.quickfix()
    local list = M.diagnostics()

    if #list == 0 then
        notify("还没有解析到 Godot 报错", vim.log.levels.INFO)
        return
    end

    local items = {}

    for _, entry in ipairs(list) do
        items[#items + 1] = {
            bufnr = entry.bufnr,
            lnum = entry.item.lnum + 1,
            col = (entry.item.col or 0) + 1,
            text = entry.item.message,
            type = entry.item.severity == vim.diagnostic.severity.ERROR and "E" or "W",
        }
    end

    vim.fn.setqflist({}, " ", {
        title = "Godot debug errors",
        items = items,
    })

    vim.cmd("copen")
end

--- 展示 Godot 报错：优先 trouble.nvim，没有就退回 quickfix。
function M.errors()
    local list = M.diagnostics()

    if #list == 0 then
        notify("还没有解析到 Godot 报错。先在 Godot 里按 F5 / F6 跑一次。", vim.log.levels.INFO)
        return
    end

    if trouble_available() then
        vim.cmd("Trouble diagnostics toggle")
        return
    end

    M.quickfix()
end

------------------------------------------------------------
-- 跳转
------------------------------------------------------------

--- 把某个窗口从面板上挪开，避免跳转时把面板窗口顶成代码窗口。
local function leave_panel_window()
    local panel_buf = M.state.buf

    if not panel_buf or vim.api.nvim_get_current_buf() ~= panel_buf then
        return
    end

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) ~= panel_buf then
            vim.api.nvim_set_current_win(win)
            return
        end
    end

    -- 只剩面板一个窗口：那就在原地打开文件（总比不跳强）
end

--- 在当前窗口打开 path 并定位到 lnum（1-based）。
local function open_location(path, lnum)
    if not path or path == "" then
        return false
    end

    leave_panel_window()

    local bufnr = vim.fn.bufadd(path)

    if vim.fn.bufloaded(bufnr) ~= 1 then
        vim.fn.bufload(bufnr)
    end

    vim.api.nvim_win_set_buf(0, bufnr)
    pcall(vim.fn.cursor, math.max(tonumber(lnum) or 1, 1), 1)

    return true
end

--- 在 Godot 报错之间跳转。
---
--- 不用 vim.diagnostic.jump：它的行为跟当前 buffer 绑定，光标停在调试面板
--- 里时就跳不动（实测 "No more valid diagnostics to move to"）。这里直接按
--- 自己的诊断表算，从面板里、从任何 buffer 里都能跳。
---
--- 关键是按「光标在整张表里的位置」前进/后退，而不是只在当前 buffer 里找 ——
--- 否则跳到一个文件里之后就出不去了（只在同一条上打转，实测踩过）。
--- @param direction number > 0 下一条，< 0 上一条
local function jump(direction)
    local list = M.diagnostics()

    if #list == 0 then
        notify("还没有解析到 Godot 报错。先在 Godot 里按 F5 / F6 跑一次。", vim.log.levels.INFO)
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local line = vim.fn.line(".")

    -- 光标位置映射成列表下标；不在列表里（例如停在面板上）就是 0
    local cursor_index = 0

    for i, entry in ipairs(list) do
        if entry.bufnr == bufnr and entry.item.lnum + 1 <= line then
            cursor_index = i
        end
    end

    local target

    if direction > 0 then
        target = list[cursor_index + 1] or list[1]
    else
        target = list[cursor_index - 1] or list[#list]
    end

    open_location(target.path, target.item.lnum + 1)
end

function M.next()
    jump(1)
end

function M.prev()
    jump(-1)
end

--- 跳到当前光标所在行提到的 res:// 位置（面板里的 <CR>）。
function M.jump_at_cursor()
    local line = vim.api.nvim_get_current_line()
    local res, lnum = line:match("(res://[^%s:)]+):(%d+)")

    if not res then
        notify("这一行没有可跳转的 res:// 位置", vim.log.levels.INFO)
        return
    end

    local path = res_to_path(res)

    if not path or vim.fn.filereadable(path) ~= 1 then
        notify("找不到文件：" .. tostring(path or res), vim.log.levels.WARN)
        return
    end

    open_location(path, tonumber(lnum) or 1)
end

------------------------------------------------------------
-- 面板 buffer
------------------------------------------------------------

--- 这个 buffer 号现在还是不是我们的面板 buffer。
---
--- 和窗口 id 一样，buffer 号也会被 Neovim 回收给新 buffer。所以不能只信
--- M.state.buf：那个号可能已经属于用户的某个文件了，此时往它里面写日志
--- 就会把日志灌进用户正在编辑的文件里。用 buffer 名字做身份校验。
local PANEL_BUFFER_NAME = "godot://debuglog"

--- @return integer?
local function panel_buffer()
    local buf = M.state.buf

    if not buf or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
        return nil
    end

    if vim.api.nvim_buf_get_name(buf) ~= PANEL_BUFFER_NAME then
        return nil
    end

    return buf
end

local function ensure_buffer()
    --------------------------------------------------------
    -- 1) 记着的那个 id 现在还是我们的面板 buffer 吗
    --------------------------------------------------------

    local buf = panel_buffer()

    if buf then
        return buf
    end

    --------------------------------------------------------
    -- 2) 按名字在全部 buffer 里找回面板 buffer。
    --
    -- 不能只信 M.state.buf：
    --   * buffer 号会被 Neovim 回收给别的 buffer —— 往那个号里写日志
    --     就等于把日志灌进用户正在编辑的文件里；
    --   * 名字可能还被一个我们跟丢了的 buffer 占着 —— 不处理的话下面
    --     nvim_buf_set_name 会因为重名直接报错。
    --------------------------------------------------------

    for _, other in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(other) and vim.api.nvim_buf_get_name(other) == PANEL_BUFFER_NAME then
            if vim.api.nvim_buf_is_loaded(other) then
                M.state.buf = other
                return other
            end

            -- 被 :bunload 过：内容没了但名字还占着，删掉腾位置
            pcall(vim.api.nvim_buf_delete, other, { force = true })
        end
    end

    M.state.buf = nil

    buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].buflisted = false
    vim.bo[buf].filetype = "godotdebug"
    vim.bo[buf].modifiable = true
    vim.bo[buf].modified = false

    vim.api.nvim_buf_set_name(buf, "godot://debuglog")

    vim.keymap.set("n", "q", "<cmd>close<cr>", {
        buffer = buf,
        silent = true,
        desc = "关闭 Godot 调试面板",
    })

    vim.keymap.set("n", "<CR>", function()
        M.jump_at_cursor()
    end, {
        buffer = buf,
        silent = true,
        desc = "跳到这一行的 res:// 位置",
    })

    M.state.buf = buf

    return buf
end

local function set_lines(lines)
    local buf = ensure_buffer()

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false

    M.state.total = #lines
end

local function append_lines(lines)
    if #lines == 0 then
        return
    end

    local buf = ensure_buffer()

    vim.bo[buf].modifiable = true

    -- 缓冲区里只有占位提示的话，追加前先清掉
    local existing = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    if M.state.total == 0 and #existing > 0 then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end

    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    vim.bo[buf].modified = false

    M.state.total = M.state.total + #lines

    local count = vim.api.nvim_buf_line_count(buf)
    local overflow = count - (opts().max_lines or 5000)

    if overflow > 0 then
        vim.api.nvim_buf_set_lines(buf, 0, overflow, false, {})
        M.state.total = M.state.total - overflow
    end

    local win = M.state.win

    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        local cursor = vim.api.nvim_win_get_cursor(win)
        local last = vim.api.nvim_buf_line_count(buf)

        if cursor[1] >= last - #lines - 1 then
            vim.api.nvim_win_set_cursor(win, { last, 0 })
        end
    end
end

local highlight_patterns = {
    { "ErrorMsg", [[\v(SCRIPT ERROR|ERROR:|ERROR )]] },
    { "DiagnosticWarn", [[\v(WARNING|WARN:)]] },
    { "DiagnosticInfo", [[\v^\s*(\[%d+\]|at:)\s]] },
    { "Special", [[\vres://[^ )]+:\d+]] },
    { "Title", [[\v^Godot Engine v]] },
}

local function apply_highlights(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end

    vim.api.nvim_win_call(win, function()
        for _, entry in ipairs(highlight_patterns) do
            pcall(vim.fn.matchadd, entry[1], entry[2])
        end
    end)
end

--- 取出「确实是面板窗口」的那个窗口。
---
--- 不能只信 M.state.win：窗口被关掉之后这个 id 就悬空了，而 Neovim 会把
--- 窗口 id 回收给新窗口用 —— 于是 nvim_win_is_valid(旧 id) 为真，面板就被
--- 塞进用户的编辑窗口里，表现是「日志内容覆盖在当前 buffer 上，切 buffer
--- 才恢复」（实测踩过）。所以必须确认那个窗口现在显示的**就是**面板 buffer。
--- @return integer?
local function panel_window()
    local win = M.state.win

    if not win or not vim.api.nvim_win_is_valid(win) then
        M.state.win = nil
        return nil
    end

    -- 面板永远不是浮窗；是浮窗说明这个 id 已经被回收了
    if vim.api.nvim_win_get_config(win).relative ~= "" then
        M.state.win = nil
        return nil
    end

    if not M.state.buf or vim.api.nvim_win_get_buf(win) ~= M.state.buf then
        M.state.win = nil
        return nil
    end

    -- buffer 号也可能被回收，一并校验身份
    if vim.api.nvim_buf_get_name(M.state.buf) ~= PANEL_BUFFER_NAME then
        M.state.win = nil
        return nil
    end

    return win
end

local function open_panel()
    local buf = ensure_buffer()

    local existing = panel_window()

    if existing then
        apply_highlights(existing)
        return existing
    end

    local win = nil
    local position = opts().position or "bottom"
    local size = opts().size or 0.3

    if position == "float" then
        local width = math.max(math.floor(vim.o.columns * 0.8), 60)
        local height = math.max(math.floor(vim.o.lines * 0.35), 10)

        win = vim.api.nvim_open_win(buf, true, {
            relative = "editor",
            width = width,
            height = height,
            row = math.max(math.floor((vim.o.lines - height) / 2 - 1), 0),
            col = math.max(math.floor((vim.o.columns - width) / 2), 0),
            style = "minimal",
            border = "rounded",
            title = " Godot Debug Log ",
            title_pos = "center",
        })
    else
        local lines = math.max(math.floor(vim.o.lines * size), 8)

        ----------------------------------------------------
        -- 先记下当前有哪些窗口。开分屏会触发 BufEnter / WinNew 之类的
        -- autocmd，焦点可能被别的插件挪走 —— 所以不能假设开完之后当前
        -- 窗口就是新建的那个，得按窗口集合的差集去找。
        ----------------------------------------------------

        local before = {}

        for _, w in ipairs(vim.api.nvim_list_wins()) do
            before[w] = true
        end

        if position == "right" then
            vim.cmd(("botright %dvsplit"):format(math.max(math.floor(vim.o.columns * size), 40)))
        else
            vim.cmd(("botright %dsplit"):format(lines))
        end

        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if not before[w] then
                win = w
                break
            end
        end

        win = win or vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
    end

    M.state.win = win

    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = false

    apply_highlights(win)
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })

    return win
end

------------------------------------------------------------
-- 轮询
------------------------------------------------------------

-- 前向声明：定义在 poll() 下面。Lua 里 local function 的作用域从定义处
-- 才开始，poll() 里直接用名字会解析成全局 nil（实测报过
-- "attempt to call global 'redraw_after_output' (a nil value)"）。
local redraw_after_output

local function poll()
    --------------------------------------------------------
    -- 先让改动过的文件上的旧诊断作废。
    --
    -- 必须放在所有提前 return 之前：改好脚本之后日志通常**不会**再有新增
    -- （游戏没重跑），下面那些 `return` 会直接跳过清理，旧报错就一直挂着。
    --------------------------------------------------------

    expire_changed_files()

    if not M.state.path and not sync_root() then
        return
    end

    local file = io.open(M.state.path, "rb")

    if not file then
        return
    end

    local size = file:seek("end") or 0

    --------------------------------------------------------
    -- 文件变小 = 被轮转。Godot 每跑一次都会把旧的 godot.log
    -- 改名成 godot<时间戳>.log，再新建一个空的。
    --
    -- 这时从 0 重读会把已经显示过的内容再显示一遍，所以直接清空
    -- 面板、镜像新文件 —— 这也是 Godot 自己 Output 面板的行为。
    -- 历史没丢，轮转出来的 godot<时间戳>.log 还在磁盘上。
    --------------------------------------------------------

    local rotated = false

    if size < M.state.offset then
        M.state.offset = 0
        M.state.partial = ""
        rotated = true
    end

    if size == M.state.offset then
        file:close()
        return
    end

    file:seek("set", M.state.offset)

    local data = file:read("*a") or ""

    M.state.offset = size
    file:close()

    if vim.env.GODOT_INSTANCE_DEBUGLOG_TRACE then
        local tf = io.open(vim.env.GODOT_INSTANCE_DEBUGLOG_TRACE, "a")

        if tf then
            tf:write(("[poll] size=%d read_from=%d len=%d rotated=%s\n"):format(
                size,
                size - #data,
                #data,
                tostring(rotated)
            ))
            tf:close()
        end
    end

    local text = M.state.partial .. data
    local lines = vim.split(text, "\r?\n", { plain = false })

    --------------------------------------------------------
    -- 最后一段可能是不完整的行，留到下次
    --------------------------------------------------------

    if text:sub(-1) ~= "\n" then
        M.state.partial = table.remove(lines) or ""
    else
        M.state.partial = ""

        if lines[#lines] == "" then
            table.remove(lines)
        end
    end

    if #lines == 0 then
        return
    end

    --------------------------------------------------------
    -- 新一轮运行：清掉上一轮的诊断，按需自动弹面板
    --------------------------------------------------------

    local new_run = false

    for _, line in ipairs(lines) do
        if line:match("^Godot Engine v") then
            new_run = true
            break
        end
    end

    if rotated then
        set_lines({})
        M.state.total = 0
        reset_parse()
        M.clear_diagnostics()
        -- 刚清空过，不需要紧接着再插一条分隔线
        M.state.last_run_at = util.now_ms()
    elseif new_run then
        -- 同一轮启动里 Godot 可能先写 banner、随后又截断重写，banner 会被
        -- 读到两次。按时间去抖，免得连着冒出两条「新的运行」分隔线。
        local now = util.now_ms()

        if not M.state.last_run_at or (now - M.state.last_run_at) > 3000 then
            M.state.last_run_at = now

            reset_parse()
            M.clear_diagnostics()

            append_lines({ "", ("──────── 新的运行 %s ────────"):format(os.date("%H:%M:%S")) })

            if opts().auto_open ~= false and not panel_window() then
                vim.schedule(function()
                    open_panel()
                end)
            end
        end
    end

    for _, line in ipairs(lines) do
        feed_line(line)
    end

    publish_if_ready()

    append_lines(lines)

    redraw_after_output()
end

--- 终端残影兜底。
---
--- 如果 Godot 编辑器（以及它 F5 起的游戏）和 Nvim 共用同一个终端，游戏的
--- stdout 会直接写进 Nvim 的画面 —— 文字从第 0 列写进去、压住行号栏，
--- 光标扫过才恢复。那不是 Nvim 画的，Nvim 拦不住。
---
--- 但那种写入和日志增长是同一个进程同时发生的，所以一有新日志就整屏重绘
--- 一次，能把残影压到一个轮询周期之内。按 redraw_throttle_ms 节流。
--- 注意：这里是 function 而不是 local function —— 上面已经前向声明过，
--- 写成 local function 会新建一个局部变量把前向声明遮蔽掉，poll() 那边
--- 拿到的仍然是 nil。
function redraw_after_output()
    if opts().redraw_on_output == false then
        return
    end
    -- headless 没有屏幕；而且实测在 headless 下从调度回调里 :redraw! 会把
    -- 事件循环卡住
    if #vim.api.nvim_list_uis() == 0 then
        return
    end

    local now = util.now_ms()
    local throttle = opts().redraw_throttle_ms or 500

    if M.state.last_redraw_at and (now - M.state.last_redraw_at) < throttle then
        return
    end

    M.state.last_redraw_at = now
    pcall(vim.cmd, "redraw!")
end

local function ensure_timer()
    if M.state.timer then
        return
    end

    local interval = opts().interval_ms or 200
    local timer = uv.new_timer()

    if not timer then
        return
    end

    M.state.timer = timer

    timer:start(interval, interval, vim.schedule_wrap(function()
        local ok, err = pcall(poll)

        if not ok then
            -- 出错就停掉，别每 200ms 刷一次屏
            timer:stop()
            M.state.timer = nil
            notify("调试日志轮询出错：\n" .. tostring(err), vim.log.levels.ERROR)
        end
    end))
end

------------------------------------------------------------
-- 公共 API
------------------------------------------------------------

function M.show()
    local path = sync_root()

    if not path then
        notify("当前 buffer 不在 Godot 项目里（找不到 project.godot）", vim.log.levels.WARN)
        return false
    end

    ensure_timer()

    --------------------------------------------------------
    -- 面板 buffer 被 :bd / :bdelete 之类的操作搞掉之后，下次打开拿到的是
    -- 一个空 buffer，而 state.offset 还停在文件末尾 —— 不重置的话就是一片
    -- 空白。这里检测到 buffer 不可用了就把读取位置、解析状态、诊断全部
    -- 重置，下面按「首次打开」的路径把已有日志重新灌一遍。
    --
    -- 注意 :bdelete 只是 unload：句柄仍然 valid，所以必须连 loaded 和
    -- buffer 名字一起判（走 panel_buffer 的身份校验）。
    --------------------------------------------------------

    if not panel_buffer() then
        M.state.offset = 0
        M.state.partial = ""
        M.state.total = 0
        reset_parse()
        M.clear_diagnostics()
    end

    if vim.fn.filereadable(path) == 1 then
        if M.state.offset == 0 then
            local file = io.open(path, "rb")

            if file then
                local data = file:read("*a") or ""
                file:close()

                local lines = vim.split(data, "\r?\n", { plain = false })

                if lines[#lines] == "" then
                    table.remove(lines)
                end

                M.state.offset = #data
                M.state.partial = ""
                set_lines(lines)

                -- 已经存在的日志也解析一遍，这样一打开就有诊断
                for _, line in ipairs(lines) do
                    feed_line(line)
                end

                publish_if_ready()
            end
        end
    else
        set_lines({
            "# Godot 调试日志",
            "",
            "日志文件还不存在：",
            "  " .. path,
            "",
            "在 Godot 编辑器里按 F5 / F6 跑一次游戏，内容会自动出现在这里。",
            "",
            "如果跑了还是没有内容，检查项目的 debug/file_logging/ 设置：",
            "桌面平台默认是开的（enable_file_logging.pc = true），",
            "被显式关掉的话游戏就不会写日志文件。",
        })

        M.state.total = 0
    end

    open_panel()

    return true
end

function M.hide()
    local win = panel_window()

    if win then
        pcall(vim.api.nvim_win_close, win, true)
    end

    M.state.win = nil
end

function M.toggle()
    if panel_window() then
        M.hide()
    else
        M.show()
    end
end

--- 往面板追加几行（编辑器报错桥用）。
--- 面板没开着也会写进 buffer，之后打开就能看到。
function M.append_panel(lines)
    append_lines(lines)
end

--- 清空面板和诊断（日志文件本身不动）。
function M.clear()
    M.state.offset = 0
    M.state.partial = ""
    set_lines({})
    M.state.total = 0
    reset_parse()
    M.clear_diagnostics()

    if M.state.path and vim.fn.filereadable(M.state.path) == 1 then
        local file = io.open(M.state.path, "rb")

        if file then
            M.state.offset = file:seek("end") or 0
            file:close()
        end
    end

    notify("面板和诊断已清空（日志文件本身没动）", vim.log.levels.INFO)
end

--- 显示日志路径（同时塞进剪贴板）。
function M.path()
    local path = M.state.path or sync_root()

    if path then
        notify("Godot 日志：" .. path, vim.log.levels.INFO)
        pcall(vim.fn.setreg, "+", path)
    else
        notify("没找到 Godot 日志（当前不在 Godot 项目里？）", vim.log.levels.WARN)
    end

    return path
end

--- 引导：自动开始盯日志 + 可选快捷键。
function M.setup()
    local group = vim.api.nvim_create_augroup("godot_instance_debuglog", { clear = true })

    vim.api.nvim_create_autocmd({ "BufEnter", "VimEnter" }, {
        group = group,
        callback = function()
            sync_root()

            if M.state.root then
                ensure_timer()
            end
        end,
    })

    --------------------------------------------------------
    -- 面板窗口被关掉时立刻清掉记录。
    --
    -- 不这么做的话 M.state.win 会悬空，而 Neovim 会把窗口 id 回收给新窗口，
    -- 之后 open_panel() 就会把日志塞进用户的编辑窗口（"覆盖当前 buffer"）。
    --------------------------------------------------------

    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(args)
            local closed = tonumber(args.match)

            if not closed or M.state.win ~= closed then
                return
            end

            M.state.win = nil

            ----------------------------------------------------
            -- 面板窗口消失后主窗口会重新占满，整屏要重排。
            --
            -- 某些终端（实测 WezTerm + nvim 0.12）在这种重排后会漏掉
            -- 一部分单元格的重绘，留下「日志残影浮在代码上、光标扫过去
            -- 才恢复」的现象。这里主动整屏重绘一次，把残影抹掉。
            --
            -- 用 schedule：WinClosed 回调期间不适合直接重绘。
            ----------------------------------------------------

            vim.schedule(function()
                -- headless 没有屏幕，重绘没有意义；而且实测在 headless 下
                -- 从调度回调里触发 :redraw! 会把事件循环卡住，所以跳过。
                if #vim.api.nvim_list_uis() == 0 then
                    return
                end

                pcall(vim.cmd, "redraw!")
            end)
        end,
    })

    local dl = opts()

    if dl.keymap then
        vim.keymap.set("n", dl.keymap, function()
            M.toggle()
        end, { desc = "Godot: 调试日志面板" })
    end

    if dl.keymap_errors then
        vim.keymap.set("n", dl.keymap_errors, function()
            M.errors()
        end, { desc = "Godot: 调试报错（Trouble / quickfix）" })
    end
end

return M
