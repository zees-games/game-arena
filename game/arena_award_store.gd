extends DotAchievementStoreFile

## Achievement progress files, written behind the frame that saved them. The tracker's autosave saves every dirty player in one frame and [DotAchievementStoreFile] writes a file for each as asked:
## 24 atomic writes on the main thread every autosave interval (the owner's 55 ms spike).
## Here a save keeps the snapshot and returns; a worker writes the batch, or one file a frame goes out where there are no threads.

const LOG := "arena.award_store"

## How many files have been written; the suite counts it.
var writes: int = 0

# player -> the dictionary to write. A newer save replaces an older one that has not gone out.
var _pending: Dictionary = {}
# Saves whose write failed: they go out again with the next save, not every frame.
var _refused: Dictionary = {}
var _ticking: bool = false
var _task: int = -1
# One entry per finished batch, appended by the worker and read on the main thread only after the task has completed.
var _done: Array = []


func _save_progress(player: String, progress: DotAchievementProgress) -> DotResult:
	for held in _refused:
		if not _pending.has(held):
			_pending[held] = _refused[held]
	_refused.clear()
	_pending[player] = progress.to_dictionary()
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		finish()
	elif not _ticking:
		_ticking = true
		tree.process_frame.connect(_tick)
	return DotResult.success(1)


func _load_progress(player: String) -> DotResult:
	if _pending.has(player):
		return DotAchievementProgress.from_dictionary((_pending[player] as Dictionary).duplicate(true))
	# A write in flight may be this player's: the file is only the truth once it has landed.
	_collect(true)
	if _refused.has(player):
		return DotAchievementProgress.from_dictionary((_refused[player] as Dictionary).duplicate(true))
	return super._load_progress(player)


## Writes whatever is still unwritten, now, and waits for a batch in flight. For shutdown: no frame may follow.
func finish() -> void:
	_collect(true)
	# The last chance for a save that was refused: it goes out again with the rest.
	for held in _refused:
		if not _pending.has(held):
			_pending[held] = _refused[held]
	_refused.clear()
	if not _pending.is_empty():
		_write(_take(_pending.size()), atomic, _done)
		_collect(true)
	_stop_ticking()


func _stop_ticking() -> void:
	if not _ticking:
		return
	_ticking = false
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.process_frame.is_connected(_tick):
		tree.process_frame.disconnect(_tick)


func _tick() -> void:
	if not _collect(false):
		return
	if _pending.is_empty():
		_stop_ticking()
		return
	if DotPlatform.has_threads():
		_task = WorkerThreadPool.add_task(_write.bind(_take(_pending.size()), atomic, _done), false, "arena award files")
	else:
		_write(_take(1), atomic, _done)
		_collect(true)


## Moves up to [param count] saves out of the queue as [player, path, data] rows, plain data the worker owns from here.
func _take(count: int) -> Array:
	var batch: Array = []
	for player in _pending.keys():
		if batch.size() >= count:
			break
		batch.append([player, path_for(str(player)), _pending[player]])
		_pending.erase(player)
	return batch


## False while a batch is still being written. [param wait] blocks until it is done.
func _collect(wait: bool) -> bool:
	if _task != -1:
		if not wait and not WorkerThreadPool.is_task_completed(_task):
			return false
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _done.is_empty():
		return true
	var wrote := 0
	for entry in _done:
		var report: Dictionary = entry
		wrote += int(report["wrote"])
		var failed: Array = report["failed"]
		for row in failed:
			# A newer save for the same player already carries everything this one did.
			if not _pending.has(row[0]):
				_refused[row[0]] = row[2]
		if not failed.is_empty():
			DotLog.warn(LOG, "achievement progress is not saving; it will be retried", {"players": failed.size(), "why": str(report["why"])})
	_done.clear()
	writes += wrote
	if wrote > 0:
		DotWeb.sync_filesystem()
	return true


static func _write(batch: Array, atomically: bool, done: Array) -> void:
	var report := {"wrote": 0, "failed": [], "why": ""}
	for row in batch:
		var written := DotPaths.write_json(str(row[1]), row[2], true, atomically)
		if written.ok:
			report["wrote"] = int(report["wrote"]) + 1
		else:
			(report["failed"] as Array).append(row)
			report["why"] = written.error.message
	done.append(report)
