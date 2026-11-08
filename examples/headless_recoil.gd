extends Node

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaRecoilView := preload("../game/arena_recoil_view.gd")

## Per-weapon recoil: the game tier of the Dot profile gives every firearm a kick, the camera climbs with a
## held trigger and settles after it, the same shots kick the same way on a second run (what the server and
## a predicting client both compute), and cl_recoil_view only scales the drawn view.
##
## [codeblock]
## godot --headless --path . res://examples/headless_recoil.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_SECTIONS := 4
const EXPECTED_CHECKS := 26

## Weapons that must kick at all (everything with a barrel), and those that must not.
const KICKERS: PackedStringArray = [
	"rifle", "carbine", "bullpup", "smg", "machine_pistol", "lmg", "minigun", "pistol", "battle_rifle",
	"burst_rifle", "marksman", "revolver", "derringer", "shotgun", "drum_shotgun", "sniper", "charge_rifle",
	"launcher", "quad_launcher", "grenade_launcher",
]
const STILL: PackedStringArray = ["knife", "beamer", "frag", "sticky", "flash", "smoke", "incendiary"]

var _checks := 0
var _failed := 0
var _entered := 0
var _finished := 0
var _tick := 1
var _feel: DotGameCombatFeel = null


func _ready() -> void:
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _run() -> void:
	_feel = DotGameCombatFeel.new(true, true)
	_test_profiles()
	_test_view()
	await _test_burst()
	_test_cvar()
	print("")
	print("%d sections entered, %d finished" % [_entered, _finished])
	var ok := _failed == 0 and _entered == EXPECTED_SECTIONS and _finished == EXPECTED_SECTIONS and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _pitch(def: DotWeaponDef) -> float:
	var b := def.tuning as DotWeaponBallistics
	return b.recoil_pitch if b != null else 0.0


func _test_profiles() -> void:
	_entered += 1
	print("== the game tier gives every weapon its kick")
	var defs := ArenaContent.weapons()
	var by_id := {}
	for d in defs:
		by_id[String(d.id)] = d
	var missing := PackedStringArray()
	var silent := PackedStringArray()
	for id in KICKERS:
		if not by_id.has(id):
			missing.append(id)
		elif _pitch(by_id[id]) <= 0.0:
			silent.append(id)
	_check(missing.is_empty(), "every firearm is in the catalogue", ",".join(missing))
	_check(silent.is_empty(), "and every one kicks", ",".join(silent))
	var loud := PackedStringArray()
	for id in STILL:
		if by_id.has(id) and _pitch(by_id[id]) > 0.0:
			loud.append(id)
	_check(loud.is_empty(), "melee, beams and grenades do not kick", ",".join(loud))
	_check(is_equal_approx(_pitch(by_id["rifle"]), 0.70), "the arena's rifle profile (cfg/game/game-arena) is applied", str(_pitch(by_id["rifle"])))
	_check(_pitch(by_id["rifle"]) > 0.36, "and kicks harder than the pack default")
	_check(_pitch(by_id["sniper"]) > _pitch(by_id["rifle"]) * 3.0, "a sniper kicks far harder than a rifle")
	_check(_pitch(by_id["smg"]) < _pitch(by_id["rifle"]), "an smg kicks less per shot than a rifle")
	var rifle: DotWeaponBallistics = by_id["rifle"].tuning as DotWeaponBallistics
	_check(rifle.recoil_recovery > 0.0 and rifle.recoil_recovery < 6.0, "recovery is slower than the pack default, so a burst climbs", str(rifle.recoil_recovery))
	_check(AwWeaponPack.errors.is_empty(), "no profile failed to load", ",".join(AwWeaponPack.errors))
	_finished += 1


func _outcome(pitch: float, yaw: float) -> DotWeaponOutcome:
	var o := DotWeaponOutcome.new()
	o.recoil = Vector2(pitch, yaw)
	o.recoil_signed = true
	o.recoil_recovery = 3.0
	return o


func _test_view() -> void:
	_entered += 1
	print("== the camera climbs with a burst and settles")
	ArenaRecoilView.scale = 1.0
	var v := ArenaRecoilView.new()
	_check(v.step(0.016) == Vector2.ZERO, "a fresh view is still")
	for _i in 10:
		v.kick(_outcome(0.7, 0.1))
		v.step(1.0 / 10.0)
	var up := v.offset().x
	_check(up > 1.5, "ten shots climb the view", "%.2f" % up)
	for _i in 120:
		v.step(1.0 / 60.0)
	_check(v.offset().length() < 0.01, "and it settles after two seconds", str(v.offset()))
	var a := ArenaRecoilView.new()
	var b := ArenaRecoilView.new()
	a.kick(_outcome(2.0, 0.0))
	b.kick(_outcome(2.0, 0.0))
	a.step(0.5)
	for _i in 5:
		b.step(0.1)
	_check(is_equal_approx(a.offset().x, b.offset().x), "settling is frame-rate independent", "%.4f vs %.4f" % [a.offset().x, b.offset().x])
	a.kick(null)
	a.kick(DotWeaponOutcome.new())
	_check(is_equal_approx(a.offset().x, b.offset().x), "a null or kickless outcome leaves it alone")
	var big := ArenaRecoilView.new()
	for _i in 100:
		big.kick(_outcome(5.0, 0.0))
	_check(big.offset().x <= big.max_pitch + 0.001, "the climb is capped", str(big.offset().x))
	big.step(0.016, false)
	_check(big.offset() == Vector2.ZERO, "dying drops the kick")
	_finished += 1


