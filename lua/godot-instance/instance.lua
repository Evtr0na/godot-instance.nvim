-- 编排层：activate / here / project / restart / stop / status。
-- 复用优先的判定、切换项目、以及托管实例的生命周期都收在这里。
local config = require("godot-instance.config").options
local state = require("godot-instance.state")
local util = require("godot-instance.util")
local project = require("godot-instance.project")
local reserve = require("godot-instance.reserve")
local records = require("godot-instance.records")
local reuse = require("godot-instance.reuse")
local process = require("godot-instance.process")
local lsp = require("godot-instance.lsp")
local godotdev = require("godot-instance.godotdev")

local notify = util.notify
local notify_unless_silent = util.notify_unless_silent
local normalize_path = util.normalize_path
local path_key = util.path_key
local same_path = util.same_path
local HOST = util.HOST
local project_root_for_file = project.project_root_for_file
local project_root_for_buf = project.project_root_for_buf
local project_pipe = project.project_pipe
local claim_server = reserve.claim_server
local release_server = reserve.release_server
local ensure_port_pair = reserve.ensure_port_pair
local forget_instance = records.forget_instance
local adopt_instance = reuse.adopt_instance
local release_adopted = reuse.release_adopted
local probe_reusable_instance = reuse.probe_reusable_instance
local managed_pid = process.managed_pid
local managed_alive = process.managed_alive
local instance_source_label = process.instance_source_label
local close_managed_godot = process.close_managed_godot
local start_godot = process.start_godot
local disable_lsp = lsp.disable_lsp
local enable_lsp = lsp.enable_lsp
local patch_lsp = lsp.patch_lsp
local patch_dap = lsp.patch_dap
local stop_dap_session = lsp.stop_dap_session
local ensure_plugin_ready = godotdev.ensure_plugin_ready

local M = {}

local function cleanup_active_project()
    disable_lsp()
    stop_dap_session()

    if state.project_server then
        release_server(state.project_server)
    end

    state.active_root = nil
    state.project_server = nil
    state.adopted = nil
end

local function finish_transition()
    state.transitioning = false
end

local function acquire_project(root)
    local address = project_pipe(root)
    local claimed, server_or_error = claim_server(address)
    if not claimed then
        return nil, "This Godot project is already active in another Nvim:\n" .. root
    end

    return server_or_error
end

local function opened_projects()
    local result = {}
    local seen = {}

    local function add(root)
        root = normalize_path(root)
        if not root then
            return
        end

        local key = path_key(root)
        if seen[key] then
            return
        end

        seen[key] = true
        table.insert(result, root)
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        add(project_root_for_buf(bufnr))
    end

    add(state.active_root)

    table.sort(result, function(a, b)
        return path_key(a) < path_key(b)
    end)

    return result
end

local function transition_guard(opts)
    if state.transitioning then
        notify_unless_silent(opts, "A Godot transition is already in progress", vim.log.levels.WARN)
        return false
    end

    return true
end

