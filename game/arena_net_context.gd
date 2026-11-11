extends RefCounted

## What a profile or a bench needs to say about where the simulation ran: whether solo play was hosted in a
## second process (ArenaSimHost), the machine's threads, the server's own last per-second line (ticks/s,
## sim and send ms/tick, read from its log), and this client's clock and prediction (round trip, input lead,
## snaps, how many input-lead reports came back late, the server pace the clock follows, reconciles and the
## ticks they replayed). Read at a recording's start and end, never per frame.

const ArenaSimHost := preload("arena_sim_host.gd")

const SERVER_LINE := "SIM_HOST "


## [param bridge] is the client's net bridge (its `net` is the DotNetManager), or anything else when there is none.
static func describe(bridge: Object) -> Dictionary:
	var host: Variant = ArenaSimHost.live
	var hosted := host is Object and is_instance_valid(host) and bool((host as Object).get(&"up"))
	var out := {"sim_host": hosted, "threads": OS.get_processor_count()}
	if hosted:
		var line := last_server_line()
		if line != "":
			out["server"] = line
	var net: Variant = bridge.get(&"net") if bridge != null else null
	if not net is Object or bool((net as Object).get(&"is_server")):
		return out
	var clock: Variant = (net as Object).get(&"clock")
	if clock is Object:
		var c: Dictionary = (clock as Object).call(&"describe")
		out["rtt_ms"] = c.get("rtt_ms", 0)
		out["lead_ticks"] = int(c.get("tick", 0)) - int(c.get("server_tick", 0))
		out["target_lead"] = c.get("lead", 0)
		for key: String in ["snaps", "lead_reports", "late_reports", "server_pace"]:
			if c.has(key):
				out[key] = c[key]
	if (net as Object).has_method(&"perf_counters"):
		var p: Dictionary = (net as Object).call(&"perf_counters")
		out["reconciles"] = p.get(&"reconciles", 0)
		out["skipped"] = p.get(&"skipped", 0)
		out["replayed_ticks"] = p.get(&"replayed_ticks", 0)
	var predictor: Variant = (net as Object).get(&"predictor")
	if predictor is Object:
		out["mismatches"] = ((predictor as Object).call(&"describe") as Dictionary).get("mismatches", {})
	return out


## The newest per-second line the hosted server wrote to its log ("" without one).
static func last_server_line() -> String:
	var text := FileAccess.get_file_as_string(ArenaSimHost.SERVER_LOG)
	var cut := text.rfind("\n" + SERVER_LINE)
	if cut < 0:
		return ""
	var end := text.find("\n", cut + 1)
	return text.substr(cut + 1, (end if end > 0 else text.length()) - cut - 1).strip_edges()
