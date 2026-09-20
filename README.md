# godot-instance.nvim

Nvim 多开 + Godot 多开的实例管理器，配合 [godotdev.nvim](https://github.com/Mathijs-Bakker/godotdev.nvim) 使用。

**它解决的问题**：从 Godot 项目根目录启动 Nvim 时，为了拿到 gdscript LSP 要等 5-6 秒
（那是 Godot 编辑器冷启动的时间，不是 LSP 连接的时间）。本插件让 Nvim：

- **复用优先** —— 已经有 Godot 在跑（你手动开的，或上次 Nvim 托管启动后保活下来的）就直接挂上去，
  实测 **~150ms** 可用，且不会再多开一个编辑器窗口；
- **托管保活** —— 需要它自己启动 Godot 时，让 Godot 活过 Nvim，下次启动直接复用；
- **真正的多开** —— 每个 Nvim 托管自己的 Godot 实例，各自一套 LSP/DAP 端口 + 项目专属 RPC 管道，
  不同项目互不干扰，同一个项目同时只允许一个 Nvim 托管（用命名管道做互斥）。

## 安装

用 lazy.nvim（`dir` 指向本插件，或换成你 push 上去的仓库地址）：

```lua
{
    dir = "D:/2zhuomian/app/neovim-tool/godot-instance.nvim",
    lazy = false, -- 必须启动时加载：VimEnter 的自动绑定要在启动阶段注册好
    opts = {
        godot_path = "D:/path/to/Godot.exe",
    },
    config = function(_, opts)
        require("godot-instance").setup(opts)
    end,
}
```

插件本身是纯 Lua，启动开销约 2ms（`godotdev.nvim` 依然是按需加载的，不会拖慢启动）。

然后在 **godotdev.nvim 的 spec** 里把 `config` 交给本插件（一行）：

```lua
{
    "Mathijs-Bakker/godotdev.nvim",
    ft = { "gd", "gdscript" },
    dependencies = {
        "mfussenegger/nvim-dap",
        "rcarriga/nvim-dap-ui",
        "nvim-treesitter/nvim-treesitter",
    },
    opts = {
        godot_path = "D:/path/to/Godot.exe",
        autostart_editor_server = false,
        -- ...你原来的偏好设置...
    },
    config = function(_, opts)
        require("godot-instance").godotdev(opts)
    end,
}
```

`require("godot-instance").godotdev(opts)` 会：

1. 把本实例的 LSP/DAP 端口注入 opts（`editor_host` / `editor_port` / `debug_port`）；
2. 在 `godotdev.setup()` 期间拦掉它自己那次“过早的” `vim.lsp.enable("gdscript")`
   （那时 Godot 的 LSP 端口往往还没起来，Windows 上会留下 `Client gdscript quit with exit code 1`）；
3. setup 之后接管：保持 LSP disabled 直到端口真的可连、装上 active-project `root_dir` gate、
   修正 DAP 端口、禁掉 godotdev 自带的通用 editor-server 自动层；
4. 把 gdscript 的 filetypes 限制回 `"gdscript"`。

## Godot 侧设置（“在 Nvim 里打开”）

用 `:GodotPaths` 打印当前路径，然后填到 Godot 里：

**编辑器设置 → 文本编辑器 → 外部**

| 字段 | 值 |
| --- | --- |
| Exec Path | `<插件目录>/scripts/godot-nvim.cmd` |
| Exec Flags | `"{file}" {line} {col}` |

`godot-nvim.cmd` → `godot-nvim-router.ps1` 会算出当前项目的专属管道名，
用 `nvim --server <pipe> --remote-expr "v:lua.godot_remote_open(...)"` 把文件丢给**正在跑的** Nvim。
管道名是按项目根目录的 sha256 算的，所以永远不会串到别的 Nvim 实例。

## 命令

| 命令 | 说明 |
| --- | --- |
| `:GodotHere[!]` | 把当前 buffer 所属项目设为活动项目（`!` 强关旧的托管 Godot） |
| `:GodotProject[!]` | 从已打开的项目里选一个激活 |
| `:GodotRestart[!]` | 重启托管的 Godot（`!` 丢弃未保存改动） |
| `:GodotStop[!]` | 关闭托管的 Godot（外部编辑器只会“脱离”，不会被杀） |
| `:GodotStatus` | 当前项目 / 实例来源 / 端口 / LSP 是否 attach |
| `:GodotPaths` | 插件自带脚本路径 + Godot 侧该怎么填 |
| `:checkhealth godot-instance` | 完整体检 |

自动绑定：从 Godot 项目根目录启动 Nvim 时会自动激活该项目（`BufEnter` / `VimEnter`）。
自动绑定是**一次性**的 —— 一旦这个 Nvim 拥有了项目，切到别的项目的 buffer 不会自动换项目，
需要显式 `:GodotHere` / `:GodotProject`。

## 配置

```lua
require("godot-instance").setup({
    ------------------------------------------------------------
    -- Godot
    ------------------------------------------------------------
    godot_path = "godot",              -- Godot 可执行文件

    ------------------------------------------------------------
    -- 复用（极速的关键）
    ------------------------------------------------------------
    reuse = true,                      -- 复用总开关
    keep_alive = true,                 -- 托管 Godot 活过 Nvim（false = 每次冷启动）
    reuse_external = true,             -- 也复用“不是本 Nvim 托管”的 Godot
    reuse_external_ports = { 6005 },   -- 外部编辑器的 LSP 端口候选
    reuse_external_dap_offset = 1,     -- 外部编辑器的 DAP = LSP + 这个偏移
    reuse_external_verify = true,      -- 用窗口标题里的项目名校验，避免连错项目

    ------------------------------------------------------------
    -- 生命周期
    ------------------------------------------------------------
    startup_timeout_ms = 15000,        -- 等 LSP 端口的上限
    close_timeout_ms = 30000,          -- 优雅关闭的等待上限
    force_close_timeout_ms = 5000,     -- 强杀后的等待上限
    port_min = 16000,                  -- 托管实例的端口对范围
    port_max = 49000,
    state_dir = nil,                   -- 实例记录目录，nil = stdpath("state")/godot_instance

    ------------------------------------------------------------
    -- Windows 焦点
    ------------------------------------------------------------
    preserve_focus_on_start = true,    -- 启动 Godot 后把焦点抢回终端
    focus_guard_timeout_ms = 5000,
    focus_guard_poll_ms = 40,
    lsp_port_poll_ms = 25,
})
```

## 工作原理

**端口**：每个 Nvim 启动时从 `port_min..port_max` 里挑一对空闲端口（LSP/DAP），并用
`\\.\pipe\nvim-godot-port-<lsp>-<dap>` 命名管道占住，保证多开不撞。

**项目互斥**：`\\.\pipe\nvim-godot-project-<sha256(项目根)>`。同一个项目同时只允许一个 Nvim
托管（另一个 Nvim 会自动绑定失败并静默退出，不会弹窗）。

**实例记录**：`stdpath("state")/godot_instance/instances.json`，形如
`{ "d:/path/to/project": { pid, lsp_port, dap_port, ... } }`。
启动时校验 `pid` 存活（`uv.kill(pid, 0)`）**且** LSP 端口可连（同步 TCP 探测，<1ms）才复用；
过期记录自动清掉。

**进程启动**：用 `uv.spawn` 而不是 `vim.system`，两个原因：

1. `vim.system` 硬编码 `hide = true`，libuv 会据此设置 `STARTF_USESHOWWINDOW + SW_HIDE`，
   Godot 的编辑器窗口会**以隐藏状态创建**：你看不见它，而且它没有 `MainWindowHandle`，
   于是优雅关闭（`scripts/godot-close.ps1` 发 WM_CLOSE）会直接失败；
2. `vim.system` 不暴露 process handle，没法 `unref`。

配合 `detached = true` + `handle:unref()`，Godot 才能活过 Nvim。

**外部编辑器校验**：Godot 4 的编辑器窗口标题形如 `scene.tscn - 项目名 - Godot Engine`，
所以复用 6005 之前会枚举顶层窗口标题，确认里面有当前项目名（归一化后匹配，且必须同时出现
`godot`）。项目名太短或不是 ASCII 时宁可退回托管启动。

## 已知限制

- **只在 Windows 上完整可用**：窗口标题校验、焦点守卫、优雅关闭（`godot-close.ps1`）依赖
  Win32。非 Windows 上仍可用，但只能强杀（`:GodotStop!`）。
- **`keep_alive = true` 的一个副作用**：存活的 Godot 会持有从 Nvim 继承的管道句柄，
  所以**用管道捕获 Nvim 输出**的启动器（`nvim ... | xxx`）要等 Godot 退出才返回。
  交互式终端不受影响。真受影响就把 `keep_alive = false`（此时“Godot 已开着就秒连”仍然有效）。
- **托管实例会常驻**：`keep_alive` 下 Nvim 退出不会关掉自己启动的 Godot（这是刻意的，
  避免丢弃未保存的场景改动）。用 `:GodotStop` 关，或跨项目时留意后台会有多个 Godot。
- **复用外部编辑器有连错项目的可能**：默认靠窗口标题校验兜着；万一漏判，Godot 自己也会发
  `The GDScript Language Server might not work correctly with other projects...`。
  要绝对保守就把 `reuse_external = false`。

## 卸载（即插即拔）

1. 删掉 lazy spec 里本插件那一段；
2. 把 godotdev spec 的 `config` 改回你自己的 `require("godotdev").setup(opts)`；
3. 删掉插件目录，以及 `stdpath("state")/godot_instance/`；
4. Godot 里把外部编辑器指回你原来的脚本（或留空）。

Nvim 配置里不需要任何残留代码。

## License

MIT
