extends SceneTree
## Scans the duel scene for pictures without the picture material. A node with a texture and no material samples with the world's
## LINEAR filter (the world sets it so the picture shader can sample), which shows the bilinear blur on the HUD panels, the digits, the
## hand and the field. The duel is a real DuelScene in the window (seeded, a fixed deal), played for a few hundred frames so the hand,
## the field and the readouts are all built; then every node with a texture is checked for its material.
##   G:\Software\Redot\redot.windows.editor.x86_64.exe --headless --path <project> -s res://tests/duel_materials.gd
## Prints PASS or FAIL, lists the first offenders, and exits 0 when every textured node has a material.

const DuelScene := preload("res://scripts/duel/duel_scene.gd")
const FRAMES := 4000

var duel: Node = null
var frames := 0


func _initialize() -> void:
	duel = DuelScene.new()
	duel.opponent_id = 1
	duel.engine_seed = 7
	root.add_child(duel)


func _process(_delta: float) -> bool:
	frames += 1
	if frames < FRAMES:
		return false
	var counted := [0]
	var missing: Array = []
	_scan(duel, missing, counted)
	print("duel materials: %d textured nodes checked, %d without a material" % [counted[0], missing.size()])
	for path in missing.slice(0, 20):
		print("  no material: ", path)
	var ok: bool = counted[0] >= 30 and missing.is_empty()
	print("PASS" if ok else "FAIL", "  every textured node of the duel scene has the picture material")
	quit(0 if ok else 1)
	return false


func _scan(node: Node, missing: Array, counted: Array) -> void:
	if node is CanvasItem and "texture" in node and node.get("texture") != null:
		counted[0] += 1
		if node.material == null:
			missing.append(str(node.get_path()) if node.is_inside_tree() else str(node.name))
	for child in node.get_children():
		_scan(child, missing, counted)
