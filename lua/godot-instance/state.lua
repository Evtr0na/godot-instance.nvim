-- 运行期状态（单例表）。所有模块直接持有这张表本身，因此字段可以随便改，
-- 但不要整体重新赋值。
return {

    bootstrapped = false,
    plugin_ready = false,
    transitioning = false,

    lsp_port = nil,
    dap_port = nil,
    port_lock_server = nil,
    active_root = nil,
    project_server = nil,

    godot_process = nil,
    godot_process_pid = nil,
    generation = 0,

    -- 复用来的实例：{ source = "managed" | "external", pid = number|nil }
    adopted = nil,

}