function M.activate(root, opts)
    opts = opts or {}

    -- Auto binding is intentionally one-shot. Once this Nvim owns a project,
    -- entering buffers from another project never switches it automatically.
    if opts.auto and state.active_root then
        return
    end

    root = normalize_path(root)
    if not root then
        notify_unless_silent(opts, "Invalid Godot project root", vim.log.levels.ERROR)
        return
    end

    if vim.fn.filereadable(vim.fs.joinpath(root, "project.godot")) ~= 1 then
        notify_unless_silent(opts, "project.godot not found:\n" .. root, vim.log.levels.ERROR)
        return
    end

    if not transition_guard(opts) then
        return
    end

    ------------------------------------------------------------
    -- 复用优先
    --
    -- 有已经在跑的 Godot（上一个 Nvim 托管启动并保活的，或者你自己开的那
    -- 个）就直接挂上去，省掉整个编辑器冷启动。
    --
    -- 必须发生在 ensure_plugin_ready() 之前：godotdev 的 setup 会读取
    -- state.lsp_port / state.dap_port，复用时要让它拿到复用实例的端口。
    ------------------------------------------------------------

    local previous_pid = managed_pid()
    local instance = probe_reusable_instance(root)

    -- 已经是当前项目、端口没变、实例也还在 —— 什么都不用做。
    if
        instance
        and same_path(root, state.active_root)
        and state.lsp_port == instance.lsp_port
        and (managed_alive() or instance.source == "external")
    then
        notify_unless_silent(opts, "Already active:\n" .. root)
        return
    end

    if instance then
        adopt_instance(instance)
    end

    if not ensure_plugin_ready(opts) then
        if instance then
            release_adopted()
        end
        return
    end

    -- 复用时这里直接返回，不会分配新的端口对。
    ensure_port_pair()

    local function notify_active(verb)
        notify_unless_silent(opts, string.format(
            "Godot %s:\n%s\nLSP :%d  DAP :%d\nInstance: %s",
            verb,
            root,
            state.lsp_port,
            state.dap_port,
            instance_source_label()
        ))
    end

    -- 要复用的实例不是“切换前正在用的那个托管实例”时，先把旧的关掉，
    -- 免得留下一堆孤儿编辑器。注意外部编辑器（你自己开的）不归我们管。
    local target_pid = instance and tonumber(instance.pid) or nil
    local must_close_previous = previous_pid ~= nil and previous_pid ~= target_pid

    if same_path(root, state.active_root) then
        state.transitioning = true
        state.generation = state.generation + 1
        local generation = state.generation

        local function start_again()
            disable_lsp()
            stop_dap_session()

            if instance then
                patch_lsp()
                patch_dap()
                enable_lsp()
                finish_transition()
                notify_active("reused")
                return
            end

            -- 要托管启动一个新实例：不能沿用复用实例的端口，重新分配一对。
            if state.adopted then
                release_adopted()
            end
            ensure_port_pair()

            patch_lsp()
            patch_dap()

            start_godot(root, generation, function(ok, err, failure_kind)
                if failure_kind == "launch" then
                    cleanup_active_project()
                end
                finish_transition()

                if not ok then
                    notify_unless_silent(opts, err, vim.log.levels.ERROR)
                    return
                end

                notify_active("active")
            end)
        end

        if must_close_previous then
            close_managed_godot({ force = opts.force == true, pid = previous_pid }, function(closed, err)
                if generation ~= state.generation then
                    return
                end

                if not closed then
                    finish_transition()
                    notify_unless_silent(opts, err or "Godot restart cancelled", vim.log.levels.WARN)
                    return
                end

                start_again()
            end)
            return
        end

        start_again()
        return
    end

    local target_server, acquire_error = acquire_project(root)
    if not target_server then
        -- This is the expected failure for auto-bind when another Nvim already
        -- owns the project, so silent auto-bind produces no warning popup.
        if instance then
            release_adopted()
        end
        notify_unless_silent(opts, acquire_error, vim.log.levels.WARN)
        return
    end

    state.transitioning = true
    state.generation = state.generation + 1
    local generation = state.generation
    local old_server = state.project_server

    local function abort_switch(message)
        release_server(target_server)
        finish_transition()
        if message then
            notify_unless_silent(opts, message, vim.log.levels.WARN)
        end
    end

    local function commit_switch()
        if generation ~= state.generation then
            release_server(target_server)
            return
        end

        disable_lsp()
        stop_dap_session()
        if old_server then
            release_server(old_server)
        end

        state.active_root = root
        state.project_server = target_server

        if instance then
            patch_lsp()
            patch_dap()
            enable_lsp()
            finish_transition()
            notify_active("reused")
            return
        end

        -- 要托管启动一个新实例：不能沿用复用实例的端口，重新分配一对。
        if state.adopted then
            release_adopted()
        end
        ensure_port_pair()

        patch_lsp()
        patch_dap()

        start_godot(root, generation, function(ok, err, failure_kind)
            if failure_kind == "launch" then
                -- The process never started. Do not leave a stale project pipe
                -- claiming ownership of a project with no managed Godot.
                cleanup_active_project()
            end

            finish_transition()

            if not ok then
                notify_unless_silent(opts, err, vim.log.levels.ERROR)
                return
            end

            notify_active("active")
        end)
    end

    if must_close_previous then
        close_managed_godot({ force = opts.force == true, pid = previous_pid }, function(closed, err)
            if generation ~= state.generation then
                release_server(target_server)
                return
            end

            if not closed then
                abort_switch(err or "Godot switch cancelled")
                return
            end

            commit_switch()
        end)
        return
    end

    commit_switch()
end

function M.auto_bind(bufnr)
    if state.transitioning or state.active_root then
        return
    end

    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local root = project_root_for_buf(bufnr)

    -- Covers starting Nvim from a Godot project with an unnamed initial buffer.
    if not root and vim.api.nvim_buf_get_name(bufnr) == "" then
        root = project_root_for_file(vim.fn.getcwd())
    end

    if not root then
        return
    end

    M.activate(root, {
        auto = true,
        silent = true,
    })
end

function M.here(opts)
    opts = opts or {}

    local root = project_root_for_buf(vim.api.nvim_get_current_buf())
    if not root then
        notify("Current buffer is not inside a Godot project", vim.log.levels.WARN)
        return
    end

    M.activate(root, opts)
end

