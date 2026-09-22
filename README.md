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

**Exec Flags 一定要填 `"{file}" {line} {col}`。** Godot 的「Vim」预设是
`"+call cursor({line}, {col})" {file}`，参数顺序完全不同；用那套的话路由器
会拿 `+call cursor(5, 3)` 当文件名，`Test-Path` 失败直接退出，表现就是
**双击完全没反应**。

路由器现在两种写法都能认（会在参数里找第一个真实存在的文件，并从
`cursor(N, M)` 里取行列），但推荐还是填标准的那套。

排查「双击没反应」时可以设 `GODOT_INSTANCE_ROUTER_LOG=<文件路径>`，
路由器会把每一步和退出码写进去：

| 退出码 | 含义 |
| --- | --- |
| 10 | 参数里找不到真实存在的文件（多半是 Exec Flags 填错） |
| 11 | 找不到 `project.godot` |
| 20 | RPC 失败 —— 通常是那个项目没有正在跑的 Nvim |

另外 `scripts/*.cmd` / `*.ps1` **必须保持纯 ASCII**：cmd.exe 按 OEM 代码页
读 `.cmd`，Windows PowerShell 5.1 按系统 ANSI 代码页读无 BOM 的 `.ps1`，
塞中文注释会让它们解析出错。

## 命令

| 命令 | 说明 |
| --- | --- |
| `:GodotHere[!]` | 把当前 buffer 所属项目设为活动项目（`!` 强关旧的托管 Godot） |
| `:GodotProject[!]` | 从已打开的项目里选一个激活 |
| `:GodotRestart[!]` | 重启托管的 Godot（`!` 丢弃未保存改动） |
| `:GodotStop[!]` | 关闭托管的 Godot（外部编辑器只会“脱离”，不会被杀） |
| `:GodotStatus` | 当前项目 / 实例来源 / 端口 / LSP 是否 attach |
| `:GodotPaths` | 插件自带脚本路径 + Godot 侧该怎么填 |
| `:GodotDebugLog` | 开关调试日志面板（编辑器里 F5 / F6 的原始输出） |
| `:GodotDebugErrors` | 展示报错列表（trouble.nvim 优先，quickfix 兜底） |
| `:GodotDebugQuickfix` | 只把 Godot 报错灌进 quickfix（不依赖任何插件） |
| `:GodotDebugNext` / `:GodotDebugPrev` | 在 Godot 报错之间跳转 |
| `:GodotDebugPath` | 显示日志文件路径 |
| `:GodotDebugClear` | 清空面板和诊断（日志文件本身不动） |
| `:checkhealth godot-instance` | 完整体检 |

自动绑定：从 Godot 项目根目录启动 Nvim 时会自动激活该项目（`BufEnter` / `VimEnter`）。
自动绑定是**一次性**的 —— 一旦这个 Nvim 拥有了项目，切到别的项目的 buffer 不会自动换项目，
需要显式 `:GodotHere` / `:GodotProject`。

## 调试日志（编辑器里按 F5 / F6 的报错）

**要解决的问题**：在 Godot 编辑器里按 F5 / F6 启动游戏时，游戏的 stdout/stderr
被编辑器自己吞掉写进它的 Debugger 面板，Nvim 这边什么都看不到。
（godotdev.nvim 的 run console 只能抓「Nvim 自己启动」的游戏 —— 它是父进程
才能拿到管道，覆盖不到 F5/F6。）

**通道**：Godot 桌面平台默认开启文件日志
（`debug/file_logging/enable_file_logging.pc` 默认 `true`），游戏进程会把
`print` / `push_error` / `SCRIPT ERROR` / GDScript backtrace 逐行 flush 写进

```
<user_data_dir>/logs/godot.log
```

编辑器 F5/F6 启动的游戏同样写这个文件，所以 tail 它就够了，**Godot 侧不需要
装任何插件**。实测每行毫秒级落盘，不是退出才写。

**两条出口**：

1. **面板**（`:GodotDebugLog`）—— 原始日志，行为和 Godot 自己的 Output 面板
   一致：每轮运行清空重来（Godot 每跑一次会把旧日志改名成
   `godot<时间戳>.log` 再新建）。面板里 `<CR>` 可以跳到光标所在行的
   `res://` 位置。
2. **诊断**（`vim.diagnostic`）—— 把报错解析成真正的 LSP 诊断，于是
   trouble.nvim / `vim.diagnostic.jump` / 行号符号 / 内联提示全都直接可用，
   不需要本插件知道 trouble 的存在。

**展示出口不是硬依赖**：`:GodotDebugErrors` 优先用 trouble.nvim
（`Trouble diagnostics toggle`），没装就退回 quickfix。`<leader>xx` 之类的
Trouble 映射会自然看到这些诊断，因为它们是标准诊断。

