class_name ArenaMatchText
extends RefCounted
## Wording for the end-of-match reveal and summary.


## Reveal rows for the top three of a ranked scoreboard.
static func reveal_entries(ranked: Array) -> Array:
	var entries: Array = []
	for row: DotPlayerScore in ranked.slice(0, 3):
		entries.append({"name": row.display_name, "score": "%d %s  %d %s" % [
			row.kills, "kill" if row.kills == 1 else "kills", row.deaths, "death" if row.deaths == 1 else "deaths"]})
	return entries


static func mvp_notice(best: DotPlayerScore) -> String:
	return "MVP: %s  -  %d kills, %d deaths, %d assists" % [best.display_name, best.kills, best.deaths, best.assists]
