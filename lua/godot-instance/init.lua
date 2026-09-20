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

            local ok_drop, err = pcall(vim.api.nvim_cmd, {
                cmd = "drop",
                args = { file },
                magic = { file = false, bar = false },
            }, {})

            if not ok_drop then
                notify("Godot remote open failed:\n" .. tostring(err), vim.log.levels.ERROR)
                return
            end

            -- Preserve the old router's cursor() semantics: both values are
            -- 1-based and Vim handles clamping for us.
            pcall(vim.fn.cursor, line, column)
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

--- 配置 + 启动引导（幂等）。lazy 的 opts 会自动传进来。
--- @param opts table?
function M.setup(opts)
    config_mod.setup(opts)
    return M.bootstrap()
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