`res://` 会映射回项目里的真实路径；引擎自身的报错（`core/...cpp:123`）在磁盘上
不存在，所以不生成诊断 —— 它们在面板里照样能看到。

**gdshader 报错也包含在内**。Godot 的 shader 报错格式比较坑：

```
--Main Shader--
    3 | void fragment() {
E   4->  COLOR = vec4(undeclared_variable, 0.0, 0.0, 1.0);
    5 | }
SHADER ERROR: Unknown identifier in expression: 'undeclared_variable'.
   at: (null) (:4)
```

`at: (null) (:4)` **没有文件名**，段头 `--Main Shader--` 也是固定标签（实测与
节点名、加载方式都无关）。所以插件拿出错行（`E 4-> ...`）的源码文本去项目里的
`*.gdshader` / `*.gdshaderinc` 反查：**行号对得上、内容也一致的文件只有一个**
才认定；对不上或有歧义就不生成诊断（宁可没有，也不指到错误的文件上）。

另外 `[Resource file res://xxx.tscn:9]` 这种带路径的资源报错也会被识别。

### 终端残影（日志“盖”在代码上）

如果 Godot 编辑器和 Nvim **共用同一个终端**（同一个 pty —— 比如你在某个
WezTerm pane 里先起了 Godot 编辑器，之后又在同一个 pane 里跑 Nvim；
godot-instance 复用它时不会改它的 console），那么编辑器 F5 起的游戏会继承
那个 pty，**stdout 直接写进 Nvim 的画面**。

特征很好认（对照实际截图确认过）：

- 文字**从第 0 列写进去**，压住行号栏 —— 正常代码绝不会出现在那里；
- 光标所在行会出现「左半行正常、右半行是日志」；
- 把光标移到那些位置就恢复（Nvim 重绘了那几行），切 buffer 也会恢复；
- gdshader 报错更顽固，因为 shader 会反复重编译、反复往终端写。

**这不是 Nvim 画的，Nvim 也拦不住**（它没法阻止别的进程往同一个 pty 写）。
两种处理：

1. **根治**：把 Godot 编辑器放到**另一个** WezTerm pane / tab 里启动，别和
   Nvim 共用一个终端。用 `:GodotStatus` 看「实例来源」—— 如果显示
   `external editor (reused)`，那就是复用了你在别处开的那个编辑器。
2. **兜底**（默认开）：`debuglog.redraw_on_output = true`。残影和日志增长是
   同一个进程同时发生的，所以一有新日志就整屏重绘一次，把残影压到一个轮询
   周期之内。按 `redraw_throttle_ms`（默认 500ms）节流；游戏疯狂 print 时会
   持续重绘，嫌闪就关掉。

顺带说明：Godot 的 `application/run/disable_stdout = true` **治不了这个** ——
它只压掉 `print`（连日志文件里也没了），`push_error` / `SCRIPT ERROR` 照样
走 stderr。

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
    -- 调试日志（编辑器里 F5 / F6 的报错）
    ------------------------------------------------------------
    debuglog = {
        enabled = true,
        interval_ms = 200,      -- 轮询间隔；日志逐行 flush，200ms 已经够实时
        auto_open = false,      -- 新一轮运行是否自动弹面板（默认关，别凭空多分屏）
        position = "bottom",    -- "bottom" | "right" | "float"
        size = 0.3,
        max_lines = 5000,
        log_path = nil,         -- 手动指定；nil = 按项目名自动推导
        diagnostics = {
            enabled = true,     -- 解析成 vim.diagnostic（Trouble 等直接用）
        },
        -- 终端残影兜底：一有新日志就整屏重绘（编辑器与 Nvim 共用 pty 时用）
        redraw_on_output = true,
        redraw_throttle_ms = 500,
        -- 插件默认不占键位，要快捷键就显式给
        keymap = false,         -- 开关面板
        keymap_errors = false,  -- 报错列表（Trouble 优先，quickfix 兜底）
    },

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
- **调试日志依赖 Godot 的文件日志**：桌面平台默认开着
  （`debug/file_logging/enable_file_logging.pc = true`）。项目里显式把
  `debug/file_logging/enable_file_logging` 关掉的话，游戏就不写日志文件，
  面板会是空的。`:checkhealth godot-instance` 会提示。

## 卸载（即插即拔）

1. 删掉 lazy spec 里本插件那一段；
2. 把 godotdev spec 的 `config` 改回你自己的 `require("godotdev").setup(opts)`；
3. 删掉插件目录，以及 `stdpath("state")/godot_instance/`；
4. Godot 里把外部编辑器指回你原来的脚本（或留空）。

Nvim 配置里不需要任何残留代码。

## License

MIT