func _player(id: int) -> ArenaPlayer:
	var p := ArenaPlayer.new()
	p.name = "P%d" % id
	p.setup(ArenaPlayer.Mode.HEADLESS, ArenaMap.dm_box(), id, "P%d" % id)
	add_child(p)
	p.spawn(Transform3D(Basis(), Vector3(-16.0, 0.05, 6.0)), 0)
	p.give_default_loadout()
	_feel.attach(p.arsenal)
	return p


func _fire(p: ArenaPlayer, ticks: int) -> Array:
	var kicks: Array = []
	for _i in ticks:
		var w := DotWeaponCommand.new()
		w.buttons = DotWeaponCommand.BUTTON_ATTACK
		var c := DotFpsCommand.new()
		c.yaw = -90.0
		var out := p.simulate_tick(_tick, 1.0 / float(TICK_RATE), c, w)
		_tick += 1
		if out != null and out.recoil != Vector2.ZERO:
			kicks.append(out.recoil)
		await get_tree().physics_frame
	return kicks


func _test_burst() -> void:
	_entered += 1
	print("== a real weapon's burst, predicted twice")
	ArenaRecoilView.scale = 1.0
	var p1 := _player(21)
	var p2 := _player(22)
	await get_tree().physics_frame
	for _i in 40:
		p1.simulate_tick(_tick, 1.0 / float(TICK_RATE), DotFpsCommand.new(), DotWeaponCommand.new())
		p2.simulate_tick(_tick, 1.0 / float(TICK_RATE), DotFpsCommand.new(), DotWeaponCommand.new())
		_tick += 1
		await get_tree().physics_frame
	var a: Array = await _fire(p1, 90)
	var b: Array = await _fire(p2, 90)
	_check(a.size() >= 8, "a held trigger kicks every shot", str(a.size()))
	_check(a.size() == b.size() and a.hash() == b.hash(), "two simulations of the same shots kick identically (no desync)")
	var view := ArenaRecoilView.new()
	for k in a:
		var o := _outcome((k as Vector2).x, (k as Vector2).y)
		view.kick(o)
	_check(view.offset().x > 1.0, "the view the burst would draw climbs (undecayed)", "%.2f" % view.offset().x)
	_check(p1.recoil_view.offset() == Vector2.ZERO, "a player with no camera (server, remote) draws no kick of its own")
	var camera := Camera3D.new()
	p1.camera = camera
	p1.add_child(camera)
	var shot := _outcome(1.0, 0.0)
	p1._on_used(shot)
	_check(p1.recoil_view.offset().x > 0.9, "the local player's shot kicks its view")
	p1.recoil_view.clear()
	p1.queue_free()
	p2.queue_free()
	_finished += 1


func _test_cvar() -> void:
	_entered += 1
	print("== cl_recoil_view scales or disables the drawn kick")
	var v := ArenaRecoilView.new()
	v.kick(_outcome(2.0, 0.0))
	ArenaRecoilView.scale = 0.0
	_check(v.step(0.0) == Vector2.ZERO, "0 keeps the crosshair still")
	ArenaRecoilView.scale = 0.5
	var half := v.step(0.0).x
	ArenaRecoilView.scale = 1.0
	var full := v.step(0.0).x
	_check(is_equal_approx(half * 2.0, full) and full > 1.9 * (1.0 - ArenaRecoilView.POSE_SHARE), "0.5 halves it", "%.2f %.2f" % [half, full])
	ArenaRecoilView.scale = 99.0
	_check(v.step(0.0).x <= full * 5.01, "and it is capped at 5")
	_check(is_equal_approx(v.offset().x * (1.0 - ArenaRecoilView.POSE_SHARE), full), "the underlying kick (what the bullet follows) is not scaled")
	ArenaRecoilView.scale = 1.0
	var rules := DotWeaponRecoilRules.new()
	_check(rules.get_script().resource_path.ends_with("dot_weapon_recoil_rules.gd") and _feel.recoil != null and _feel.recoil.enabled, "the server's sv_recoil_* rules are on for the arena")
	_finished += 1
