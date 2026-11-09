extends Node3D
## Thrown knives: the aim key with the knife in hand throws it. The server flies each one on the tick,
## kills the first enemy it meets outright and leaves it in the body, bounces it off the world, and gives
## it back to whoever walks over it. A client mirrors the server's events and draws them.

## Server: a knife was thrown, bounced, came to rest, stuck or was taken (GONE, [param victim] the taker).
signal changed(id: int, owner: int, phase: int, victim: int, at: Vector3, motion: Vector3)

enum Phase { FLY, REST, STUCK, GONE }

const KNIFE := &"knife"
## Gravity on the throw until its first contact, then the players' own; flat enough to land where aimed.
const THROW_GRAVITY := 8.0
const GRAVITY := 22.0
## Speed kept off a bounce into the surface and along it: steel comes off hard surfaces dead.
const RESTITUTION := 0.3
const SURFACE_KEEP := 0.55
const REST_SPEED := 1.5
## Past this many bounces it settles on the next floor it touches, and past three times it stops anywhere.
const MAX_BOUNCES := 10
## One still flying this long (out of the world) goes back to its owner.
const FLIGHT_SECONDS := 10.0
const THROWER_GRACE_TICKS := 8
## More than this and the oldest goes back to its owner; so does one left lying this long.
const MAX_KNIVES := 32
const LIFETIME_SECONDS := 90.0
## How deep the tip sits in a body, and how far a client looks for the body's ragdoll part.
const EMBED := 0.07
const PART_REACH := 1.2
const SEEK_SECONDS := 0.6
const SPIN := 22.0


class Knife extends RefCounted:
	var id: int = 0
	var owner: int = 0
	var phase: int = Phase.FLY
	var victim: int = 0
	var at: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	## Which way the blade points: along the flight, into the body, or along the floor.
	var facing: Vector3 = Vector3.FORWARD
	var age: int = 0
	var bounces: int = 0
	var holder: Node3D = null
	var part: Node3D = null
	var part_local: Transform3D = Transform3D.IDENTITY
	var seek: float = 0.0
	var spun: float = 0.0
	var bled: bool = false


## `arena_knife_throw` (enabled), `arena_knife_throw_speed` (m/s) and `arena_knife_throw_pickup` (m, 0 off).
var rules: Dictionary = {"enabled": true, "speed": 40.0, "pickup": 1.0}
var is_authority: bool = true
var draws: bool = false
var tick_rate: int = 64
var combat: DotCombatManager = null
## Callables from the game: id -> ArenaPlayer or null, and the ids of everybody playing.
var player_for: Callable = Callable()
var player_ids: Callable = Callable()
## Client: the ragdolls to stick a knife into, and the blood layer; [method bind_view] sets them.
var ragdolls: Node = null
var blood: Node = null
var look_of: Callable = Callable()

var _knives: Dictionary = {}
var _next_id: int = 1
var _aim_held: Dictionary = {}
var _tick: int = 0
var _model_box: AABB = AABB()


func count() -> int:
	return _knives.size()


func get_knife(id: int) -> Knife:
	return _knives.get(id, null)


func entries() -> Array:
	return _knives.values()


## Server, before the player simulates: the aim key's rising edge with the knife in hand throws it.
## The button is cleared on [param fire] for this tick, so nothing else reads the press.
func input(id: int, player, fire: DotWeaponCommand) -> void:
	if not is_authority or fire == null or player == null or player.arsenal == null:
		return
	var down := fire.is_pressed(DotWeaponCommand.BUTTON_AIM)
	var was: bool = _aim_held.get(id, false)
	_aim_held[id] = down
	if not down or was or not bool(rules.get("enabled", true)):
		return
	var def: DotWeaponDef = player.arsenal.current_def()
	if def == null or def.id != KNIFE:
		return
	if player.arsenal.drop_from_slot(player.arsenal.current_slot()).is_empty():
		return
	fire.set_button(DotWeaponCommand.BUTTON_AIM, false)
	var _id := throw(id, player.muzzle_position(), fire.aim_direction(), player.controller.state.velocity)


