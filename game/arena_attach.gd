extends RefCounted
## Weapon attachments in the arena (docs/netcode.md, Ask.ATTACH): one attachments catalogue for every player, the
## request a client sends, the server's answer to it, and the suppressed report of a gun with a suppressor on.
## The fitting reaches every machine as `net_fitted`; nothing here touches hit registration.

const SLOT_BITS := 5
const NAME_BYTES := 32
## On the holder of an `AwShotFx` (a world model, or the local rig): its gun has a suppressor on.
const SUPPRESSED_META := &"arena_suppressed"

static var _catalogue: DotWeaponAttachments = null


## The pack's attachments, built once: `attachment_defs()` makes a new catalogue on every call.
static func catalogue() -> DotWeaponAttachments:
	if _catalogue == null:
		_catalogue = AwSpawnProvider.attachment_defs()
	return _catalogue


static func write_request(slot: int, mount: StringName, id: StringName) -> PackedByteArray:
	var w := DotNetWriter.new()
	w.write_uint(clampi(slot, 0, (1 << SLOT_BITS) - 1), SLOT_BITS)
	w.write_string(String(mount), NAME_BYTES)
	w.write_string(String(id), NAME_BYTES)
	return w.to_bytes()


## Reads a request and fits [param arsenal] if the catalogue allows it. Server only: the result is what the
## server decided, and the client sees it through the next snapshot's `net_fitted`.
static func serve(arsenal: DotWeaponArsenal, reader: DotNetReader) -> DotResult:
	var wire := [int(reader.read_uint(SLOT_BITS)), reader.read_string(NAME_BYTES), reader.read_string(NAME_BYTES)]
	if not reader.ok():
		return DotResult.fail(DotError.CODE_INVALID, "A cut-off attach request.")
	var parsed := DotWeaponAttachRequest.from_wire(wire)
	if not parsed.ok:
		return parsed
	return (parsed.value as DotWeaponAttachRequest).apply(arsenal)


## The replicated code of [param arsenal]'s held gun, 0 for none.
static func held_code(arsenal: DotWeaponArsenal) -> int:
	if arsenal == null or arsenal.attachments == null or arsenal.current() == null:
		return 0
	var base := arsenal.catalogue.get_def(arsenal.current().id())
	if base == null or arsenal.attachments.code_bits(base) > DotWeaponNetSync.FITTED_BITS:
		return 0
	return arsenal.attachments.encode(base, arsenal.fitting_at(arsenal.current_slot()))


## Whether [param code] on gun [param id] has a suppressor on.
static func suppressed(id: StringName, code: int) -> bool:
	if code == 0 or id == &"":
		return false
	var base := AwWeaponCatalogue.shared().get_def(id)
	if base == null or catalogue().code_bits(base) > DotWeaponNetSync.FITTED_BITS:
		return false
	var fitted := catalogue().apply(base, catalogue().decode(base, code))
	return fitted.ok and bool((fitted.value as DotWeaponDef).params.get(DotWeaponAttachment.PARAM_SUPPRESSED, false))


## Wraps [param fx]'s report: while its holder carries [constant SUPPRESSED_META], the shot plays through
## [param shots] (`func(at: Vector3) -> bool`); otherwise the report it had. Read at each shot, so a pooled
## effect that moves to another holder follows that holder. Wrapping an effect already wrapped does nothing.
static func wrap_report(fx: AwShotFx, shots: Callable) -> void:
	if fx == null or fx.shot_sound == fx.get_meta(&"arena_attach_wrap", Callable()):
		return
	var base := fx.shot_sound
	var wrap := func(id: StringName, kind: StringName, at: Vector3, indoors: bool) -> bool:
		var holder := fx.get_parent()
		if holder != null and bool(holder.get_meta(SUPPRESSED_META, false)) and shots.is_valid():
			return bool(shots.call(at))
		return base.is_valid() and bool(base.call(id, kind, at, indoors))
	fx.set_meta(&"arena_attach_wrap", wrap)
	fx.shot_sound = wrap


## A suppressed report at [param at] through [param presentation]'s layered shot player; false when it has none
## (layered shots off), and the effect then plays its own report.
static func play_suppressed(presentation: Object, at: Vector3) -> bool:
	var shots: DotShotPlayer = presentation.get(&"shots") if is_instance_valid(presentation) else null
	if shots == null:
		return false
	var res := shots.fire(DotAudioShotStock.id_of(AwShotLayers.shot_class(AwWeaponSound.SUPPRESSED)), at, true)
	return res.ok and int(res.value_or(0)) > 0
