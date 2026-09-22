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

-- 读 project.godot 里的某一项，形如 project_setting(root, "application/config/name")。
-- project.godot 是 INI 风格，所以按 section 定位，避免撞上别的 section 里的同名键。
--- @param root string
--- @param key string "section/key"
--- @return string?
local function project_setting(root, key)
    local want_section, want_key = key:match("^([^/]+)/(.+)$")

    if not want_section then
        return nil
    end

    local project_file = vim.fs.joinpath(root, "project.godot")

    if vim.fn.filereadable(project_file) ~= 1 then
        return nil
    end

    local ok, lines = pcall(vim.fn.readfile, project_file)

    if not ok or type(lines) ~= "table" then
        return nil
    end

    local section = nil

    for _, line in ipairs(lines) do
        local header = line:match("^%s*%[([^%]]+)%]")

        if header then
            section = header
        elseif section == want_section then
            local k, v = line:match("^%s*([%w_/%.]+)%s*=%s*(.*)$")

            if k == want_key and v then
                -- 去掉引号
                return v:match('^"(.*)"$') or v
            end
        end
    end

    return nil
end

-- Godot 的 OS::get_data_path()：用户数据放在哪。
local function data_path()
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
        local appdata = vim.env.APPDATA

        if appdata and appdata ~= "" then
            return util.normalize_slashes(appdata)
        end

        return nil
    end

    if vim.fn.has("mac") == 1 then
        return vim.fs.joinpath(vim.env.HOME or "", "Library/Application Support")
    end

    local xdg = vim.env.XDG_DATA_HOME

    if xdg and xdg ~= "" then
        return util.normalize_slashes(xdg)
    end

    return vim.fs.joinpath(vim.env.HOME or "", ".local/share")
end

-- Godot 的 get_godot_dir_name()：厂商目录名。
local function godot_dir_name()
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 or vim.fn.has("mac") == 1 then
        return "Godot"
    end

    return "godot"
end

-- Godot 的 get_safe_dir_name()：路径分隔符和非法文件名字符会被替换掉。
local function safe_dir_name(name)
    if not name or name == "" then
        return name
    end

    return (name:gsub('[\\/:*?"<>|]', "-"))
end

-- 复刻 Godot 的 OS::get_user_data_dir()：
--
--     use_custom_user_dir = true -> <data>/<custom_user_dir_name>
--     否则                       -> <data>/<Godot>/app_userdata/<项目名>
--     项目名为空                 -> .../app_userdata/[unnamed project]
--
-- 游戏进程和编辑器都按这套规则找 user://，所以日志也在这里。
--- @param root string
--- @return string?
local function user_data_dir(root)
    if not root then
        return nil
    end

    local data = data_path()

    if not data then
        return nil
    end

    local name = project_setting(root, "application/config/name")

    if not name or name == "" then
        name = project_name_for_root(root)
    end

    if not name or name == "" then
        name = "[unnamed project]"
    end

    if project_setting(root, "application/config/use_custom_user_dir") == "true" then
        local custom = project_setting(root, "application/config/custom_user_dir_name")

        if custom and custom ~= "" then
            return vim.fs.joinpath(data, safe_dir_name(custom) or custom)
        end

        return vim.fs.joinpath(data, safe_dir_name(name) or name)
    end

    return vim.fs.joinpath(data, godot_dir_name(), "app_userdata", safe_dir_name(name) or name)
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
M.project_setting = project_setting
M.user_data_dir = user_data_dir
M.project_pipe = project_pipe
M.port_lock_pipe = port_lock_pipe

return M
