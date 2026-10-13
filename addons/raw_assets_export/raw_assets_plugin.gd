@tool
extends EditorPlugin

## Registers the exporter that packs res://assets/ (raw PNG, JSON, BIN, WAV) into every export. See raw_assets_exporter.gd.

var _exporter: EditorExportPlugin


func _enter_tree() -> void:
	_exporter = preload("res://addons/raw_assets_export/raw_assets_exporter.gd").new()
	add_export_plugin(_exporter)


func _exit_tree() -> void:
	remove_export_plugin(_exporter)
	_exporter = null
