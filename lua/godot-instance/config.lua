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

    ------------------------------------------------------------
    -- 调试日志（Godot 编辑器里按 F5 / F6 的报错）
    ------------------------------------------------------------
    -- 编辑器启动的游戏，stdout 被编辑器自己吞掉，Nvim 看不到。Godot 桌面
    -- 平台默认会把游戏输出写进 user://logs/godot.log，这里 tail 它。
    -- 详见 lua/godot-instance/debuglog.lua 头部。
    debuglog = {

        enabled = true,

        -- 轮询间隔（毫秒）。日志是逐行 flush 的，200ms 已经足够实时。
        interval_ms = 200,

        -- 检测到新一轮运行（Godot 启动横幅）时是否自动打开面板。
        -- 默认关：跑项目时不要凭空多出一个分屏，要看时 :GodotDebugLog 打开。
        -- 诊断不受这个开关影响，一直都在。
        auto_open = false,

        -- 面板位置："bottom" | "right" | "float"
        position = "bottom",
        size = 0.3,

        -- 面板最多保留多少行，超出丢弃最旧的
        max_lines = 5000,

        -- 手动指定日志路径；nil = 按项目名自动推导
        log_path = nil,

        -- 把报错解析成真正的 vim.diagnostic，于是 Trouble / 跳转 /
        -- 行号符号全都直接可用
        diagnostics = {
            enabled = true,
        },

        ------------------------------------------------------------
        -- 终端残影兜底
        ------------------------------------------------------------
        -- 如果 Godot 编辑器（以及它 F5 起的游戏）和 Nvim 共用同一个终端
        -- （同一个 pty），游戏的 stdout 会直接写进 Nvim 的画面，留下日志
        -- 残影 —— 文字从第 0 列写进去、压住行号栏，光标扫过才恢复。
        -- 那不是 Nvim 画的，Nvim 拦不住。
        --
        -- 残影和日志增长是同一个进程同时发生的，所以一有新日志就整屏重绘
        -- 一次，可以把残影压到一个轮询周期之内。代价是游戏疯狂 print 时
        -- 会按下面的节流间隔持续重绘；嫌闪就关掉。
        --
        -- 根治办法是让编辑器和 Nvim 别共用终端：把 Godot 编辑器放到另一个
        -- WezTerm pane/tab 里启动。
        redraw_on_output = true,
        redraw_throttle_ms = 500,

        -- 快捷键；false = 不设置（默认不占键位，插件不该强加映射）
        keymap = false,        -- 开关面板
        keymap_errors = false, -- 展示报错（Trouble 优先，quickfix 兜底）

    },

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
