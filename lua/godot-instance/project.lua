-- Godot 项目定位：找 project.godot、项目名、以及本项目专属的命名管道名。
local util = require("godot-instance.util")

local normalize_path = util.normalize_path
local path_key = util.path_key

local M = {}

local function project_name_for_root(root)
    local project_file = vim.fs.joinpath(root, "project.godot")

    if vim.fn.filereadable(project_file) == 1 then
        local ok, lines = pcall(vim.fn.readfile, project_file)
        if ok and type(lines) == "table" then
            for _, line in ipairs(lines) do
                local name = line:match('^%s*config/name%s*=%s*"(.*)"%s*$')
                if name and name ~= "" then
                    return name
                end
            end
        end
    end

    return vim.fs.basename(root)
end

local function project_root_for_file(filename)
    if not filename or filename == "" then
        return nil
    end

    local ok, root = pcall(vim.fs.root, filename, "project.godot")
    if not ok then
        return nil
    end

    return normalize_path(root)
end

local function project_root_for_buf(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local filename = vim.api.nvim_buf_get_name(bufnr)
    return project_root_for_file(filename)
end

local function project_pipe(root)
    local key = assert(path_key(root), "invalid Godot project root")
    return "//./pipe/nvim-godot-project-" .. vim.fn.sha256(key)
end

local function port_lock_pipe(lsp_port, dap_port)
    return string.format("//./pipe/nvim-godot-port-%d-%d", lsp_port, dap_port)
end

M.project_name_for_root = project_name_for_root
M.project_root_for_file = project_root_for_file
M.project_root_for_buf = project_root_for_buf
M.project_pipe = project_pipe
M.port_lock_pipe = port_lock_pipe

return M
