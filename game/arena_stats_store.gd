extends DotStatsStoreFile

## The stats file, written once per flush and off the main thread. [DotStatsStoreFile] rewrites the whole file after every player's merge, and the tracker's timed flush merges every player in one frame:
## with 24 players that was 24 full serialisations and atomic writes in one frame (the owner's 130 ms spike). Here a merge only marks the file dirty; the next frame takes one snapshot and a worker serialises and writes it.

const CHANNEL := "arena.stats_store"

## How many times the file has been written; the suite counts it.
var writes: int = 0

var _dirty: bool = false
var _ticking: bool = false
var _task: int = -1
# Written by the worker, read on the main thread only after the task has completed.
var _written: Array = []


func _save() -> void:
	_dirty = true
	if _ticking:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		finish()
		return
	_ticking = true
	tree.process_frame.connect(_tick)


## Writes whatever is still unwritten, now, and waits for a write in flight. For shutdown: no frame may follow.
## The owner must call it: a RefCounted cannot call its own methods while it is being freed, so nothing here can do it as a last resort.
func finish() -> void:
	_collect(true)
	if _dirty:
		_dirty = false
		_write(_snapshot(), path, _written)
		_collect(true)
	_stop_ticking()


func _tick() -> void:
	if not _collect(false):
		return
	if not _dirty:
		_stop_ticking()
		return
	_dirty = false
	var rows := _snapshot()
	if DotPlatform.has_threads():
		_task = WorkerThreadPool.add_task(_write.bind(rows, path, _written), false, "arena stats file")
	else:
		_write(rows, path, _written)
		_collect(true)


func _stop_ticking() -> void:
	if not _ticking:
		return
	_ticking = false
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.process_frame.is_connected(_tick):
		tree.process_frame.disconnect(_tick)


## Plain data only, so the worker shares nothing with the rows the next merge changes. The same shape the base class writes.
func _snapshot() -> Dictionary:
	var out := {}
	for id in _rows:
		var row: Dictionary = _rows[id]
		var values: DotStatsValues = row["values"]
		out[String(id)] = {"name": row["name"], "values": values.to_dictionary(), "cells": values.cells.duplicate()}
	return out


## False while a write is still running. [param wait] blocks until it is done.
func _collect(wait: bool) -> bool:
	if _task != -1:
		if not wait and not WorkerThreadPool.is_task_completed(_task):
			return false
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _written.is_empty():
		return true
	var written: DotResult = _written.pop_back()
	_written.clear()
	writes += 1
	if not written.ok:
		# The figures stay in memory and the next merge retries, as in the base class.
		DotLog.warn(CHANNEL, "could not write the stats file", {"path": path, "why": written.error.message})
		return true
	DotWeb.sync_filesystem()
	return true


static func _write(rows: Dictionary, to: String, result: Array) -> void:
	result.append(DotPaths.write_json(to, rows, true, true))
