-- 复用优先：启动时先找“已经在跑的 Godot”，找到就直接挂上去。
--
--   1. 自己（或上一个 Nvim）托管启动、且还活着的实例（记录在 records 里）
--   2. 外部编辑器（你自己开的那个 Godot，默认 LSP 端口 6005）
local config = require("godot-instance.config").options
local state = require("godot-instance.state")
local util = require("godot-instance.util")
local records = require("godot-instance.records")
local reserve = require("godot-instance.reserve")
local windows = require("godot-instance.windows")

local path_key = util.path_key
local pid_alive = util.pid_alive
local tcp_reachable = util.tcp_reachable
local read_records = records.read_records
local forget_instance = records.forget_instance
local release_server = reserve.release_server
local external_editor_serves_project = windows.external_editor_serves_project

local M = {}

local function adopt_instance(instance)
    -- 换到别的端口对时，把原来预留的那一对还回去。
    if state.port_lock_server and state.lsp_port ~= instance.lsp_port then
        release_server(state.port_lock_server)
        state.port_lock_server = nil
    end

    state.adopted = {
        source = instance.source,
        pid = instance.pid,
    }
    state.lsp_port = instance.lsp_port
    state.dap_port = instance.dap_port
end

local function release_adopted()
    if state.port_lock_server then
        release_server(state.port_lock_server)
    end

    state.adopted = nil
    state.lsp_port = nil
    state.dap_port = nil
    state.port_lock_server = nil
end
-- 返回 nil（没有可复用的）或 { source, lsp_port, dap_port, pid }
local function probe_reusable_instance(root)
    if not config.reuse then
        return nil
    end

    -- 1) 之前（可能是上一个 Nvim）托管启动、并且还活着的实例
    local record = read_records()[path_key(root)]
    if record then
        local lsp_port = tonumber(record.lsp_port)
        local dap_port = tonumber(record.dap_port)

        if lsp_port and dap_port and pid_alive(record.pid) and tcp_reachable(lsp_port) then
            return {
                source = "managed",
                lsp_port = lsp_port,
                dap_port = dap_port,
                pid = tonumber(record.pid),
            }
        end

        forget_instance(root)
    end

    -- 2) 外部编辑器（你自己开的那个 Godot）
    if config.reuse_external then
        local offset = tonumber(config.reuse_external_dap_offset) or 1

        for _, port in ipairs(config.reuse_external_ports) do
            port = tonumber(port)

            if port and tcp_reachable(port) then
                if not config.reuse_external_verify or external_editor_serves_project(root) then
                    return {
                        source = "external",
                        lsp_port = port,
                        dap_port = port + offset,
                        pid = nil,
                    }
                end
            end
        end
    end

    return nil
end

M.adopt_instance = adopt_instance
M.release_adopted = release_adopted
M.probe_reusable_instance = probe_reusable_instance

return M
