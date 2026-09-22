-- godot-instance.nvim
--
-- Nvim 多开 + Godot 多开的实例管理器。和 godotdev.nvim 配合使用：
-- 每个 Nvim 托管自己那个 Godot 编辑器，各自一套 LSP/DAP 端口 + 项目专属 RPC 管道。
--
-- 公共 API：
--   require("godot-instance").setup(opts)   -- 配置（lazy 的 opts 会自动传进来）
--   require("godot-instance").godotdev(opts) -- 在 godotdev 的 config 里调用
--   :GodotHere / :GodotProject / :GodotRestart / :GodotStop / :GodotStatus / :GodotPaths
local config_mod = require("godot-instance.config")
local config = config_mod.options
local state = require("godot-instance.state")
local util = require("godot-instance.util")
local project = require("godot-instance.project")
local lsp = require("godot-instance.lsp")
local instance = require("godot-instance.instance")
local godotdev = require("godot-instance.godotdev")
local debuglog = require("godot-instance.debuglog")
local bridge = require("godot-instance.bridge")

local notify = util.notify
local same_path = util.same_path
local script_path = util.script_path
local project_root_for_file = project.project_root_for_file
local disable_lsp = lsp.disable_lsp
local stop_dap_session = lsp.stop_dap_session

local M = {}

-- 插件根目录（用 runtime 解析，比 debug.getinfo 可靠：Lua 编译缓存会改路径）。
local function plugin_root()
    local matches = vim.api.nvim_get_runtime_file("lua/godot-instance/init.lua", false)
    if type(matches) == "table" and matches[1] then
        return vim.fn.fnamemodify(matches[1], ":h:h:h")
    end

    return nil
end

local function setup_remote_open()
    _G.godot_remote_open = function(encoded_file, line, column)
        if not vim.base64 or not vim.base64.decode then
            error("vim.base64.decode is unavailable")
        end

        local ok_decode, file = pcall(vim.base64.decode, encoded_file)
        if not ok_decode or not file or file == "" then
            error("invalid Godot remote-open path")
        end

        local root = project_root_for_file(file)
        if not state.active_root or not root or not same_path(root, state.active_root) then
            error("Godot remote-open project does not match this Nvim")
        end

        line = tonumber(line) or 1
        column = tonumber(column) or 1
        line = math.max(math.floor(line), 1)
        column = math.max(math.floor(column), 1)

        vim.schedule(function()
            -- Re-check after scheduling in case the active project changed.
            local scheduled_root = project_root_for_file(file)
            if not state.active_root or not scheduled_root or not same_path(scheduled_root, state.active_root) then
                return
            end

            ----------------------------------------------------
            -- 不要用 nvim_cmd({ cmd = "drop", args = { file } })。
            -- nvim_cmd 的 args 会先拼成命令行再解析，路径里的空格会被当成
            -- 参数分隔符 —— "D:/a/my proj/x.gd" 实测被截成 "D:/a/my"，
            -- 于是双击文件 / 点报错打开的是错的文件。
            -- 这里直接操作 buffer，完全不经过命令行解析。
            ----------------------------------------------------

            local ok_open, open_error = pcall(function()
                local bufnr = nil

                for _, existing in ipairs(vim.api.nvim_list_bufs()) do
                    if
                        vim.api.nvim_buf_is_valid(existing)
                        and same_path(vim.api.nvim_buf_get_name(existing), file)
                    then
                        bufnr = existing
                        break
                    end
                end

                if not bufnr then
                    bufnr = vim.fn.bufadd(file)
                end

                vim.fn.bufload(bufnr)

                -- :drop 的语义：已经显示在某个窗口里就跳过去，否则在当前窗口打开
                local win = vim.fn.bufwinid(bufnr)

                if win ~= -1 then
                    vim.api.nvim_set_current_win(win)
                else
                    vim.api.nvim_win_set_buf(0, bufnr)
                end

                -- Preserve the old router's cursor() semantics: both values are
                -- 1-based and Vim handles clamping for us.
                vim.fn.cursor(line, column)
            end)

            if not ok_open then
                notify("Godot remote open failed:\n" .. tostring(open_error), vim.log.levels.ERROR)
            end
        end)

        return 1
    end
