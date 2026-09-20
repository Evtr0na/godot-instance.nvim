-- 托管实例的持久化记录：{ 项目根 -> pid / lsp_port / dap_port }。
-- 有了它，下一个 Nvim（或 Nvim 重开之后）才能直接复用还活着的 Godot。
local config = require("godot-instance.config").options
local util = require("godot-instance.util")

local normalize_path = util.normalize_path
local path_key = util.path_key

local M = {}

local function state_dir()
    return config.state_dir or vim.fs.joinpath(vim.fn.stdpath("state"), "godot_instance")
end

local function state_file()
    return vim.fs.joinpath(state_dir(), "instances.json")
end

local function read_records()
    if vim.fn.filereadable(state_file()) ~= 1 then
        return {}
    end

    local ok_read, lines = pcall(vim.fn.readfile, state_file())
    if not ok_read or type(lines) ~= "table" then
        return {}
    end

    local ok_decode, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not ok_decode or type(decoded) ~= "table" then
        return {}
    end

    return decoded
end

local function write_records(records)
    pcall(vim.fn.mkdir, state_dir(), "p")

    local ok_encode, encoded = pcall(vim.json.encode, records)
    if not ok_encode then
        return
    end

    pcall(vim.fn.writefile, { encoded }, state_file())
end

local function record_instance(root, pid, lsp_port, dap_port)
    local records = read_records()

    records[path_key(root)] = {
        root = normalize_path(root),
        pid = tonumber(pid),
        lsp_port = tonumber(lsp_port),
        dap_port = tonumber(dap_port),
        godot_path = config.godot_path,
        updated_at = os.time(),
    }

    write_records(records)
end

local function forget_instance(root)
    local key = path_key(root)
    if not key then
        return
    end

    local records = read_records()
    if records[key] == nil then
        return
    end

    records[key] = nil
    write_records(records)
end

M.state_dir = state_dir
M.state_file = state_file
M.read_records = read_records
M.write_records = write_records
M.record_instance = record_instance
M.forget_instance = forget_instance

return M
