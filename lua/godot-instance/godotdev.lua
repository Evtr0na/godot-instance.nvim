-- 与 godotdev.nvim 的集成边界。所有“必须塞进 godotdev.setup() 里”的动作都在这。
local config = require("godot-instance.config").options
local state = require("godot-instance.state")
local util = require("godot-instance.util")
local reserve = require("godot-instance.reserve")
local lsp = require("godot-instance.lsp")

local HOST = util.HOST
local notify = util.notify
local notify_unless_silent = util.notify_unless_silent
local ensure_port_pair = reserve.ensure_port_pair
local disable_lsp = lsp.disable_lsp
local patch_lsp = lsp.patch_lsp
local patch_dap = lsp.patch_dap

local M = {}

local function ensure_plugin_ready(opts)
    if state.plugin_ready then
        return true
    end

    local ok_lazy, lazy = pcall(require, "lazy")
    if ok_lazy then
        pcall(lazy.load, { plugins = { "godotdev.nvim" } })
    end

    if state.plugin_ready then
        return true
    end

    notify_unless_silent(opts,
        "godotdev.nvim is not initialized. Ensure its Lazy spec calls godot_instance.godotdev_opts() before setup and godot_instance.after_godotdev_setup() after setup.",
        vim.log.levels.ERROR
    )
    return false
end

function M.godotdev_opts(opts)
    opts = vim.deepcopy(opts or {})
    ensure_port_pair()

    opts.editor_host = HOST
    opts.editor_port = state.lsp_port
    opts.debug_port = state.dap_port
    opts.autostart_editor_server = false

    if opts.godot_path then
        config.godot_path = opts.godot_path
    end

    return opts
end

local function disable_godotdev_editor_server()
    -- The project-specific RPC pipe is owned by this manager. godotdev.nvim's
    -- generic editor-server autostart layer is redundant in this architecture
    -- and can race with another Nvim instance, so remove the automatic hook.
    pcall(vim.api.nvim_del_augroup_by_name, "godotdev_start_editor_server")

    if vim.fn.exists(":GodotStartEditorServer") == 2 then
        pcall(vim.api.nvim_del_user_command, "GodotStartEditorServer")
    end

    vim.api.nvim_create_user_command("GodotStartEditorServer", function()
        if state.project_server then
            notify("Godot editor RPC is already managed by this Nvim:\n" .. state.project_server)
        else
            notify("Godot editor RPC will be created automatically when this Nvim binds a Godot project")
        end
    end, {
        desc = "Show the project-specific Godot editor RPC server managed by godot_instance",
    })
end

function M.after_godotdev_setup(opts)
    opts = opts or {}

    if opts.godot_path then
        config.godot_path = opts.godot_path
    end

    ensure_port_pair()

    -- gdscript.lua suppresses godotdev's one eager vim.lsp.enable() call.
    -- Keep it disabled here as a second guard until the managed Godot LSP
    -- TCP port is actually accepting connections.
    disable_lsp()
    patch_lsp()
    patch_dap()
    disable_godotdev_editor_server()
    state.plugin_ready = true
end

--- godotdev 集成入口。
---
--- 在 godotdev 的 lazy spec 里这样用：
---
---     config = function(_, opts)
---         require("godot-instance").godotdev(opts)
---     end
---
--- 它会：
---   1. 把本实例的 LSP/DAP 端口注入 opts（editor_host/editor_port/debug_port）
---   2. 在 godotdev.setup() 期间拦掉它自己那次“过早的” vim.lsp.enable("gdscript")
---      （这时 Godot 的 LSP 端口往往还没起来，Windows 上会留下
---      "Client gdscript quit with exit code 1"）
---   3. setup 之后接管：保持 LSP disabled、装上 active-project root_dir gate、
---      修正 DAP 端口、禁掉 godotdev 自带的通用 editor-server 自动层
---   4. 把 gdscript 的 filetypes 限制回 "gdscript"
---   5. 记住这个 Nvim 是托管项目的，并标记 godotdev 已经就绪
--- @param opts table godotdev 的 opts
function M.godotdev(opts)
    opts = M.godotdev_opts(opts or {})

    local original_lsp_enable = vim.lsp.enable

    vim.lsp.enable = function(name, enable)
        if name == "gdscript" and enable ~= false then
            return {}
        end

        return original_lsp_enable(name, enable)
    end

    local ok, setup_error = xpcall(function()
        require("godotdev").setup(opts)
    end, debug.traceback)

    -- 无论成功还是失败都必须恢复，不能污染其它 LSP。
    vim.lsp.enable = original_lsp_enable

    if not ok then
        error(setup_error)
    end

    vim.lsp.config("gdscript", {
        filetypes = {
            "gdscript",
        },
    })

    M.after_godotdev_setup({
        godot_path = opts.godot_path,
    })

    return true
end

M.setup_godotdev = M.godotdev
M.ensure_plugin_ready = ensure_plugin_ready
M.godotdev_opts = M.godotdev_opts
M.after_godotdev_setup = M.after_godotdev_setup
M.disable_godotdev_editor_server = disable_godotdev_editor_server

return M
