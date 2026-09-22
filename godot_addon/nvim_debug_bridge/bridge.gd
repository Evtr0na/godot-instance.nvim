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

var _logger: Logger = null

func _enter_tree() -> void:
	# 新一轮编辑器会话：清掉上一轮的日志，让 Nvim 那边从零开始读
	_truncate()

	_logger = NvimBridgeLogger.new()
	OS.add_logger(_logger)

func _exit_tree() -> void:
	if _logger != null:
		OS.remove_logger(_logger)
		_logger = null

func _truncate() -> void:
	var f := FileAccess.open(BRIDGE_LOG, FileAccess.WRITE)
	if f != null:
		f.close()


# ---------------------------------------------------------------------------
# Logger 实现
# ---------------------------------------------------------------------------

class NvimBridgeLogger:
	extends Logger

	# 防重入：写文件失败时 Godot 自己会再报一次错，不挡住就会无限递归
	var _busy := false

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

		var f := FileAccess.open(BRIDGE_LOG, FileAccess.READ_WRITE)
		if f == null:
			f = FileAccess.open(BRIDGE_LOG, FileAccess.WRITE)

		if f != null:
			f.seek_end()
			f.store_line(JSON.stringify(payload))
			f.flush()
			f.close()

		_busy = false