end

local function create_command(name, callback, opts)
    opts = opts or {}

    if vim.fn.exists(":" .. name) == 2 then
        vim.api.nvim_del_user_command(name)
    end

    vim.api.nvim_create_user_command(name, callback, opts)
end

function M.bootstrap(opts)
    if state.bootstrapped then
        return
    end

    config_mod.setup(opts)
    setup_remote_open()

    create_command("GodotHere", function(command_opts)
        M.here({ force = command_opts.bang })
    end, {
        bang = true,
        desc = "Set current buffer's Godot project active (! force-closes old managed Godot)",
    })

    create_command("GodotProject", function(command_opts)
        M.project({ force = command_opts.bang })
    end, {
        bang = true,
        desc = "Choose active Godot project (! force-closes old managed Godot)",
    })

    create_command("GodotRestart", function(command_opts)
        M.restart({ force = command_opts.bang })
    end, {
        bang = true,
        desc = "Restart managed Godot Editor (! may discard unsaved Godot editor changes)",
    })

    create_command("GodotStop", function(command_opts)
        M.stop({ force = command_opts.bang })
    end, {
        bang = true,
        desc = "Stop managed Godot Editor (! may discard unsaved Godot editor changes)",
    })

    create_command("GodotStatus", function()
        M.status()
    end, {
        desc = "Show Godot instance status",
    })

    ------------------------------------------------------------
    -- 调试日志（编辑器里 F5 / F6 的报错）
    ------------------------------------------------------------

    create_command("GodotDebugLog", function()
        debuglog.toggle()
    end, {
        desc = "Toggle the Godot debug log panel (F5/F6 output)",
    })

    create_command("GodotDebugErrors", function()
        debuglog.errors()
    end, {
        desc = "Show Godot debug errors (trouble.nvim, quickfix fallback)",
    })

    create_command("GodotDebugQuickfix", function()
        debuglog.quickfix()
    end, {
        desc = "Put Godot debug errors into the quickfix list",
    })

    create_command("GodotDebugPath", function()
        debuglog.path()
    end, {
        desc = "Show the Godot log file path",
    })

    create_command("GodotDebugClear", function()
        debuglog.clear()
    end, {
        desc = "Clear the Godot debug panel and its diagnostics",
    })

    create_command("GodotDebugNext", function()
        debuglog.next()
    end, {
        desc = "Jump to the next Godot debug error",
    })

    create_command("GodotDebugPrev", function()
        debuglog.prev()
    end, {
        desc = "Jump to the previous Godot debug error",
    })

    ------------------------------------------------------------
    -- 编辑器报错桥
    ------------------------------------------------------------

    create_command("GodotBridge", function()
        local result = bridge.sync()
        local info = bridge.info()

        local lines = {
            "godot-instance.nvim 编辑器报错桥",
            "",
            "项目      : " .. tostring(info.root or result.root or "-"),
            "addon     : " .. tostring(info.addon or "-"),
            "注入      : " .. tostring(result.inject or "-"),
            "启用插件  : " .. tostring(result.enable or "-"),
            "桥日志    : " .. tostring(info.path or "-") .. (info.exists and "（存在）" or "（还没有）"),
            "已收报错  : " .. tostring(info.count) .. " 条",
        }

        if result.inject == "invalid_addon" then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "⚠ 注入的插件有语法错误，Godot 会静默加载失败（一条报错都抓不到）："
            lines[#lines + 1] = tostring(result.detail)
        elseif result.enable == "updated" then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "⚠ 刚把插件补回 project.godot 的启用列表。"
            lines[#lines + 1] = "  Godot 在「首次导入项目」或「插件加载失败」时会删掉这一项，"
            lines[#lines + 1] = "  所以现在需要重启一次编辑器让它生效。"
        else
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Godot 只在启动时加载编辑器插件：注入后要重启一次编辑器"
            lines[#lines + 1] = "（或在 Godot 里「项目 -> 重新加载当前项目」）。"
        end

        notify(table.concat(lines, "\n"))
    end, {
        desc = "Sync and show the Godot editor error bridge status",
    })

    local group = vim.api.nvim_create_augroup("godot_instance_manager", { clear = true })

    -- Auto-bind only while this Nvim has no active Godot project. The actual
    -- ownership claim is still the project-specific named pipe, so another
    -- Nvim already owning the project makes this a silent no-op.
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        callback = function(args)
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(args.buf) then
                    M.auto_bind(args.buf)
                end
            end)
        end,
    })

    -- If bootstrap happens after the initial BufEnter, or Nvim starts in a
    -- Godot project with an unnamed buffer, this catches the initial project.
    vim.api.nvim_create_autocmd("VimEnter", {
        group = group,
        once = true,
        callback = function()
            vim.schedule(function()
                M.auto_bind(vim.api.nvim_get_current_buf())
            end)
        end,
    })

    -- Never force-kill Godot during Nvim shutdown: that could discard unsaved
    -- scene/resource changes. Pipe ownership disappears with the Nvim process.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            disable_lsp()
            stop_dap_session()
        end,
    })

    state.bootstrapped = true

    -- Covers configurations where commands.lua is sourced after VimEnter.
    vim.schedule(function()
        M.auto_bind(vim.api.nvim_get_current_buf())
    end)
