@tool
extends EditorPlugin

# ---------------------------------------------------------------------------
# Nvim Debug Bridge —— 由 godot-instance.nvim 自动注入到项目的 addons/ 下。
#
# 它做一件事：把 Godot 编辑器里产生的**全部**报错转给 Neovim。
#
# 为什么需要它：编辑器侧的报错（最典型的是 gdshader 编译失败）只进 Godot 的
# Output 面板，**不会**写进 user://logs/godot.log（那个文件是游戏进程写的）。
# 所以 Nvim 那边 tail 日志只能看到「跑起来的游戏」的报错，看不到你编辑
# shader 时的报错。
#
# 钩子用的是 OS.add_logger()：Logger._log_error 会给出**精确的**
# file / line / code / error_type（含 ERROR_TYPE_SHADER），比事后拿报错
# 文本去反查文件可靠得多。
#
# 输出：user://nvim_debug_bridge.log，一行一个 JSON 对象。
#
# 注意：本文件由插件管理，**不要手改**（改了会在下次注入时被覆盖）。
# 判断依据就是下面这行标记。
# ---------------------------------------------------------------------------

const MANAGED_MARKER := "managed-by: godot-instance.nvim"
const BRIDGE_LOG := "user://nvim_debug_bridge.log"

# 缺 shader_type 时的兜底文案。
#
# 照抄引擎自己的说法（Godot 的 shader 编辑器里显示的就是这句），这样 Nvim
# 里看到的字和 Godot 面板里的一致，不会被当成「插件自己编的报错」。
const MSG_MISSING_SHADER_TYPE := "Expected 'shader_type' at the beginning of shader. Valid types are: 'spatial', 'canvas_item', 'particles', 'sky', 'fog', 'texture_blit'."

# 刻意不标类型 Logger：下面要用它自己的成员（target / synthetic），
# 标成基类的话 GDScript 会在解析期就报「基类里没有这个成员」，
# 插件随即静默加载失败（实测踩过）。
var _logger = null

# path -> FileAccess.get_modified_time()，用来判断哪些 shader 真的变了
var _shader_stamp := {}
var _scan_busy := false
var _scan_at := 0.0

# 轮询兜底用的定时器（见 _on_poll_timeout 上面的注释）
var _poll_timer: Timer = null

func _enter_tree() -> void:
	# 新一轮编辑器会话：清掉上一轮的日志，让 Nvim 那边从零开始读
	_truncate()

	_logger = NvimBridgeLogger.new()
	OS.add_logger(_logger)

	# 文件系统一变就重新扫一遍 shader。
	#
	# 为什么必须这么做：Godot **只在实际编译某个 shader 时才报它的错**。
	# 如果你在 Nvim 里改了一个 .gdshader，而编辑器当前开的是别的场景
	# （那个 shader 没被加载），Godot 根本不会编译它 —— 也就没有报错可抓。
	# 这里主动 load + 挂到临时材质上，把编译逼出来。
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.filesystem_changed.connect(_on_filesystem_changed)

	# 启动时先主动扫一遍。
	#
	# filesystem_changed 只在「真的有变动」时触发 —— 项目没动过就一次都不来，
	# 那样启动时就存在的 shader 错误永远抓不到（实测：桥日志是 0 字节）。
	get_tree().create_timer(1.0).timeout.connect(_force_scan)

	# -----------------------------------------------------------------------
	# 定时轮询 —— 这一条是「实时」的关键。
	#
	# filesystem_changed 只有在**编辑器自己重新获得焦点**、跑一遍文件系统
	# 刷新时才可靠地到来。你在 Nvim 里保存 shader 时焦点在 Nvim 上，Godot
	# 收不到那个通知 —— 表现就是「改完必须切到 Godot 再切回来才报错」。
	#
	# 所以这里不依赖任何信号，自己按 mtime 轮询。_compile_if_changed 有
	# mtime 闸门，没变就立刻返回，所以每轮的代价只是一次目录遍历。
	# -----------------------------------------------------------------------
	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL
	_poll_timer.one_shot = false
	add_child(_poll_timer)
	_poll_timer.timeout.connect(_on_poll_timeout)
	_poll_timer.start()

