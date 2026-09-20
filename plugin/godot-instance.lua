-- godot-instance.nvim
--
-- 即插即拔：装好就能用，不写任何配置也行（godot_path 默认 "godot"）。
-- 这里先做一次引导，把命令和自动绑定装上；
-- 之后 lazy 的 opts 会调用 setup(opts) 再合并一次配置（幂等）。
--
-- 想完全关掉自动引导（例如只手动调用 API）：
--     vim.g.godot_instance_no_auto_bootstrap = 1
if vim.g.godot_instance_no_auto_bootstrap ~= 1 then
    require("godot-instance").setup()
end
