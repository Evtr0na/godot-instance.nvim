-- LSP / DAP 接线：把 godotdev 的 gdscript client 指向“本项目那个 Godot”的端口。
local config = require("godot-instance.config").options
local state = require("godot-instance.state")
local util = require("godot-instance.util")
local project = require("godot-instance.project")

local HOST = util.HOST
local same_path = util.same_path
local notify = util.notify
local project_root_for_buf = project.project_root_for_buf

local M = {}

local function disable_lsp()
    pcall(vim.lsp.enable, "gdscript", false)
end

local function enable_lsp()
    local ok, err = pcall(vim.lsp.enable, "gdscript", true)
    if not ok then
        notify("Failed to enable gdscript LSP:\n" .. tostring(err), vim.log.levels.ERROR)
    end
end

local function patch_lsp()
    local lsp_config = {
        root_dir = function(bufnr, on_dir)
            local active_root = state.active_root
            if not active_root then
                return
            end

            local root = project_root_for_buf(bufnr)
            if not root or not same_path(root, active_root) then
                return
            end

            on_dir(active_root)
        end,
    }

    -- godotdev.nvim currently launches an external `ncat` process on Windows.
    -- Neovim already has a native TCP LSP transport, so use it directly:
    --   * no extra ncat process
    --   * no ncat startup/exit noise
    --   * connects immediately once Godot's port is ready
    if vim.lsp.rpc and type(vim.lsp.rpc.connect) == "function" and state.lsp_port then
        lsp_config.cmd = vim.lsp.rpc.connect(HOST, state.lsp_port)
    end

    vim.lsp.config("gdscript", lsp_config)
end

local function stop_dap_session()
    local ok, dap = pcall(require, "dap")
    if not ok then
        return
    end

    local session = dap.session()
    if session then
        pcall(dap.terminate)
    end
end

local function patch_dap()
    local ok, dap = pcall(require, "dap")
    if not ok then
        return
    end

    dap.adapters.godot = {
        type = "server",
        host = HOST,
        port = state.dap_port,
    }
end

M.disable_lsp = disable_lsp
M.enable_lsp = enable_lsp
M.patch_lsp = patch_lsp
M.stop_dap_session = stop_dap_session
M.patch_dap = patch_dap

return M