func _force_scan() -> void:
	_scan_at = Time.get_ticks_msec() / 1000.0
	_scan_busy = true
	_scan_shaders("res://")
	_scan_busy = false

func _exit_tree() -> void:
	if _poll_timer != null:
		_poll_timer.stop()
		_poll_timer.queue_free()
		_poll_timer = null

	if _logger != null:
		OS.remove_logger(_logger)
		_logger = null

func _truncate() -> void:
	var f := FileAccess.open(BRIDGE_LOG, FileAccess.WRITE)
	if f != null:
		f.close()


# ---------------------------------------------------------------------------
# 强制编译改动过的 shader
# ---------------------------------------------------------------------------

# filesystem_changed 很吵（任何文件变动都会触发），节流一下
const SCAN_THROTTLE := 0.5

# 定时轮询间隔（秒）。
#
# 这是从「保存」到「Nvim 里出现报错」的延迟上限，所以要短；但每一轮都要
# 遍历一遍项目目录，也不能太短。0.3s 对手感来说已经是即时的。
const POLL_INTERVAL := 0.3

func _on_poll_timeout() -> void:
	if _scan_busy:
		return

	# 这里**不能**因为「游戏正在跑」就跳过。
	#
	# 实测踩过：加上 is_playing_scene() 这道闸之后，只要你 F5 起的游戏还活着，
	# 轮询就一直是空的 —— 表现正是「故意改错 → 必须把焦点交给 Godot → 才报错」，
	# 因为只剩编辑器自己那个跟焦点绑定的 filesystem_changed 在干活。
	#
	# 而且本来也没必要跳过：_compile_if_changed 有 mtime 闸门，没变就直接返回；
	# 变了也只是把代码挂到一个**临时** ShaderMaterial 上逼引擎编译一次，
	# 不动你的任何资源（编辑器自己在你编辑 shader 时就是这么干的）。
	_scan_at = Time.get_ticks_msec() / 1000.0
	_scan_busy = true
	_scan_shaders("res://")
	_scan_busy = false

func _on_filesystem_changed() -> void:
	if _scan_busy:
		return

	var now := Time.get_ticks_msec() / 1000.0
	if now - _scan_at < SCAN_THROTTLE:
		return

	_scan_at = now
	_scan_busy = true
	_scan_shaders("res://")
	_scan_busy = false

