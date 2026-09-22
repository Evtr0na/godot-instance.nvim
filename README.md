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
| `:GodotBridge` | 编辑器报错桥状态（项目 / addon / 注入结果 / 已收条数） |
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

   **诊断的生命周期也跟 Godot 一致**：上一轮运行的报错会一直留着（改代码不会
   让它消失），直到**下一轮运行**开始才清空重来。详见下面
   「两条通道的诊断生命周期是故意不一样的」。

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
三种处理：

1. **根治（插件默认已经做了）**：`console_wrapper = true`。见下面「为什么能
   根治」—— 让 Godot 的父进程没有控制台，整条链就断了。
2. **根治（手工）**：把 Godot 编辑器放到**另一个** WezTerm pane / tab 里启动，
   别和 Nvim 共用一个终端。用 `:GodotStatus` 看「实例来源」—— 如果显示
   `external editor (reused)`，那就是复用了你在别处开的那个编辑器。
   注意：这种情况下插件管不到它的 console，仍然会污染那个 pane。
3. **兜底**（默认开）：`debuglog.redraw_on_output = true`。残影和日志增长是
   同一个进程同时发生的，所以一有新日志就整屏重绘一次，把残影压到一个轮询
   周期之内。按 `redraw_throttle_ms`（默认 500ms）节流；游戏疯狂 print 时会
   持续重绘，嫌闪就关掉。

#### 为什么能根治（实测定位到的机制）

从 Godot 源码读出来的（`platform/windows/os_windows.cpp`，`OS_Windows`
构造函数里**无条件**执行）：

```cpp
#ifndef WINDOWS_SUBSYSTEM_CONSOLE
	RedirectIOToConsole();
#endif
```

```cpp
void RedirectIOToConsole() {
	HANDLE h_stdout = GetStdHandle(STD_OUTPUT_HANDLE);   // 存旧的
	if (AttachConsole(ATTACH_PARENT_PROCESS)) {          // 挂到「父进程」的控制台
		...
		RedirectStream("CONOUT$", "w", stdout, STD_OUTPUT_HANDLE);
		RedirectStream("CONOUT$", "w", stderr, STD_ERROR_HANDLE);
	}
}
```

`RedirectStream` 只在 **CRT 里的流还不是有效句柄**时才改道（注释写得很清楚：
“if not redirected it's NULL handles not INVALID_HANDLE_VALUE”）。于是：

- **编辑器**是插件 spawn 的、`stdio` 给了 NUL（有效句柄），所以它自己不会
  往终端写 —— 但它已经 `AttachConsole` 到了**父进程（Nvim）的控制台**上；
- **游戏**走 Godot 内部的 `create_process()`：`STARTUPINFO` 被 `ZeroMemory`、
  `bInheritHandles=false`，于是拿到的是 **NULL** 句柄 —— 正好命中上面那个
  条件，stdout/stderr 被接到「编辑器挂着的那个控制台」，也就是 **Nvim 的终端**。

所以真正写屏的是**游戏**，不是编辑器。实测证据（隐藏控制台 + 读控制台进程
列表 `GetConsoleProcessList`）：

| 启动方式 | 挂在 Nvim 控制台上的进程 | 编辑器挂上去了吗 |
|---|---|---|
| 直接 spawn（旧行为） | powershell, **Godot471**, nvim, cmd | **是** |
| 套一层 detached `cmd.exe` | powershell, nvim, cmd | **否** |

**修法**：让 Godot 的父进程是一个 **detached（没有控制台）的 cmd.exe**。
`AttachConsole(ATTACH_PARENT_PROCESS)` 找不到可挂的控制台 → 编辑器没有控制台
→ 游戏也挂不上任何控制台 → 输出只进 `user://logs/godot.log`（那才是插件真正
在看的东西）。

代价是 `uv.spawn` 拿到的是 cmd 的 PID，所以插件会再用 CIM 查一次**真正的
Godot PID**（焦点守卫按前台窗口 PID 比对、`godot-close.ps1` 要
`MainWindowHandle`、实例记录也要它）。`cmd /c` 会等子进程退出，所以 `on_exit`、
存活判断、`:GodotStop` 的时序语义都不变。

两个例外（会退回旧行为，仍然污染终端）：

