extends Node

const ArenaCoverWarm := preload("../game/arena_cover_warm.gd")

## The cover's sliced material warm-up (cl_cover_warm): materials of one shader signature are told
## apart from ones that need their own program, the first of each signature and every mesh come ahead
## of the repeats, a headless run never uses the setting, and the node holds a gate for as long as it
## runs and lets it go when it is done.
##
## [codeblock]
## godot --headless --path . res://examples/headless_coverwarm.tscn
## [/codeblock]

const EXPECTED_CHECKS := 12

var _checks := 0
var _failed := 0


class _StubGate extends RefCounted:
	var holds := 0
	var releases := 0
	var reason: StringName = &""
	var node: Node = null
	var seen := {}

	func hold(why: StringName, _text: String = "") -> void:
		holds += 1
		reason = why

	func release(why: StringName) -> void:
		if why == reason:
			releases += 1
			seen = node.get(&"stats")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		print("FAIL ", what)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var plain := StandardMaterial3D.new()
	var plain2 := StandardMaterial3D.new()
	plain2.albedo_color = Color.RED
	var alpha := StandardMaterial3D.new()
	alpha.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var normal := StandardMaterial3D.new()
	normal.normal_enabled = true
	var mesh := QuadMesh.new()
	_check(ArenaCoverWarm.signature_of(plain) == ArenaCoverWarm.signature_of(plain2), "a colour alone is not another program")
	_check(ArenaCoverWarm.signature_of(plain) != ArenaCoverWarm.signature_of(alpha), "alpha blending is another program")
	_check(ArenaCoverWarm.signature_of(plain) != ArenaCoverWarm.signature_of(normal), "a normal map is another program")

	var order := ArenaCoverWarm.ordered([plain, plain2, mesh, alpha, normal])
	_check(order.size() == 5, "nothing is dropped")
	_check(order.slice(0, 4) == [plain, mesh, alpha, normal], "the first of each signature and the mesh lead")
	_check(order[4] == plain2, "the repeat of a signature comes last")

	_check(not ArenaCoverWarm.enabled(), "a headless run never slices (it draws nothing)")
	_check(ArenaCoverWarm.batch_setting() == ArenaCoverWarm.DEFAULT_BATCH, "the batch has a default")

	var camera := Camera3D.new()
	add_child(camera)
	var gate := _StubGate.new()
	var node := ArenaCoverWarm.new()
	gate.node = node
	add_child(node)
	node.run(gate, camera, [])
	_check(gate.holds == 1 and gate.reason == ArenaCoverWarm.HOLD, "it holds the gate under its own reason")
	for i in 30:
		if gate.releases > 0:
			break
		await get_tree().process_frame
	_check(gate.releases == 1, "it lets the gate go when it is done")
	_check(gate.seen.get("items", -1) == 0, "it counts what it drew")
	await get_tree().process_frame
	_check(not is_instance_valid(node) or node.is_queued_for_deletion(), "and frees itself")

	print("headless_coverwarm: %d checks, %d failed" % [_checks, _failed])
	if _checks != EXPECTED_CHECKS:
		print("FAIL expected %d checks, ran %d" % [EXPECTED_CHECKS, _checks])
		_failed += 1
	get_tree().quit(1 if _failed > 0 else 0)
