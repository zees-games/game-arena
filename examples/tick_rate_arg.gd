extends RefCounted

## The tick rate a suite runs at: `-- --tick-rate=33` on the command line, else ARENA_TICK_RATE, else [param fallback].
## Clamped to the range the arena is tuned for (15..128). No class_name, for pack delivery.
static func rate(fallback: int = 64) -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tick-rate="):
			return clampi(int(arg.trim_prefix("--tick-rate=")), 15, 128)
	if OS.has_environment("ARENA_TICK_RATE"):
		return clampi(int(OS.get_environment("ARENA_TICK_RATE")), 15, 128)
	return fallback


## The snapshot rate a suite uses at [param tick]: the exact divisor of it nearest 16 (4 ticks apart at 64).
## ARENA_SNAPSHOT_RATE overrides. A rate that does not divide the tick rate is not a thing the arena sends.
static func snapshot(tick: int) -> int:
	if OS.has_environment("ARENA_SNAPSHOT_RATE"):
		return clampi(int(OS.get_environment("ARENA_SNAPSHOT_RATE")), 1, tick)
	var best := tick
	for every in range(2, tick + 1):
		if tick % every == 0 and absi(tick / every - 16) < absi(best - 16):
			best = tick / every
	return best