## Server: a knife leaves [param from] along [param aim] at the rule's speed plus [param carried].
func throw(owner: int, from: Vector3, aim: Vector3, carried: Vector3 = Vector3.ZERO) -> int:
	var k := Knife.new()
	k.id = _next_id
	_next_id += 1
	k.owner = owner
	k.at = from
	k.velocity = aim.normalized() * float(rules.get("speed", 40.0)) + carried
	k.facing = k.velocity.normalized()
	_knives[k.id] = k
	_tell(k)
	if _knives.size() > MAX_KNIVES:
		var oldest: Knife = _knives[_knives.keys().min()]
		_finish(oldest, oldest.owner, true)
	return k.id


## Server, every tick after the players moved.
func tick(current_tick: int, delta: float) -> void:
	if not is_authority:
		return
	_tick = current_tick
	for k: Knife in _knives.values():
		k.age += 1
		if k.phase == Phase.FLY:
			_fly(k, delta)
		if k.phase == Phase.GONE:
			continue
		var limit := FLIGHT_SECONDS if k.phase == Phase.FLY else LIFETIME_SECONDS
		if k.age >= int(limit * tick_rate):
			_finish(k, k.owner, true)
			continue
		_offer(k)


func _fly(k: Knife, delta: float) -> void:
	k.velocity.y -= (THROW_GRAVITY if k.bounces == 0 else GRAVITY) * delta
	var step := k.velocity * delta
	var hit := _sweep(k, step)
	if hit == null:
		k.at += step
		if k.velocity.length() > 0.5:
			k.facing = k.velocity.normalized()
		return
	if not hit.blocked and _kill(k, hit):
		return
	_bounce(k, hit)
	_tell(k)


## The first enemy the blade meets dies, and the knife stays in them.
func _kill(k: Knife, hit: DotHitbox.Hit) -> bool:
	if combat == null or not combat.is_authority or hit.entity == null:
		return false
	var victim := combat.entity_id_of(hit.entity)
	var health := combat.health_of(victim) if victim != 0 else null
	if victim == k.owner or health == null or not health.alive:
		return false
	var damage := DotDamage.make(k.owner, victim, 10000.0, combat.damage_type(&"strike"))
	damage.tick = _tick
	damage.point = hit.point
	damage.direction = k.velocity.normalized()
	damage.weapon_id = KNIFE
	damage.context = {"why": &"knife_throw"}
	var _applied := combat.apply_damage(damage)
	if damage.refused or health.alive:
		return false
	k.facing = k.velocity.normalized()
	k.phase = Phase.STUCK
	k.victim = victim
	k.at = hit.point
	k.velocity = Vector3.ZERO
	_tell(k)
	return true


func _bounce(k: Knife, hit: DotHitbox.Hit) -> void:
	var normal := hit.normal
	if normal.length_squared() < 0.0001:
		normal = -k.velocity.normalized()
	k.at = hit.point + normal * 0.03
	var into := k.velocity.dot(normal)
	var along := k.velocity - normal * into
	k.velocity = along * SURFACE_KEEP - normal * into * RESTITUTION
	k.bounces += 1
	var on_floor := normal.y > 0.7 and (k.velocity.length() < REST_SPEED or k.bounces >= MAX_BOUNCES)
	if on_floor or k.bounces >= MAX_BOUNCES * 3:
		var flat := Vector3(k.facing.x, 0.0, k.facing.z)
		k.facing = flat.normalized() if flat.length() > 0.01 else Vector3.FORWARD
		k.velocity = Vector3.ZERO
		k.phase = Phase.REST


## One tick of flight against the world and, before its first bounce, every body but the thrower's.
func _sweep(k: Knife, step: Vector3) -> DotHitbox.Hit:
	if combat == null or combat.trace == null or step.length() <= 0.0:
		return null
	var sets: Array[DotHitboxSet] = []
	if k.bounces == 0 and is_authority:
		sets = combat.hitbox_sets()
	var thrower := combat.hitboxes_of(k.owner)
	combat.trace.exclude = [thrower] if thrower != null else []
	var hit := combat.trace.ray(k.at, step.normalized(), step.length(), sets)
	combat.trace.exclude = []
	return hit if hit != null and hit.ok() else null


