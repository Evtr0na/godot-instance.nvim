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