- `keep_alive = false`：那时要靠 libuv 的 job object 保证「Godot 活不过
  Nvim」，而 job object 里的进程**会继承控制台**，中间层就失效了 ——
  实测那种配置下编辑器又出现在控制台进程列表里。两者不可兼得。
- `godot_path` 含空格：`cmd /c` 的「命令行以引号开头」规则会吃掉首尾引号。

顺带说明：Godot 的 `application/run/disable_stdout = true` **治不了这个** ——
它只压掉 `print`（连日志文件里也没了），`push_error` / `SCRIPT ERROR` 照样
走 stderr。

### 编辑器报错桥（编辑器侧的报错）

上面那条 tail 日志的路，**看不到编辑器里编辑时的报错** —— 最典型的就是
gdshader 编译失败：它只进 Godot 的 Output 面板，不写进 `user://logs/godot.log`
（那个文件是游戏进程写的）。你贴的那种 `...gdshader#L1:C1-L1:C2147483647`
链接就是编辑器侧的报错。

这条路由**注入到项目里的 EditorPlugin** 补上：

- 插件把 `godot_addon/nvim_debug_bridge/` 写进 `<项目>/addons/nvim_debug_bridge/`
- 幂等地把 `res://addons/nvim_debug_bridge/plugin.cfg` 加进 `project.godot`
  的 `[editor_plugins] enabled`
- 插件用 **`OS.add_logger()`** 挂一个 `Logger`，把编辑器里的报错按 JSON 一行
  写进 `user://nvim_debug_bridge.log`，Nvim 这边 tail 它并转成诊断

用 `OS.add_logger` 而不是事后解析文本，是因为 `Logger._log_error` 直接给出
**精确的** `file` / `line` / `code` / `error_type`（含 `ERROR_TYPE_SHADER`），
不需要靠报错行文本去反查文件。实测：

```
{"type":3,"file":"res://broken.gdshader","line":4,
 "code":"Unknown identifier in expression: 'undeclared_thing'."}
```

→ Nvim 里就是 `broken.gdshader:4` 的诊断，`source = "godot-editor"`。
引擎自身的位置（`servers/...`、`modules/...`、`./...`）会跳过。

**两个机制是互补的，不是替代**：桥抓编辑器侧，日志 tail 抓游戏运行时
（游戏是另一个进程，编辑器插件看不到它）。

**编辑器侧的 GDScript 报错默认不发**（`bridge.script_errors = false`）：

那类报错和 godotdev.nvim 的 LSP 诊断是**同一份东西** —— 同一个 GDScript
解析器、同一批语法错误，编辑器插件只是又抄了一份给你。两边都报就是重复，
而且对你已经知道的问题再喊一遍没有价值。

游戏跑起来之后的脚本报错**不受这个开关影响** —— 那是游戏进程写进
`godot.log` 的，走上面那条 tail 日志的路。也就是说你要的「运行以后的调试
报错」一直都有；这里关掉的只是「编辑器里就存在的、LSP 也能看到的」那些。

改回老行为：`bridge.script_errors = true`（那时
`collapse_script_parse_errors` 的级联抑制才有意义）。

几个要注意的：

- **Godot 只在启动时加载编辑器插件**，所以第一次注入后要**重启一次编辑器**
  （或在 Godot 里「项目 → 重新加载当前项目」）。
- 注入会**改 `project.godot`**（会出现在 git diff 里）。不想要就把
  `bridge.auto_enable = false`，然后自己去「项目设置 → 插件」勾一次。
- addon 文件内容一致就复用；内容不同**但不是我们注入的**（没有
  `managed-by: godot-instance.nvim` 标记）就绝不覆盖，只提示。
- `:GodotBridge` 看当前状态（项目 / addon 路径 / 注入结果 / 桥日志 / 已收条数）。
- 同一个 `(类型, 文件, 行, 消息)` 只发一次诊断 —— shader 会反复重编译，
  不去重会把诊断刷爆。
- 编辑器报错**也会写进调试面板**（`[editor/SHADER] ...` 那种行），所以
  `<leader>gD` 就能实时看到；不想要就 `bridge.show_in_panel = false`。

**报错是实时的，不需要切窗口**：

