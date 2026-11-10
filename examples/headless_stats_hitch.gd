extends Node

## The timed stats flush writes the stats file once, not once per player. This flushes 24 players
## through `ArenaStatsStore` and the addon's store, and asserts one write, the same file, and
## nothing lost; the achievement autosave gets the same checks.

const ArenaAwards := preload("../game/arena_awards.gd")
const ArenaAwardStore := preload("../game/arena_award_store.gd")
const ArenaStats := preload("../game/arena_stats.gd")
const ArenaStatsStore := preload("../game/arena_stats_store.gd")

const PLAYERS := 24
## Rows already in the file: a profile that has met a few hundred names.
const OLD_ROWS := 300
const BATCHED := "user://headless_stats_hitch_batched.json"
const PLAIN := "user://headless_stats_hitch_plain.json"
const AWARDS_BATCHED := "user://headless_stats_hitch_awards_batched"
const AWARDS_PLAIN := "user://headless_stats_hitch_awards_plain"

var _checks := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _seed(path: String) -> void:
	var rows := {}
	for i in OLD_ROWS:
		rows["old%d" % i] = {"name": "Old %d" % i, "values": {String(ArenaStats.KILLS): float(i), String(ArenaStats.DEATHS): float(i * 2)}, "cells": {}}
	var written := DotPaths.write_json(path, rows, true, true)
	_check(written.ok, "the seed file was written", path)


func _tracker(store: DotStatsStoreFile) -> DotStatsTracker:
	var stats := DotStatsTracker.new()
	stats.schema = ArenaStats.schema()
	stats.report_interval = 0.0
	stats.store = store
	add_child(stats)
	var started := stats.start()
	_check(started.ok, "the tracker started")
	for i in PLAYERS:
		stats.begin(StringName("p%d" % i), "Player %d" % i)
	return stats


func _play(stats: DotStatsTracker, round: int) -> void:
	for i in PLAYERS:
		var id := StringName("p%d" % i)
		stats.record(id, ArenaStats.KILLS, float(1 + (i + round) % 3))
		stats.record(id, ArenaStats.DEATHS, 1.0)
		stats.record(id, ArenaStats.SHOTS_FIRED, float(10 + i))


func _read(path: String) -> Dictionary:
	var read := DotPaths.read_json(path)
	if not read.ok or not (read.value is Dictionary):
		return {}
	return read.value as Dictionary


func _award_tracker(store: DotAchievementStoreFile) -> DotAchievementTracker:
	var tracker := DotAchievementTracker.new()
	tracker.catalogue = ArenaAwards.catalogue()
	tracker.autosave_interval = 0.0
	# An unlock saves at once; off here so that a flush is the only thing that saves.
	tracker.save_on_unlock = false
	tracker.register_as = &""
	tracker.store = store
	add_child(tracker)
	_check(tracker.start().ok, "the achievement tracker started")
	return tracker


func _same_files(store_a: DotAchievementStoreFile, store_b: DotAchievementStoreFile) -> int:
	var same := 0
	for i in PLAYERS:
		var a := _read(store_a.path_for("p%d" % i))
		if not a.is_empty() and DotValue.same_dictionary(a, _read(store_b.path_for("p%d" % i))):
			same += 1
	return same


func _awards() -> void:
	var store: DotAchievementStoreFile = ArenaAwardStore.new(AWARDS_BATCHED)
	var plain_store := DotAchievementStoreFile.new(AWARDS_PLAIN)
	var batched := _award_tracker(store)
	var plain := _award_tracker(plain_store)
	for i in PLAYERS:
		await batched.begin("p%d" % i)
		await plain.begin("p%d" % i)
	var worst_batched := 0.0
	var worst_plain := 0.0
	for round in 3:
		for i in PLAYERS:
			batched.record("p%d" % i, ArenaStats.KILLS, float(1 + i + round))
			plain.record("p%d" % i, ArenaStats.KILLS, float(1 + i + round))
		var before: int = store.get(&"writes")
		var t0 := Time.get_ticks_usec()
		var saved: DotResult = await batched.flush()
		worst_batched = maxf(worst_batched, (Time.get_ticks_usec() - t0) / 1000.0)
		_check(saved.ok and int(saved.value) == PLAYERS, "awards round %d: the autosave saved every dirty player" % round, str(saved.value) if saved.ok else "failed")
		_check(int(store.get(&"writes")) == before, "awards round %d: the autosave's own frame wrote no file" % round)
		t0 = Time.get_ticks_usec()
		await plain.flush()
		worst_plain = maxf(worst_plain, (Time.get_ticks_usec() - t0) / 1000.0)
		if round == 0:
			# A player back before the write has landed gets what was saved, not the old file.
			var early: DotResult = await store.load_progress("p3")
			var want := plain.progress_of("p3")
			_check(early.ok and DotValue.same_dictionary((early.value as DotAchievementProgress).to_dictionary(), want.to_dictionary()),
				"a load before the write lands returns the saved progress")
		var waited := 0
		while int(store.get(&"writes")) - before < PLAYERS and waited < 600:
			await get_tree().process_frame
			waited += 1
		await _frames(6)
		_check(int(store.get(&"writes")) - before == PLAYERS, "awards round %d: every player's file went out once" % round, str(int(store.get(&"writes")) - before))
		_check(_same_files(store, plain_store) == PLAYERS, "awards round %d: and they are the files the addon's store writes" % round, str(_same_files(store, plain_store)))

	for i in PLAYERS:
		batched.record("p%d" % i, ArenaStats.DEATHS, 2.0)
		plain.record("p%d" % i, ArenaStats.DEATHS, 2.0)
	await batched.flush()
	await plain.flush()
	store.call(&"finish")
	_check(_same_files(store, plain_store) == PLAYERS, "awards: finish() writes the last autosave without waiting for a frame", str(_same_files(store, plain_store)))
	print("  worst autosave frame: %.2f ms batched, %.2f ms per-player writes (%d players)" % [worst_batched, worst_plain, PLAYERS])
	_check(worst_batched < worst_plain, "the batched autosave frame is cheaper than per-player writes", "%.2f vs %.2f ms" % [worst_batched, worst_plain])
	batched.free()
	plain.free()
	for i in PLAYERS:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(store.path_for("p%d" % i)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(plain_store.path_for("p%d" % i)))
	for dir in [AWARDS_BATCHED, AWARDS_PLAIN]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(str(dir)))


