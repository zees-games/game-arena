extends RefCounted

## The flashlight's config and binder for this game (the beam, the battery and the sounds are dot-flashlight's).

const GAME_ID := "game-arena"
## The wire bit the client holds for a few ticks to ask the server for a switch.
const BUTTON := DotWeaponCommand.BUTTON_USER_1
## Seconds the bit is held (3 ticks at 66): long enough that one lost command does not lose the press.
const HOLD_SEC := 0.045

## [constant HOLD_SEC] in ticks at [param tick_rate].
static func hold_ticks(tick_rate: int) -> int:
	return maxi(1, ceili(HOLD_SEC * float(tick_rate) - 0.001))


## A config with this game's defaults: F switches it, and it starts off on the lit maps.
static func make_config() -> DotFlashlightConfig:
	var cfg := DotFlashlightConfig.new()
	cfg.key = "F"
	return cfg


## `arena_flashlight_<field>` cvars, `cfg/game/game-arena/flashlight/game.yml`, and a workbench set.
static func make_binder(cfg: DotFlashlightConfig) -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(cfg, GAME_ID, "arena_flashlight")
	b.profile_kind = "flashlight"
	return b


## Whether a player begins the map with the light on, from the map's id and its ambient.
static func starts_on(cfg: DotFlashlightConfig, map_id: String, ambient: float = 1.0) -> bool:
	return cfg.enabled and DotFlashlightRules.start_on(cfg, map_id, ambient)