func _scan_shaders(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return

	dir.list_dir_begin()

	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full := dir_path.path_join(entry)

			if dir.current_is_dir():
				# 跳过第三方 addon，它们的报错不是你的
				if entry != "addons":
					_scan_shaders(full)
			elif entry.ends_with(".gdshader"):
				_compile_if_changed(full)

		entry = dir.get_next()

	dir.list_dir_end()

func _compile_if_changed(path: String) -> void:
	var stamp := FileAccess.get_modified_time(path)
	if _shader_stamp.get(path) == stamp:
		return

	_shader_stamp[path] = stamp

	# 告诉 Logger「现在正在编译这个文件」。
	#
	# 为什么需要：Godot 编译失败时报的位置常常是引擎内部路径
	# （servers/...cpp），完全没有 res:// 信息，Nvim 那边就没法定位。
	# 但这次编译是我们自己发起的，所以确切知道目标是谁 —— 标上去。
	#
	# 连 mtime 一起标：这份报错属于**这一版**文件。Nvim 那边拿它跟当前
	# mtime 比对来判断过期；如果用报错「被打印出来那一刻」的 mtime，
	# 报错已经修好之后引擎补报的旧错会被当成新的（时间戳是新的）。
	# （Nvim 那边还会再对一次内容指纹 —— 同一份代码再保存一次只改 mtime，
	# 那种不算过期。）
	if _logger != null:
		_logger.aim(path, stamp)

	# CACHE_MODE_IGNORE：绕开缓存重新读盘，否则拿到的还是旧代码
	var res := ResourceLoader.load(path, "Shader", ResourceLoader.CACHE_MODE_IGNORE)

	# 先**真的**让 Godot 编译一次，优先用引擎自己的报错。
	#
	# 为什么不再自己判 shader_type：引擎给的文案和行号比我们猜的准 ——
	# Godot 的 shader 编辑器里显示的就是
	#   Error at line 1: Expected 'shader_type' at the beginning of shader.
	#                    Valid types are: 'spatial', 'canvas_item', ...
	# 而插件以前直接短路掉编译、甩一句自己编的话，两边对不上，看着就像在瞎报。
	if res is Shader:
		var mat := ShaderMaterial.new()
		mat.shader = res
		mat.shader = null
	else:
		# load 直接失败（连资源都不是 Shader）：引擎**不会**经由 Logger 报出来
		# （实测这种情况 stdout 和 Logger 都是空的）。自己造一条。
		if _logger != null:
			_logger.synthetic(path, "Shader 解析失败（Godot 没给出具体行号）")

	# 引擎一条都没报、但确实缺 shader_type -> 补一条兜底。
	#
	# 实测（headless + dummy 渲染器）：只要真的走到 `mat.shader = res`，引擎
	# 就会经由 Logger 报出
	#   Expected 'shader_type' at the beginning of shader. Valid types are: ...
	# 所以正常情况下这条兜底**不会**触发；留着是为了某些「光挂材质不触发
	# 解析」的渲染器/配置。文案照抄引擎的说法，免得两边字不一样。
	if _logger != null:
		if not _logger.reported_this_aim() and _has_shader_type(path) == false:
			_logger.synthetic(path, MSG_MISSING_SHADER_TYPE)

		_logger.disarm()

# Godot 的规则：第一行非空、非 // 注释的内容必须是 shader_type 声明。
func _has_shader_type(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return true

	var code := f.get_as_text()
	f.close()

	for raw in code.split("\n"):
		var line := raw.strip_edges()

		if line == "" or line.begins_with("//"):
			continue

		return line.begins_with("shader_type")

	return false


# ---------------------------------------------------------------------------
# Logger 实现
# ---------------------------------------------------------------------------

class NvimBridgeLogger:
	extends Logger

	# 防重入：写文件失败时 Godot 自己会再报一次错，不挡住就会无限递归
	var _busy := false

	# 当前正在被我们强制编译的 shader（res:// 路径）。
	# 这次编译产生的报错如果位置是引擎内部路径，就用它来定位。
	var target := ""

	# 目标文件在被编译那一刻的 mtime。
	#
	# 报错里的 mtime 必须是「这份代码的版本」，而不是「报错被打印出来的
	# 时刻」。引擎的 shader 编译是延迟的，报错可能在文件已经改好之后才
	# 到 —— 那时若用当前 mtime，Nvim 会把它当成新报错挂上去，看起来就是
	# 「改好了还在报，只有重启 Nvim 才消失」。
	var target_mtime := 0

	# 目标的保质期（秒，Time.get_ticks_msec 口径）。
	#
	# 不立刻清空目标：引擎级的报错可能在我们这次调用返回之后才由渲染
	# 线程补报，那时 target 若已经清掉就定位不到了。留一小段时间兜住。
	const TARGET_TTL := 0.8

	var _target_until := 0.0

	# 本次强制编译是否已经报过「具体」的错误。
	#
	# 引擎在具体错误（Unknown identifier ...）之后还会补一条通用的
	# shader_set_code / "Shader compilation failed."。两条都发过去，同一个
	# 位置就挂两条诊断，看起来像在乱报。后者没有额外信息，丢掉。
	var _aim_reported := false

	func aim(path: String, stamp: int) -> void:
		target = path
		target_mtime = stamp
		_target_until = Time.get_ticks_msec() / 1000.0 + TARGET_TTL
		_aim_reported = false

	func disarm() -> void:
		target = ""
		target_mtime = 0
		_target_until = 0.0
		_aim_reported = false

	func _target_alive() -> bool:
		return target != "" and Time.get_ticks_msec() / 1000.0 <= _target_until

	# 本次强制编译期间引擎有没有报过「具体的」错误。
	# 用来决定要不要补一条兜底报错（引擎沉默时才补）。
	func reported_this_aim() -> bool:
		return _aim_reported

	func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		editor_notify: bool,
		error_type: int,
		script_backtraces: Array
	) -> void:
		var aimed := _target_alive()

		# 同一个 shader 上，具体错误已经报过 -> 丢掉引擎补的通用错误
		if aimed and _aim_reported and function == "shader_set_code":
			return

		var mtime := 0

		# 引擎内部路径 + 有编译目标 -> 归到那个 shader 上
		if aimed:
			if not file.begins_with("res://"):
				file = target
				line = 0

			if file == target:
				mtime = target_mtime

		if aimed and function != "shader_set_code":
			_aim_reported = true

		_write({
			"kind": "error",
			"type": error_type,
			"file": file,
			"line": line,
			"func": function,
			"code": code,
			"rationale": rationale,
			"notify": editor_notify,
			"backtraces": _backtraces(script_backtraces),
			# 报错所属的源文件版本（mtime）。
			#
			# Nvim 那边拿它跟当前 mtime 精确比对：不相等就说明文件已经改过，
			# 这条报错属于旧版本，直接丢掉。两边都是 OS stat 出来的同一个
			# 值，所以没有时区/时钟偏差问题（用墙上时间戳比会踩这个坑）。
			"mtime": mtime if mtime != 0 else _file_mtime(file),
		})

	# 自己造一条报错（Godot 没报但确实有问题的情况）。
	func synthetic(path: String, message: String) -> void:
		var mtime := 0

		if _target_alive() and path == target:
			mtime = target_mtime

		# 这一条就是本次编译的结论了，后面的通用错误没有信息量
		_aim_reported = true

		_write({
			"kind": "error",
			"type": 3,
			"file": path,
			"line": 0,
			"func": "",
			"code": message,
			"rationale": "",
			"notify": false,
			"backtraces": [],
			"mtime": mtime if mtime != 0 else _file_mtime(path),
		})

	func _log_message(message: String, error: bool) -> void:
		# 只转发「错误类」消息。正常 print 也走这里，全转过去会把 Nvim 灌爆。
		if not error:
			return

		_write({
			"kind": "message",
			"error": true,
			"message": message,
		})

	# 源文件的 mtime（Unix 秒）。非 res:// 路径（引擎内部）返回 0。
	func _file_mtime(path: String) -> int:
		if not path.begins_with("res://"):
			return 0

		return FileAccess.get_modified_time(path)

	# GDScript 报错的 file/line 常常是引擎内部位置，真正的脚本位置在
	# script_backtraces 里。取出来让 Nvim 那边能定位到用户代码。
	func _backtraces(script_backtraces: Array) -> Array:
		var out := []

		for bt in script_backtraces:
			if bt == null:
				continue

			var frames := []
			var count: int = bt.get_frame_count()

			for i in count:
				frames.append({
					"func": bt.get_frame_function(i),
					"file": bt.get_frame_file(i),
					"line": bt.get_frame_line(i),
				})

			if not frames.is_empty():
				out.append(frames)

		return out

	func _write(payload: Dictionary) -> void:
		if _busy:
			return

		_busy = true

		# 事件时间戳。Nvim 那边拿它跟源文件 mtime 比：如果文件比事件还新，
		# 说明这条报错属于旧版本的文件，直接丢掉（否则重新 tail 旧日志时
		# 会把历史报错当成当前报错，看起来就是「乱报」）。
		payload["t"] = Time.get_unix_time_from_system()

		var f := FileAccess.open(BRIDGE_LOG, FileAccess.READ_WRITE)
		if f == null:
			f = FileAccess.open(BRIDGE_LOG, FileAccess.WRITE)

		if f != null:
			f.seek_end()
			f.store_line(JSON.stringify(payload))
			f.flush()
			f.close()

		_busy = false