func _run() -> void:
	_seed(BATCHED)
	_seed(PLAIN)
	var store: DotStatsStoreFile = ArenaStatsStore.new(BATCHED)
	var batched := _tracker(store)
	var plain := _tracker(DotStatsStoreFile.new(PLAIN))
	await _frames(2)

	var worst_batched := 0.0
	var worst_plain := 0.0
	for round in 3:
		_play(batched, round)
		_play(plain, round)
		var before: int = store.get(&"writes")
		var t0 := Time.get_ticks_usec()
		var flushed: DotResult = await batched.flush()
		worst_batched = maxf(worst_batched, (Time.get_ticks_usec() - t0) / 1000.0)
		_check(flushed.ok, "round %d: the flush succeeded" % round)
		_check(batched.store_pending() == 0, "round %d: every player's delta was merged" % round, str(batched.store_pending()))
		_check(int(store.get(&"writes")) == before, "round %d: the flush's own frame wrote no file" % round)
		t0 = Time.get_ticks_usec()
		await plain.flush()
		worst_plain = maxf(worst_plain, (Time.get_ticks_usec() - t0) / 1000.0)
		var waited := 0
		while int(store.get(&"writes")) == before and waited < 600:
			await get_tree().process_frame
			waited += 1
		await _frames(6)
		var wrote: int = int(store.get(&"writes")) - before
		_check(wrote == 1, "round %d: %d players' flush wrote the file once" % [round, PLAYERS], "%d writes" % wrote)
		var a := _read(BATCHED)
		var b := _read(PLAIN)
		_check(a.size() == OLD_ROWS + PLAYERS, "round %d: the file holds every row" % round, str(a.size()))
		_check(DotValue.same_dictionary(a, b), "round %d: and is the file the addon's store writes" % round)

	# Shutdown: a flush with no frame after it. `ArenaProgress._exit_tree` calls finish() for this.
	_play(batched, 3)
	_play(plain, 3)
	await batched.flush()
	await plain.flush()
	store.call(&"finish")
	_check(DotValue.same_dictionary(_read(BATCHED), _read(PLAIN)), "finish() writes the last flush without waiting for a frame")

	# And the real order at quit: the tracker leaves the tree with a delta unflushed and merges it there, then its owner calls finish().
	_play(batched, 4)
	_play(plain, 4)
	remove_child(batched)
	remove_child(plain)
	store.call(&"finish")
	_check(DotValue.same_dictionary(_read(BATCHED), _read(PLAIN)), "a tracker leaving the tree mid-interval loses nothing")

	var again := DotStatsStoreFile.new(BATCHED)
	again.schema = ArenaStats.schema()
	var kept: DotResult = await again.values_for(&"p0")
	_check(kept.ok and (kept.value as DotStatsValues).get_value(ArenaStats.DEATHS) == 5.0, "the written file reads back a player's totals",
		str((kept.value as DotStatsValues).get_value(ArenaStats.DEATHS)) if kept.ok else "unreadable")

	print("  worst flush frame: %.2f ms batched, %.2f ms per-player writes (%d players, %d rows)" % [worst_batched, worst_plain, PLAYERS, OLD_ROWS + PLAYERS])
	_check(worst_batched < worst_plain, "the batched flush frame is cheaper than per-player writes", "%.2f vs %.2f ms" % [worst_batched, worst_plain])
	batched.free()
	plain.free()
	await _frames(2)
	for path in [BATCHED, PLAIN]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(str(path)))
	await _awards()
	print("headless_stats_hitch: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
