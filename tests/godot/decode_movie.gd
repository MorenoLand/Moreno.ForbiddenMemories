extends SceneTree
## Decodes the first frames of the STR intro movie to build/movie/frame_N.png (headless).

const MDEC_SCRIPT := preload("res://scripts/runner/mdec.gd")
const STR_SCRIPT := preload("res://scripts/runner/str_movie.gd")
const FRAME_COUNT := 125
const SAVE := [2, 60, 120]


func _init() -> void:
	var movie = STR_SCRIPT.new("res://build/disc/DATA/MOVIE.STR.raw")
	if not movie.is_open():
		push_error("cannot open movie")
		quit(1)
		return
	var out_dir := ProjectSettings.globalize_path("res://build/movie")
	DirAccess.make_dir_recursive_absolute(out_dir)
	for n in FRAME_COUNT:
		var frame: Dictionary = movie.next_frame()
		if frame.is_empty():
			push_error("no frame %d" % n)
			break
		var w: int = frame["width"]
		var h: int = frame["height"]
		var bs: PackedByteArray = frame["bitstream"]
		var t0 := Time.get_ticks_usec()
		var res: Dictionary = MDEC_SCRIPT.decode_frame_ex(bs, w, h)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var rgb: PackedByteArray = res["rgb"]
		print("frame %d (num %d): %dx%d, bitstream %d bytes, frame_size %d, qscale %d, version %d, end_bit %d (%.1f bytes), decode %.1f ms" % [
			n, frame["frame_number"], w, h, bs.size(), frame["frame_size"], res["qscale"], res["version"],
			res["end_bit"], res["end_bit"] / 8.0, ms])
		if SAVE.has(n):
			var img := Image.create_from_data(w, h, false, Image.FORMAT_RGB8, rgb)
			img.save_png("%s/frame_%d.png" % [out_dir, n])
	quit(0)