早期版本只连 `EditorFileSystem.filesystem_changed`，而那个信号**只在编辑器
自己重新获得焦点、跑一遍文件系统刷新时才可靠地到来**。你在 Nvim 里保存
shader 时焦点在 Nvim 上，Godot 收不到通知 —— 表现就是「故意改错，必须切到
Godot 再切回来才报错；改对了也要切过去才响应」。

现在 addon 不再依赖任何信号，自己用 `Timer` 每 **0.3 秒**按 mtime 轮询一遍
（`_compile_if_changed` 有 mtime 闸门，没变就立刻返回，代价只是一次目录
遍历）。保存到 Nvim 里出现诊断的延迟实测 **≤ 0.4 秒**，全程不需要和 Godot
窗口有任何交互。

> 踩过的坑：这个轮询一开始加了一道 `is_playing_scene()` 闸门（「游戏在跑就
> 别去重编译」）。结果是：只要你 F5 起的游戏还活着，轮询就一直是空的，只剩
> 编辑器那个跟焦点绑定的 `filesystem_changed` 在干活 —— 症状跟没修一样
> （「必须把焦点交给 Godot 才报错」）。**这道闸已经去掉**：`_compile_if_changed`
> 本来就有 mtime 闸门，变了也只是把代码挂到一个临时 `ShaderMaterial` 上逼引擎
> 编译一次，不动你的任何资源（编辑器自己在你编辑 shader 时就是这么干的）。

**「看起来像乱报」的坑，插件已经处理掉了**：

1. **越界行号**：解析器恢复失败时会报出**超出文件末尾**的行号（实测 196 行的
   文件报 198）。现在会钳到最后一行的位置，诊断和面板都显示钳过的行号。
2. **同一个 shader 报两条**：引擎在具体错误（`Unknown identifier ...`）之后
   还会补一条通用的 `shader_set_code` / `Shader compilation failed.`。它没有
   额外信息，addon 会把后者丢掉，一个错误只留一条诊断。

**诊断会跟着文件走（不再「挂着旧报错」）**：

**两条通道的诊断生命周期是故意不一样的**：

| 通道 | 管什么 | 什么时候消失 |
|---|---|---|
| 桥 `bridge.lua` | **编辑器侧**报错（gdshader 编译失败等） | 文件内容真的改了 |
| 日志 `debuglog.lua` | **游戏运行期**报错 | **下一轮运行开始** |

理由：编辑器侧的报错描述的是**当前这份代码**，你把 shader 改对，那个错就真的
不存在了，所以它必须跟着文件走。而运行期报错属于**跑完的那一轮运行**，是一份
历史 —— 你改代码并不会让上一轮运行的报错「没发生过」。这也正是 Godot 自己
调试器面板的行为：**上一次运行的报错会一直留着，直到你下次运行**。

**编辑器侧（bridge.lua）怎么判「文件真的改了」**：

- addon 在每个事件里带上**报这份代码时的源文件 mtime**
  （`FileAccess.get_modified_time`，在强制编译那一刻取的，不是打印报错那一刻）；
- Nvim 拿到事件先跟当前 mtime 比对，并且**还要比一次内容指纹**（sha256）：
  mtime 不一致**不等于**内容变了 —— 同一份代码再保存一次也会改 mtime，那种
  情况这条报错依然有效，不能丢。只有内容真的变了才算旧版本、才丢掉；
- 每轮轮询同样按「mtime + 内容指纹」判断已有诊断所属文件是否真的变了，变了才
  作废 —— 所以「改好之后 Godot 不再报错」的情况旧诊断会自动消失；而
  **「我没改代码、只是又保存了一次」的诊断不会再被误清**。

**运行期（debuglog.lua）刻意不做文件过期**：

`poll()` 里**没有**「文件改动就清诊断」这一步。清空只发生在日志轮转
（`size < offset`）或读到新的启动横幅时 —— 也就是**新一轮运行**：先
`clear_diagnostics()`，再按新日志重新发布。所以：

- 改代码（改对也好、改成另一个错也好）都不会动上一轮的报错；
- 下一次运行如果干净，旧报错才消失；如果还错，显示的就是这次的新报错。

