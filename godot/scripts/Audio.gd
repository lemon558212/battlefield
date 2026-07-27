# Audio.gd — 自動載入：BGM（選單/平時/激戰交叉）＋角色語音（GDD/13 移植 audio.js）
extends Node

var _bgm: AudioStreamPlayer
var _voice: AudioStreamPlayer
var _cur := ""

func _ready() -> void:
	_bgm = AudioStreamPlayer.new()
	_bgm.bus = "Master"
	_bgm.volume_db = -8.0
	add_child(_bgm)
	_voice = AudioStreamPlayer.new()
	_voice.volume_db = -4.0
	add_child(_voice)

func bgm(kind: String) -> void:
	# kind: "menu" / "battle" / "" (停)
	if kind == _cur:
		return
	_cur = kind
	if kind == "":
		_bgm.stop()
		return
	var path := "res://assets/audio/%s.mp3" % ("menu" if kind == "menu" else "battle_calm")
	if ResourceLoader.exists(path):
		var s = load(path)
		if s is AudioStream:
			s.loop = true
			_bgm.stream = s
			_bgm.play()

func sting(kind: String) -> void:
	# 一次性：victory / defeat
	var path := "res://assets/audio/%s.mp3" % kind
	if ResourceLoader.exists(path):
		var s = load(path)
		if s is AudioStream:
			_bgm.stop()
			_cur = ""
			_bgm.stream = s
			_bgm.play()

func voice(cls: String, kind: String) -> void:
	# kind: sel / atk / down
	var path := "res://assets/audio/voice/%s_%s.mp3" % [cls, kind]
	if ResourceLoader.exists(path):
		var s = load(path)
		if s is AudioStream:
			_voice.stream = s
			_voice.play()


# ---------- 戰場音效（GDD/14 §音響；2026-07-27 補）----------
# ⚠ 先前整個專案**只有 BGM 與角色語音**：開一槍是靜音的，爆炸也是。
#   而且用的是 AudioStreamPlayer（非空間化），沒有位置也沒有距離衰減。
#   這裡一律用 AudioStreamPlayer3D：遠處的槍聲會變小、聽得出方向，
#   這既是鐵律 0（聲音在空氣中會衰減），也是戰術資訊（槍聲暴露位置）。
const SFX_DIR := "res://assets/audio/sfx/"
var _sfx_cache := {}
var _last_sfx: AudioStreamPlayer3D = null      # 給驗證台檢查參數用
# 由 Main 注入：這個位置到聽者（鏡頭）之間有沒有被牆擋住。
# 擋住的聲音要變悶——這是真實的（高頻被牆吸收），也是情報
# （「聽起來悶悶的」代表對方在牆後面）。
var los_check: Callable = Callable()

func sfx3d(name: String, pos: Vector3, db := 0.0, pitch := 1.0) -> AudioStreamPlayer3D:
	var muffled := false
	if los_check.is_valid():
		muffled = not bool(los_check.call(pos))
	var path: String = SFX_DIR + name + ".wav"
	if not _sfx_cache.has(name):
		_sfx_cache[name] = load(path) if ResourceLoader.exists(path) else null
	var st = _sfx_cache[name]
	if st == null:
		return null
	var host := get_tree().current_scene
	if host == null:
		return null
	var pl := AudioStreamPlayer3D.new()
	pl.stream = st
	pl.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	pl.unit_size = 7.0          # 7m 之內接近原音量，之後隨距離反比衰減
	pl.max_distance = 140.0
	pl.volume_db = db - (7.0 if muffled else 0.0)
	pl.pitch_scale = pitch
	if muffled:
		# 低通：牆會吃掉高頻，剩下悶悶的低頻。這是 AudioStreamPlayer3D 內建的。
		pl.attenuation_filter_cutoff_hz = 900.0
		pl.attenuation_filter_db = -24.0
	host.add_child(pl)
	pl.global_position = pos
	pl.finished.connect(pl.queue_free)
	pl.play()
	_last_sfx = pl
	return pl

# 槍聲：依武器型別選音色，音高隨機微調（每一槍都一模一樣會像機器）
func gun(wtype: String, pos: Vector3) -> void:
	var name := "shot_rifle"
	match wtype:
		"carbine", "smg": name = "shot_carbine"
		"sniper": name = "shot_sniper"
		"lmg", "naval_mg": name = "shot_lmg"
		"cannon", "mortar", "naval_gun": name = "shot_cannon"
		"rocket", "agm", "antiship_missile", "sam_missile": name = "shot_rocket"
	sfx3d(name, pos, 0.0, randf_range(0.94, 1.06))

func impact(kind: String, pos: Vector3) -> void:
	sfx3d("impact_" + kind, pos, -4.0, randf_range(0.9, 1.12))

func boom(pos: Vector3) -> void:
	sfx3d("explosion", pos, 2.0, randf_range(0.92, 1.08))

func step(pos: Vector3, quiet := false) -> void:
	sfx3d("step_%d" % (randi() % 3 + 1), pos, -16.0 if quiet else -9.0,
			randf_range(0.88, 1.14))

func reload_click(pos: Vector3) -> void:
	sfx3d("reload", pos, -6.0, randf_range(0.96, 1.05))
