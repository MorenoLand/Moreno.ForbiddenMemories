@tool
extends EditorExportPlugin

## Packs every file under res://assets/ into the export as a raw file (no import). The editor does not import assets/
## (it has a .gdignore), and the exporter skips folders the editor ignores, so the include filter on the preset never
## reaches these files. Reading them here with FileAccess works in the editor and in headless exports.
## The game loads them with Image.load_from_file, FileAccess and AudioStreamWAV.load_from_file on res:// paths, which
## read from the PCK in an exported build.

const ROOT := "res://assets"


func _get_name() -> String:
	return "RawAssetsExporter"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_add_tree(ROOT)


func _add_tree(dir_path: String) -> void:
	for file_name in DirAccess.get_files_at(dir_path):
		if file_name.begins_with(".") or file_name.ends_with(".import"):
			continue
		var file_path := dir_path.path_join(file_name)
		add_file(file_path, FileAccess.get_file_as_bytes(file_path), false)
	for sub_dir in DirAccess.get_directories_at(dir_path):
		if sub_dir.begins_with("."):
			continue
		_add_tree(dir_path.path_join(sub_dir))