function M.project(opts)
    opts = opts or {}

    if not ensure_plugin_ready() then
        return
    end

    local projects = opened_projects()
    if #projects == 0 then
        notify("No opened Godot projects found", vim.log.levels.WARN)
        return
    end

    vim.ui.select(projects, {
        prompt = "Godot Project",
        format_item = function(root)
            local marker = same_path(root, state.active_root) and "* " or "  "
            return marker .. vim.fs.basename(root) .. "    " .. root
        end,
    }, function(choice)
        if choice then
            M.activate(choice, opts)
        end
    end)
end

function M.restart(opts)
    opts = opts or {}

    if not ensure_plugin_ready() or not transition_guard() then
        return
    end

    if not state.active_root then
        notify("No active Godot project", vim.log.levels.WARN)
        return
    end

    state.transitioning = true
    state.generation = state.generation + 1
    local generation = state.generation
    local root = state.active_root

    local external = state.adopted ~= nil and state.adopted.source == "external"

    local function start_again()
        disable_lsp()
        stop_dap_session()

        -- 新实例要用新的端口对，复用的那一对还回去。
        if state.adopted then
            release_adopted()
        end
        ensure_port_pair()

        patch_lsp()
        patch_dap()

        start_godot(root, generation, function(ok, err, failure_kind)
            if failure_kind == "launch" then
                cleanup_active_project()
            end
            finish_transition()

            if not ok then
                notify(err, vim.log.levels.ERROR)
                return
            end

            notify(string.format(
                "Godot restarted:\n%s\nLSP :%d  DAP :%d\nInstance: %s%s",
                root,
                state.lsp_port,
                state.dap_port,
                instance_source_label(),
                external and "\n(你手动开的那个 Godot 编辑器仍然在运行)" or ""
            ))
        end)
    end

    if managed_alive() then
        close_managed_godot({ force = opts.force == true }, function(closed, err)
            if generation ~= state.generation then
                return
            end

            if not closed then
                finish_transition()
                notify(err or "Godot restart cancelled", vim.log.levels.WARN)
                return
            end

            start_again()
        end)
        return
    end

    start_again()
end

function M.stop(opts)
    opts = opts or {}

    if not ensure_plugin_ready() or not transition_guard() then
        return
    end

    if not state.active_root then
        disable_lsp()
        notify("No active Godot project")
        return
    end

    state.transitioning = true
    state.generation = state.generation + 1
    local generation = state.generation

    local function finish_stop()
        local was_external = state.adopted ~= nil and state.adopted.source == "external"
        local stopped_root = state.active_root

        cleanup_active_project()

        -- 外部编辑器不归我们管，记录也留着（下次还能复用）。
        if stopped_root and not was_external then
            forget_instance(stopped_root)
        end

        finish_transition()
        notify(was_external
            and "Detached from the external Godot editor (it keeps running)"
            or "Godot instance stopped")
    end

    if managed_alive() then
        close_managed_godot({ force = opts.force == true }, function(closed, err)
            if generation ~= state.generation then
                return
            end

            if not closed then
                finish_transition()
                notify(err or "Godot stop cancelled", vim.log.levels.WARN)
                return
            end

            finish_stop()
        end)
        return
    end

    finish_stop()
end

function M.status()
    if not ensure_plugin_ready() then
        return
    end

    ensure_port_pair()

    local active_client = nil

    -- godotdev 想把 client 命名成 "godot_editor"，但 patch_lsp() 里
    -- vim.lsp.config("gdscript", ...) 之后实际注册的名字是 "gdscript"，
    -- 所以两个都认（否则这里永远显示 false）。
    for _, client in ipairs(vim.lsp.get_clients()) do
        if client.name == "gdscript" or client.name == "godot_editor" then
            if state.active_root and same_path(client.root_dir, state.active_root) then
                active_client = client
                break
            end
        end
    end

    local pid = managed_pid()
    local godot_pid = pid and tostring(pid) or "-"

    if not pid and state.adopted and state.adopted.source == "external" then
        godot_pid = "external (not managed)"
    end

    local lines = {
        string.format("Nvim PID    : %d", vim.fn.getpid()),
        string.format("Nvim server : %s", vim.v.servername ~= "" and vim.v.servername or "-"),
        "",
        string.format("Project     : %s", state.active_root or "-"),
        string.format("Project RPC : %s", state.project_server or "-"),
        string.format("Instance    : %s", instance_source_label()),
        string.format("Godot PID   : %s", godot_pid),
        "",
        string.format("Godot LSP   : %s:%d", HOST, state.lsp_port),
        string.format("Godot DAP   : %s:%d", HOST, state.dap_port),
        string.format("LSP attached: %s", tostring(active_client ~= nil and active_client.initialized == true)),
        string.format("Transition  : %s", tostring(state.transitioning)),
    }

    notify(table.concat(lines, "\n"))
end

function M.active_root()
    return state.active_root
end

return M