end

-- ---------------------------------------------------------------- 公共 API
M.activate = instance.activate
M.auto_bind = instance.auto_bind
M.here = instance.here
M.project = instance.project
M.restart = instance.restart
M.stop = instance.stop
M.status = instance.status
M.active_root = instance.active_root

M.godotdev = godotdev.godotdev
M.setup_godotdev = godotdev.setup_godotdev
M.godotdev_opts = godotdev.godotdev_opts
M.after_godotdev_setup = godotdev.after_godotdev_setup
M.ensure_plugin_ready = godotdev.ensure_plugin_ready

M.config = config
M.state = state
M.debuglog = debuglog
M.bridge = bridge

--- 配置 + 启动引导（幂等）。lazy 的 opts 会自动传进来。
--- @param opts table?
function M.setup(opts)
    config_mod.setup(opts)
    M.bootstrap()

    -- 必须在配置合并之后再走一遍：plugin/ 里的自动引导跑在 lazy 的 opts
    -- 之前，那一次用的是默认配置（debuglog.keymap 默认 false）。debuglog.setup()
    -- 是幂等的，重跑一次才让 keymap 这类配置项真正生效。
    if config.debuglog == nil or config.debuglog.enabled ~= false then
        debuglog.setup()
    end

    --------------------------------------------------------
    -- 编辑器报错桥
    --
    -- 它产生的诊断并进 debuglog 的展示（quickfix / :GodotDebugErrors /
    -- Trouble 本来就能看到），但两边的清空时机保持独立。
    --------------------------------------------------------

    if config.bridge == nil or config.bridge.enabled ~= false then
        bridge.setup()

        if config.debuglog == nil or config.debuglog.enabled ~= false then
            debuglog.register_diagnostics(bridge.diagnostics)
        end
    end

    return true
end

--- 插件自带脚本的位置，以及 Godot 侧该怎么填。
--- @return table
function M.paths()
    return {
        root = plugin_root(),
        close_helper = script_path("godot-close.ps1"),
        router = script_path("godot-nvim.cmd"),
        router_ps1 = script_path("godot-nvim-router.ps1"),
    }
end

--- Godot 编辑器里“外部编辑器”应该填的路径。
--- @return string?
function M.router_path()
    return script_path("godot-nvim.cmd")
end

create_command("GodotPaths", function()
    local paths = M.paths()

    notify(table.concat({
        "godot-instance.nvim",
        "",
        "plugin root  : " .. tostring(paths.root),
        "close helper : " .. tostring(paths.close_helper),
        "router       : " .. tostring(paths.router),
        "",
        "Godot 侧：编辑器设置 -> 文本编辑器 -> 外部",
        "  Exec Path  = " .. tostring(paths.router),
        '  Exec Flags = "{file}" {line} {col}',
    }, "\n"))
end, {
    desc = "Show godot-instance.nvim paths (Godot external editor setup)",
})

-- :checkhealth godot-instance 会自动找 require("godot-instance.health").check()

return M