> 实测过的坑（三个都要记住）：
>
> 1. 编辑器侧只比 mtime 会误杀：再保存一次同样的错误代码，诊断被清掉、而引擎
>    可能还没来得及重报 —— 表现就是「我没改代码，报错却自己消失了，切到 Godot
>    再回来又出现」。所以 mtime 变了之后还要再对一次内容指纹。
> 2. 运行期**不能**套用上面那套过期逻辑（试过 mtime、又试过加内容指纹，都错）：
>    结果是「我一改代码报错就没了」，而游戏根本还没重跑 —— 既丢了一份还有效的
>    历史，又让人误以为已经修好了。
> 3. `file_state`（旧名 `file_stamp`）一律用 `path_key(path)` 做键，**不要**用
>    路径字符串。事件里的路径和 buffer 名字可能是同一个文件的不同写法，混用键
>    的话过期检查会静默失效（排查过：诊断永远不过期，正是这个原因）。

**addon 会主动把改动过的 `.gdshader` 编译一遍**：

Godot **只在实际编译某个 shader 时才报它的错**。你在 Nvim 里改了一个
`.gdshader`，如果编辑器当前开的是别的场景（那个 shader 没被加载），Godot
根本不会编译它 —— 也就没有报错可抓，表现就是「故意写错但没报」。

所以 addon：

- `_enter_tree` 里延迟 1 秒**主动全量扫一遍**（`filesystem_changed` 只在
  「真的有变动」时触发，项目没动过就一次都不来）；
- 连 `EditorFileSystem.filesystem_changed`，文件一变就扫（按 mtime 只处理真变
  了的，节流 0.5s，跳过 `addons/`）；
- **另外每 0.3 秒自己轮询一遍**，因为 `filesystem_changed` 依赖编辑器获得焦点
  （见上面「报错是实时的」）；
- 对每个变了的 `.gdshader` 做 `load` + 挂到临时材质上，把编译逼出来。

**报错文案优先用 Godot 自己的**：

以前 addon 会自己判「第一行是不是 `shader_type`」，命中就直接短路掉编译、甩一句
自己编的话（`Shader 缺少 shader_type 声明...`）。问题是 Godot 的 shader 编辑器
里显示的是

```
Error at line 1: Expected 'shader_type' at the beginning of shader.
                 Valid types are: 'spatial', 'canvas_item', 'particles', 'sky', 'fog', 'texture_blit'.
```

两边字不一样，看着就像插件在瞎报。现在不短路了：**先真的编译一次**，优先用引擎
经由 Logger 报出来的原文（实测 headless/dummy 渲染器下就会报出上面这句）。

只有引擎确实一条都没报、而文件又缺 `shader_type` 时，才补一条兜底，**文案照抄
引擎的说法**。另外 `load` 直接失败（连资源都不是 `Shader`）时引擎不吭声，那种
情况仍然由 addon 造一条。

另外：**这次编译是 addon 自己发起的**，所以引擎级联错的 `at:` 往往是
`servers/...cpp` 这种没有 `res://` 的位置。addon 会把「正在编译的目标文件」
标给 Logger，Nvim 那边就能定位到你的 shader 而不是引擎内部；Nvim 也会跳过
桥自己 addon 的 `res://` 帧（否则诊断会指到 `bridge.gd` 上）。

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
    -- 编辑器报错桥（编辑器侧的报错，含 gdshader）
    ------------------------------------------------------------
    bridge = {
        enabled = true,
        inject = true,       -- 把 addon 写进 <项目>/addons/nvim_debug_bridge/
        auto_enable = true,  -- 自动改 project.godot 勾上插件（会出现在 git diff 里）
        interval_ms = 200,
        -- 编辑器侧的 GDScript 报错默认不发（和 LSP 诊断重复）。
        -- 「游戏运行以后的调试报错」不受这个开关影响，一直都有。
        script_errors = false,
        -- log_path = nil,   -- 手动指定桥日志路径；nil = user://nvim_debug_bridge.log
    },

    ------------------------------------------------------------
    -- Windows 焦点
    ------------------------------------------------------------
    preserve_focus_on_start = true,    -- 启动 Godot 后把焦点抢回终端
    focus_guard_timeout_ms = 5000,
    focus_guard_poll_ms = 40,
    lsp_port_poll_ms = 25,

    -- 启动 Godot 时套一层 detached cmd.exe，免得它 AttachConsole 到 Nvim 的
    -- 终端上（游戏输出会直接写进 Nvim 画面）。仅 Windows、且 keep_alive = true
    -- 时生效。详见「终端残影」一节。
    console_wrapper = true,
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
