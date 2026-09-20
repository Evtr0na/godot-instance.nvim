-- 资源占用：命名管道互斥（一个项目同时只允许一个 Nvim 托管）+ LSP/DAP 端口对。
local config = require("godot-instance.config").options
local state = require("godot-instance.state")
local util = require("godot-instance.util")
local project = require("godot-instance.project")

local IS_WINDOWS = util.IS_WINDOWS
local HOST = util.HOST
local close_handle = util.close_handle
local normalize_slashes = util.normalize_slashes
local port_lock_pipe = project.port_lock_pipe

local uv = vim.uv

local M = {}

local function server_key(address)
    if not address or address == "" then
        return nil
    end

    address = normalize_slashes(address)
    if IS_WINDOWS then
        address = address:lower()
    end

    return address
end

local function own_server_exists(address)
    local wanted = server_key(address)
    for _, existing in ipairs(vim.fn.serverlist()) do
        if server_key(existing) == wanted then
            return true, existing
        end
    end

    return false, nil
end

local function peer_server_reachable(address)
    if not address or address == "" then
        return false
    end

    -- serverlist() only reports servers owned by this Nvim on Windows. Probe
    -- the named pipe first so another Nvim owning it is a normal collision,
    -- not an expected serverstart() EADDRINUSE failure.
    local ok, channel = pcall(vim.fn.sockconnect, "pipe", address, { rpc = true })
    if not ok or type(channel) ~= "number" or channel <= 0 then
        return false
    end

    pcall(vim.fn.chanclose, channel)
    return true
end

local function claim_server(address)
    local ours, existing = own_server_exists(address)
    if ours then
        return true, existing
    end

    if peer_server_reachable(address) then
        return false, "address already in use"
    end

    local ok, result = pcall(vim.fn.serverstart, address)
    if not ok then
        return false, tostring(result)
    end

    return true, result
end

local function release_server(address)
    if not address then
        return
    end

    local ours, existing = own_server_exists(address)
    if not ours then
        return
    end

    pcall(vim.fn.serverstop, existing)
end

local function can_listen(port)
    local tcp = uv.new_tcp()
    if not tcp then
        return false
    end

    local ok_bind, bind_result = pcall(function()
        return tcp:bind(HOST, port)
    end)

    if not ok_bind or bind_result == nil then
        close_handle(tcp)
        return false
    end

    local ok_listen, listen_result = pcall(function()
        return tcp:listen(1, function() end)
    end)

    local result = ok_listen and listen_result ~= nil
    close_handle(tcp)
    return result
end

local function ensure_port_pair()
    -- 复用来的端口对没有 lock server，用 state.adopted 标记。
    if state.lsp_port and state.dap_port and (state.port_lock_server or state.adopted) then
        return
    end

    local min_port = config.port_min
    local max_port = config.port_max

    if min_port % 2 ~= 0 then
        min_port = min_port + 1
    end
    if max_port % 2 ~= 0 then
        max_port = max_port - 1
    end

    if max_port <= min_port then
        error("Godot Instance: invalid port range")
    end

    local pair_count = math.floor((max_port - min_port) / 2) + 1
    local start_slot = vim.fn.getpid() % pair_count

    for offset = 0, pair_count - 1 do
        local slot = (start_slot + offset) % pair_count
        local lsp_port = min_port + slot * 2
        local dap_port = lsp_port + 1
        local lock_address = port_lock_pipe(lsp_port, dap_port)
        local claimed, lock_or_error = claim_server(lock_address)

        if claimed then
            if can_listen(lsp_port) and can_listen(dap_port) then
                state.lsp_port = lsp_port
                state.dap_port = dap_port
                state.port_lock_server = lock_or_error
                return
            end

            release_server(lock_or_error)
        end
    end

    error("Godot Instance: no free LSP/DAP port pair is available")
end

M.server_key = server_key
M.own_server_exists = own_server_exists
M.peer_server_reachable = peer_server_reachable
M.claim_server = claim_server
M.release_server = release_server
M.can_listen = can_listen
M.ensure_port_pair = ensure_port_pair

return M
