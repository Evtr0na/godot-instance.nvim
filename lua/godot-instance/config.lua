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

    ------------------------------------------------------------
    -- 启动 Godot 时套一层「无控制台」的中间进程（仅 Windows）
    ------------------------------------------------------------
    -- Godot 启动时会 AttachConsole(ATTACH_PARENT_PROCESS)，然后把自己（以及
    -- 它 F5 起的游戏）的 stdout/stderr 接到那个控制台上。如果 Godot 是从
    -- Nvim 里启动的，那个控制台就是 Nvim 所在的终端 —— 游戏输出会直接写进
    -- Nvim 的画面，字符错乱、行号错位，Nvim 完全不知情。
    --
    -- 开着这个开关时，Godot 的父进程是一个 detached 的 cmd.exe（没有控制台），
    -- AttachConsole 找不到可挂的控制台，整条链就断了。
    --
    -- 代价：uv.spawn 拿到的是 cmd 的 PID，插件会再查一次真正的 Godot PID
    -- （焦点守卫、优雅关闭、实例记录都要用它）。
    --
    -- 注意：中间层必须 detached 才有效（detached 的进程没有控制台），而
    -- detached 跟 keep_alive 是同一个开关 —— 所以**这个开关只在
    -- keep_alive = true 时生效**。keep_alive = false 时要靠 libuv 的 job
    -- object 保证「Godot 活不过 Nvim」，而 job object 里的进程会继承控制台，
    -- 两者没法兼得；那种配置下会退回旧行为（游戏输出仍会污染终端）。
    --
    -- 关掉就恢复旧行为。
    console_wrapper = true,
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

    ------------------------------------------------------------
    -- 编辑器报错桥（Godot 编辑器 -> Nvim）
    ------------------------------------------------------------
    -- 编辑器侧的报错（最典型的是 gdshader 编译失败）只进 Godot 的 Output
    -- 面板，不写进 user://logs/godot.log，所以 debuglog 那条 tail 日志的
    -- 路看不到它。
    --
    -- 本模块往项目里注入一个 EditorPlugin（addons/nvim_debug_bridge/），
    -- 它用 OS.add_logger() 挂 Logger，把编辑器报错按 JSON 一行写到
    -- user://nvim_debug_bridge.log，这里 tail 它并转成诊断。
    --
    -- 注意：Godot 只在启动时加载编辑器插件，所以第一次注入后需要
    -- **重启一次编辑器**（或在 Godot 里「项目 -> 重新加载当前项目」）。
    bridge = {

        enabled = true,

        -- 把 addon 文件写进 <项目>/addons/nvim_debug_bridge/
        -- 内容一致就复用；内容不同但不是我们注入的（没有 managed 标记）
        -- 就绝不覆盖，只提示。
        inject = true,

        -- 自动改 project.godot 的 [editor_plugins] enabled 把插件勾上。
        -- Godot 必须看到这一项才会加载编辑器插件。关掉的话就自己去
        -- 「项目设置 -> 插件」里勾一次。
        auto_enable = true,

        -- 轮询间隔（毫秒）
        interval_ms = 200,

        -- 把编辑器报错也写进调试面板，这样 <leader>gD 就能实时看到
        -- （否则只在诊断里，要看只能 <leader>xx / :GodotDebugErrors）
        show_in_panel = true,

        -- GDScript 解析级联抑制。
        --
        -- 一个真正的语法错会让 GDScript 解析器恢复失败，然后吐出一堆下游
        -- 假错（实测一个未闭合的 func 报出 7 条，行号散落在 154~198，
        -- 198 还超出文件总行数 196），看起来就像「乱报错」。
        -- 打开后只留每条「解析轮次」的第一条（第一条通常就是根因）。
        --
        -- 只在 script_errors = true 时才有意义（默认那类报错根本不发）。
        collapse_script_parse_errors = true,

        -- 上面那个「同一轮解析」的时间窗（毫秒）
        parse_burst_window_ms = 3000,

        -- 是否把**编辑器侧**的 GDScript 报错也发过来。
        --
        -- 默认关：这类报错和 godotdev.nvim 的 LSP 诊断是同一份东西（同一个
        -- GDScript 解析器、同一批语法错误），两边都报就是重复。
        --
        -- 游戏跑起来之后的脚本报错**不受这个开关影响** —— 那是游戏进程写进
        -- godot.log 的，走 debuglog 那条路。也就是说：「运行以后的调试报错」
        -- 一直都有，这里管的是「编辑器里就存在的、LSP 也能看到的」那些。
        script_errors = false,

        -- 手动指定桥日志路径；nil = user://nvim_debug_bridge.log
        log_path = nil,

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
