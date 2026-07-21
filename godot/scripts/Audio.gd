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