## Somebody alive without a knife within the pickup reach of one lying still takes it.
func _offer(k: Knife) -> void:
	var reach := float(rules.get("pickup", 1.0))
	if reach <= 0.0 or k.phase == Phase.FLY or not player_ids.is_valid():
		return
	for id: int in player_ids.call():
		var p = player_for.call(id)
		if p == null or not p.is_alive() or p.arsenal == null or p.arsenal.carries(KNIFE):
			continue
		var feet: Vector3 = p.controller.state.position
		var close := Vector3(feet.x, clampf(k.at.y, feet.y, feet.y + 1.8), feet.z)
		if close.distance_to(k.at) <= reach and p.arsenal.give(KNIFE, true).ok:
			_finish(k, id, false)
			return


## Takes [param k] out of the world; [param returning] gives it to [param to] when alive and without one.
func _finish(k: Knife, to: int, returning: bool) -> void:
	if returning and player_for.is_valid():
		var p = player_for.call(to)
		if p != null and p.is_alive() and p.arsenal != null and not p.arsenal.carries(KNIFE):
			var _given: DotResult = p.arsenal.give(KNIFE, true)
	k.phase = Phase.GONE
	k.victim = to
	_tell(k)
	_drop_view(k)
	var _gone := _knives.erase(k.id)


func _tell(k: Knife) -> void:
	changed.emit(k.id, k.owner, k.phase, k.victim, k.at, k.velocity if k.phase == Phase.FLY else k.facing)


## Client: one knife event from the server. [param motion] is the velocity in flight, else the blade's facing.
func mirror(id: int, owner: int, phase: int, victim: int, at: Vector3, motion: Vector3) -> void:
	if is_authority:
		return
	var k: Knife = _knives.get(id, null)
	if phase == Phase.GONE:
		if k != null:
			_drop_view(k)
			var _gone := _knives.erase(id)
		return
	if k == null:
		k = Knife.new()
		k.id = id
		_knives[id] = k
	var was := k.phase
	k.owner = owner
	k.phase = phase
	k.victim = victim
	k.at = at
	k.velocity = motion if phase == Phase.FLY else Vector3.ZERO
	if motion.length() > 0.01:
		k.facing = motion.normalized()
	if phase == Phase.FLY and k.bounces == 0 and was == Phase.FLY and k.age > 0:
		k.bounces = 1
	if phase == Phase.STUCK and (was != Phase.STUCK or k.holder == null):
		k.seek = SEEK_SECONDS


## Client: flies the mirrors between events, against the world only; the server's next event corrects it.
func _physics_process(delta: float) -> void:
	if is_authority:
		return
	for k: Knife in _knives.values():
		if k.phase != Phase.FLY:
			continue
		k.age += 1
		k.velocity.y -= (THROW_GRAVITY if k.bounces == 0 else GRAVITY) * delta
		var step := k.velocity * delta
		var hit := _sweep(k, step)
		if hit == null:
			k.at += step
		else:
			_bounce(k, hit)


## Client: where the ragdolls and the blood are. Cheap; called every frame.
func bind_view(ragdoll_layer: Node, blood_layer: Node) -> void:
	ragdolls = ragdoll_layer
	blood = blood_layer


func _process(delta: float) -> void:
	if not draws:
		return
	for k: Knife in _knives.values():
		_draw(k, delta)


func _draw(k: Knife, delta: float) -> void:
	if k.holder == null:
		k.holder = _make_holder()
	var model: Node3D = k.holder.get_child(0)
	if k.phase == Phase.STUCK:
		_draw_stuck(k, model, delta)
		return
	var face := k.facing if k.facing.length() > 0.01 else Vector3.FORWARD
	k.holder.global_transform = Transform3D(_basis_along(face), k.at)
	var c := _model_box.get_center()
	if k.phase == Phase.FLY:
		## Tumbling end over end about its own centre.
		k.spun += SPIN * delta
		model.transform = Transform3D(Basis(Vector3.RIGHT, -k.spun), Vector3.ZERO) * Transform3D(Basis.IDENTITY, -c)
	else:
		## Flat on its side, a hair over the floor.
		var lie := Basis(Vector3.FORWARD, PI * 0.5)
		model.transform = Transform3D(lie, Vector3(0.0, _model_box.size.x * 0.5 + 0.005, 0.0)) * Transform3D(Basis.IDENTITY, -c)


