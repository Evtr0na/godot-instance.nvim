-- 配置：默认值 + setup() 合并。
--
-- 合并必须“就地”写回 options 表：其它模块在加载时把 options 表别名成了
-- local config（见各模块头部的 import 段），重新赋值 config.options 会让那些
-- 别名指向旧表。
local M = {}

M.options = {

    godot_path = "godot",
    startup_timeout_ms = 15000,
    close_timeout_ms = 30000,
    force_close_timeout_ms = 5000,
    port_min = 16000,
    port_max = 49000,

    -- Godot's editor window can steal the foreground window on Windows when it
    -- is launched automatically. Keep the terminal/Nvim focused by default.
    preserve_focus_on_start = true,
    focus_guard_timeout_ms = 5000,
    focus_guard_poll_ms = 40,
    lsp_port_poll_ms = 25,

    ------------------------------------------------------------
    -- 实例复用（省掉 Godot 编辑器冷启动的 5-6 秒）
    ------------------------------------------------------------

    -- 托管启动的 Godot 是否活过 Nvim。true 时下一次启动 Nvim 可以直接
    -- 复用它，代价是它会留在后台，需要 :GodotStop 关掉。
    keep_alive = true,

    -- 总开关：启动时先找可复用的实例，找不到才托管启动。
    reuse = true,

    -- 是否也复用“不是本 Nvim 托管”的 Godot（也就是你自己开的那个）。
    reuse_external = true,

    -- 外部编辑器的 LSP 端口候选。对应 Godot 设置项
    -- network/language_server/remote_port（默认 6005）。
    reuse_external_ports = { 6005 },

    -- 外部编辑器的 DAP 端口 = LSP 端口 + 这个偏移（6005 -> 6006）。
    reuse_external_dap_offset = 1,

    -- 复用外部编辑器之前，用 Godot 窗口标题里的项目名确认它开的确实是
    -- 当前项目（Godot 4 的标题形如 "scene.tscn - 项目名 - Godot Engine"）。
    -- 关掉会退化成“6005 上有东西就连”，有连错项目的风险。
    reuse_external_verify = true,

    -- 实例状态文件目录，nil = stdpath("state")/godot_instance
    state_dir = nil,

}

--- @param opts table?
--- @return table options
function M.setup(opts)
    if type(opts) ~= "table" then
        return M.options
    end

    local merged = vim.tbl_deep_extend("force", M.options, opts)
    for key, value in pairs(merged) do
        M.options[key] = value
    end

    return M.options
end

return M
