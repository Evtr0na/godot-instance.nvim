-- :checkhealth godot-instance
--
-- Neovim 会自动尝试 require("godot-instance.health").check()，
-- 所以不需要额外注册任何东西。
local M = {}

-- nvim 0.10 前后 API 名字变过（report_* -> *），两边都兼容。
local function health_api()
    local h = vim.health or require("health")

    return {
        start = h.start or h.report_start,
        ok = h.ok or h.report_ok,
        info = h.info or h.report_info,
        warn = h.warn or h.report_warn,
        error = h.error or h.report_error,
    }
end

function M.check()
    local h = health_api()

    local config = require("godot-instance.config").options
    local state = require("godot-instance.state")
    local util = require("godot-instance.util")
    local records = require("godot-instance.records")
    local process = require("godot-instance.process")

    h.start("godot-instance")

    if util.IS_WINDOWS then
        h.ok("Windows：窗口标题校验、焦点守卫、优雅关闭都可用")

        --------------------------------------------------------
        -- 控制台中间层：决定游戏输出会不会写进 Nvim 的画面。
        --------------------------------------------------------

        if config.console_wrapper == false then
            h.warn(
                "console_wrapper = false：Godot 会 AttachConsole 到 Nvim 的终端，游戏输出会污染画面",
                "重新打开 console_wrapper 可以根治（见 README「终端残影」）"
            )
        elseif config.keep_alive ~= true then
            h.warn(
                "keep_alive = false：控制台中间层用不了（job object 里的进程会继承控制台），游戏输出会污染画面",
                "把 keep_alive 设为 true 才能根治；或者把 Godot 放到另一个终端里跑"
            )
        else
            h.ok("控制台中间层已启用（Godot 的父进程是无控制台的 cmd.exe）")
        end
    else
        h.warn(
            "非 Windows：窗口标题校验、焦点守卫、优雅关闭（godot-close.ps1）不可用",
            "强制关闭 :GodotStop! 仍然可用"
        )
    end

    if vim.fn.executable(config.godot_path) == 1 then
        h.ok(("godot_path 可执行：%s"):format(config.godot_path))
    else
        h.error(
            ("godot_path 不可执行：%s"):format(config.godot_path),
            "在 setup({ godot_path = ... }) 里指向 Godot 可执行文件"
        )
    end

    local ok_lazy, lazy_config = pcall(require, "lazy.core.config")
    if ok_lazy and lazy_config.plugins and lazy_config.plugins["godotdev.nvim"] then
        h.ok("godotdev.nvim 已安装")
    else
        h.warn("没找到 godotdev.nvim", "本插件依赖它提供 gdscript LSP")
    end

    for _, name in ipairs({ "godot-close.ps1", "godot-nvim.cmd", "godot-nvim-router.ps1" }) do
        local path = util.script_path(name)
        if path then
            h.ok(("scripts/%s -> %s"):format(name, path))
        else
            h.error(("缺少 scripts/%s"):format(name), "插件目录可能不完整")
        end
    end

    local router = util.script_path("godot-nvim.cmd")
    if router then
        h.info(
            "Godot 侧：编辑器设置 -> 文本编辑器 -> 外部\n"
                .. "  Exec Path  = "
                .. router
                .. '\n  Exec Flags = "{file}" {line} {col}'
        )
    end

    h.start("godot-instance: 当前实例")

    if not state.active_root then
        h.info("当前没有托管项目")
    else
        h.ok("项目：" .. state.active_root)
        h.info(("实例：%s"):format(process.instance_source_label()))
        h.info(("LSP :%s   DAP :%s"):format(tostring(state.lsp_port), tostring(state.dap_port)))

        if state.lsp_port and util.tcp_reachable(state.lsp_port) then
            h.ok("LSP 端口可连接")
        else
            h.warn("LSP 端口连不上")
        end

        local attached = false
        for _, client in ipairs(vim.lsp.get_clients()) do
            if (client.name == "gdscript" or client.name == "godot_editor") and client.initialized then
                attached = true
                break
            end
        end

        if attached then
            h.ok("gdscript LSP client 已 attach")
        else
            h.warn("gdscript LSP client 未 attach")
        end
    end

    h.start("godot-instance: 调试日志")

    if config.debuglog and config.debuglog.enabled == false then
        h.info("已关闭（config.debuglog.enabled = false）")
    else
        local info = require("godot-instance.debuglog").info()

        if not info.root then
            h.info("当前不在 Godot 项目里，日志监控未启动")
        else
            h.ok("项目：" .. info.root)

            if info.exists then
                h.ok("日志文件：" .. info.path)
            else
                h.warn(
                    "日志文件还不存在：" .. tostring(info.path),
                    "在 Godot 编辑器里按 F5 / F6 跑一次游戏。若仍无日志，检查项目设置 "
                        .. "debug/file_logging/enable_file_logging（桌面平台默认是开的）"
                )
            end

            h.info(("已解析诊断：%d 条"):format(info.count))
        end

        -- 展示出口：Trouble 优先，quickfix 兜底。这里只报告实际会用哪条路。
        if vim.fn.exists(":Trouble") == 2 or pcall(require, "trouble") then
            h.ok("trouble.nvim 可用：:GodotDebugErrors 走 Trouble diagnostics")
        else
            h.info("没装 trouble.nvim：:GodotDebugErrors 会退回 quickfix（不是硬依赖）")
        end
    end

    h.start("godot-instance: 编辑器报错桥")

    if config.bridge and config.bridge.enabled == false then
        h.info("已关闭（config.bridge.enabled = false）")
    else
        local info = require("godot-instance.bridge").info()

        if not info.root then
            h.info("当前不在 Godot 项目里，桥未启动")
        else
            h.ok("项目：" .. info.root)

            if info.injected then
                h.ok("addon 已注入：" .. tostring(info.addon))

                -- 语法校验：插件静默加载失败时完全没输出，是最难查的一种坏法
                local bstatus, bdetail = require("godot-instance.bridge").validate(info.root)

                if bstatus == "ok" then
                    h.ok("addon 语法校验通过（godot --check-only）")
                elseif bstatus == "no_godot" then
                    h.warn("没找到 Godot 可执行文件，跳过了 addon 语法校验")
                else
                    h.error(
                        "addon 语法校验失败（" .. tostring(bstatus) .. "）：编辑器会静默加载失败，一条报错都抓不到",
                        tostring(bdetail)
                    )
                end
            else
                h.warn(
                    "addon 还没注入：" .. tostring(info.addon),
                    "在项目里开个 .gd 文件触发一次 :GodotBridge 即可"
                )
            end

            if info.enabled then
                h.ok("project.godot 里已勾上该插件")
            else
                h.warn(
                    "project.godot 的 [editor_plugins] 里没有这个插件，Godot 不会加载它",
                    "打开 config.bridge.auto_enable，或在 Godot 里「项目设置 -> 插件」手动勾一次"
                )
            end

            if info.exists then
                h.ok("桥日志：" .. info.path)
            else
                h.warn(
                    "桥日志还不存在：" .. tostring(info.path),
                    "Godot 只在启动时加载编辑器插件 —— 第一次注入后需要重启一次编辑器"
                )
            end

            --------------------------------------------------------
            -- 把「哪些编辑器报错会发过来」讲清楚。
            --
            -- 默认不发编辑器侧的 GDScript 报错（和 LSP 诊断重复），不知情的
            -- 话很容易以为是插件坏了。
            --------------------------------------------------------

            if config.bridge and config.bridge.script_errors == true then
                h.info("编辑器侧 GDScript 报错：会转发（bridge.script_errors = true）")
            else
                h.info(
                    "编辑器侧 GDScript 报错：不转发（默认，和 gdscript LSP 诊断重复）",
                    "游戏运行以后的脚本报错不受影响，走 godot.log 那条路",
                    "想全都要就设 bridge.script_errors = true"
                )
            end

            h.info(("已收编辑器报错：%d 条"):format(info.count))
        end
    end

    h.start("godot-instance: 实例记录")

    local found = 0
    for key, record in pairs(records.read_records()) do
        found = found + 1
        local label = tostring(record.root or key)

        if util.pid_alive(record.pid) and util.tcp_reachable(record.lsp_port) then
            h.ok(("%s  pid=%s  LSP=%s（存活，可复用）"):format(label, tostring(record.pid), tostring(record.lsp_port)))
        else
            h.warn(("%s  pid=%s（已失效，下次 activate 会清掉）"):format(label, tostring(record.pid)))
        end
    end

    if found == 0 then
        h.info("没有记录（还没托管启动过实例）")
    end

    h.info("状态文件：" .. records.state_file())
end

return M