## In the body: the tip [constant EMBED] past the hit point, following the ragdoll part nearest it.
func _draw_stuck(k: Knife, model: Node3D, delta: float) -> void:
	var c := _model_box.get_center()
	model.transform = Transform3D(Basis.IDENTITY, Vector3(-c.x, -c.y, -_model_box.position.z - EMBED))
	if k.holder.get_child_count() < 2:
		k.holder.add_child(_wound())
	if not k.bled:
		k.bled = true
		_bleed(k)
	if k.part != null:
		if is_instance_valid(k.part) and k.part.is_inside_tree():
			k.holder.global_transform = k.part.global_transform * k.part_local
			return
		k.part = null
	k.holder.global_transform = Transform3D(_basis_along(k.facing), k.at)
	if k.seek > 0.0:
		k.seek -= delta
		k.part = _nearest_part(k.at)
		if k.part != null:
			k.part_local = k.part.global_transform.affine_inverse() * k.holder.global_transform
			k.seek = 0.0


func _nearest_part(at: Vector3) -> Node3D:
	if ragdolls == null or not is_instance_valid(ragdolls) or not ragdolls.has_method(&"live"):
		return null
	var best: Node3D = null
	var best_d := PART_REACH
	for doll in ragdolls.call(&"live"):
		if doll == null or not is_instance_valid(doll) or not doll.has_method(&"part_nodes"):
			continue
		for part in doll.call(&"part_nodes"):
			if part is Node3D and is_instance_valid(part):
				var d: float = (part as Node3D).global_position.distance_to(at)
				if d < best_d:
					best_d = d
					best = part
	return best


func _bleed(k: Knife) -> void:
	if blood == null or not is_instance_valid(blood):
		return
	if blood.has_method(&"splat_behind"):
		var _behind: Variant = blood.call(&"splat_behind", k.at - k.facing * 0.5, k.at, 3.0, 0.8)
	if blood.has_method(&"splat_below"):
		var _pool: Variant = blood.call(&"splat_below", k.at, 3.0, 0.2, 0.7)


func _wound() -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 0.055
	mesh.height = 0.11
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.01, 0.01)
	mat.roughness = 0.25
	mesh.material = mat
	var wound := MeshInstance3D.new()
	wound.mesh = mesh
	wound.scale = Vector3(1.0, 1.0, 0.35)
	return wound


func _make_holder() -> Node3D:
	var model: Node3D = look_of.call(KNIFE) if look_of.is_valid() else null
	if model == null:
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.02, 0.04, 0.3)
		var box := MeshInstance3D.new()
		box.mesh = mesh
		model = box
	var holder := Node3D.new()
	holder.name = "Knife"
	holder.add_child(model)
	add_child(holder)
	if _model_box.size == Vector3.ZERO:
		_model_box = _bounds(model)
	return holder


## The model's mesh extent in its own space.
static func _bounds(model: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var inv := model.global_transform.affine_inverse()
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var box := inv * mi.global_transform * mi.mesh.get_aabb()
			out = box if first else out.merge(box)
			first = false
		stack.append_array(n.get_children())
	return out if not first else AABB(Vector3(-0.01, -0.02, -0.15), Vector3(0.02, 0.04, 0.3))


## A basis whose -Z is [param forward].
static func _basis_along(forward: Vector3) -> Basis:
	var f := forward.normalized()
	var up := Vector3.UP if absf(f.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	return Basis.looking_at(f, up)


func _drop_view(k: Knife) -> void:
	if k.holder != null and is_instance_valid(k.holder):
		k.holder.queue_free()
	k.holder = null
	k.part = null


## Everything gone at once, for a map change or a round reset; owners get theirs back on the server.
func clear() -> void:
	for k: Knife in _knives.values():
		if is_authority:
			_finish(k, k.owner, true)
		else:
			_drop_view(k)
	_knives.clear()
	_aim_held.clear()
