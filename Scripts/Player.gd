extends CharacterBody2D
class_name Player

@export var player_name : String
@export var player_id : int = 1:
	set(id):
		player_id = id
		$InputSynchronizer.set_multiplayer_authority(id)

@export var max_speed : float = 150.0
@export var turn_rate : float = 2.5
var throttle : float = 0.0

@export var shoot_rate : float = 0.1
var last_shoot_time : float
var projectile_scene = preload("res://Scenes/Projectile.tscn")

@export var cur_hp : int = 100
@export var max_hp : int = 100
@export var score : int = 0
var last_attacker_id : int
var is_alive : bool = true

@onready var input = $InputSynchronizer
@onready var shadow = $Shadow
@onready var muzzle = $Muzzle
@onready var respawn_timer = $RespawnTimer
@onready var audio_player = $AudioPlayer
@onready var sprite = $Sprite
@onready var hit_particle = $HitParticle

# sound effects
var shoot_sfx = preload("res://Audio/PlaneShoot.wav")
var hit_sfx = preload("res://Audio/PlaneHit.wav")
var explode_sfx = preload("res://Audio/PlaneExplode.wav")

# weapon heat
@export var cur_weapon_heat : float = 0.0
@export var max_weapon_heat : float = 100.0
var weapon_heat_increase_rate : float = 7.0
var weapon_heat_cool_rate : float = 25.0
var weapon_heat_cap_wait_time : float = 1.5
var weapon_heat_waiting : bool = false

# border locations for wrapping around
var border_min_x : float = -400
var border_max_x : float = 400
var border_min_y : float = -230
var border_max_y : float = 230

var game_manager

func _ready():
	game_manager = get_tree().get_current_scene().get_node("GameManager")
	game_manager.players.append(self)
	
	# do we control this player?
	if $InputSynchronizer.is_multiplayer_authority():
		game_manager.local_player = self
		
		var network_manager = get_tree().get_current_scene().get_node("Network")
		set_player_name.rpc(network_manager.local_username)
	
	if multiplayer.is_server():
		position = game_manager.get_random_position()

@rpc("any_peer", "call_local", "reliable")
func set_player_name (new_name : String):
	player_name = new_name

func _process(delta):
	# update shadow on all CLIENTS
	shadow.global_position = position + Vector2(0, 20)
	
	# only the server runs this code
	if multiplayer.is_server() and is_alive:
		_check_border()
		_try_shoot()
		_manage_weapon_heat(delta)

func _physics_process (delta):
	# only the server runs this code
	if multiplayer.is_server() and is_alive:
		_move(delta)

func _move (delta):
	rotate(input.turn_input * turn_rate * delta)
	
	throttle += input.throttle_input * delta
	throttle = clamp(throttle, 0.0, 1.0)
	
	velocity = -transform.y * throttle * max_speed
	
	move_and_slide()

func _try_shoot ():
	if not input.shoot_input:
		return
	
	if cur_weapon_heat >= max_weapon_heat:
		return
	
	if Time.get_unix_time_from_system() - last_shoot_time < shoot_rate:
		return
	
	last_shoot_time = Time.get_unix_time_from_system()
	
	var proj = projectile_scene.instantiate()
	proj.position = muzzle.global_position
	proj.rotation = rotation + deg_to_rad(randf_range(-2, 2))
	proj.owner_id = player_id
	get_tree().get_current_scene().get_node("Network/SpawnedNodes").add_child(proj, true)
	
	play_shoot_sfx.rpc()
	
	cur_weapon_heat += weapon_heat_increase_rate
	cur_weapon_heat = clamp(cur_weapon_heat, 0, max_weapon_heat)

# called on all CLIENTS when player shoots
@rpc("authority", "call_local", "reliable")
func play_shoot_sfx ():
	audio_player.stream = shoot_sfx
	audio_player.play()

func take_damage (damage_amount : int, attacker_player_id : int):
	cur_hp -= damage_amount
	last_attacker_id = attacker_player_id
	take_damage_clients.rpc()
	
	if cur_hp <= 0:
		die()

# called on all CLIENTS when player takes damage
@rpc("authority", "call_local", "reliable")
func take_damage_clients ():
	if $InputSynchronizer.is_multiplayer_authority():
		game_manager.camera_shake.shake(0.1, 3.0)
	
	audio_player.stream = hit_sfx
	audio_player.play()
	
	hit_particle.emitting = true
	
	sprite.modulate = Color(1, 0, 0)
	await get_tree().create_timer(0.05).timeout
	sprite.modulate = Color(1, 1, 1)

func die ():
	is_alive = false
	position = Vector2(0, 9999)
	respawn_timer.start(2)
	game_manager.on_player_die(player_id, last_attacker_id)
	die_clients.rpc()

# called on ALL clients when player dies
@rpc("authority", "call_local", "reliable")
func die_clients ():
	if $InputSynchronizer.is_multiplayer_authority():
		game_manager.camera_shake.shake(0.5, 7.0)
	
	audio_player.stream = explode_sfx
	audio_player.play()

func respawn ():
	is_alive = true
	cur_hp = max_hp
	throttle = 0.0
	last_attacker_id = 0
	position = game_manager.get_random_position()
	rotation = 0

func _manage_weapon_heat (delta):
	if cur_weapon_heat < max_weapon_heat:
		cur_weapon_heat -= weapon_heat_cool_rate * delta
		
		if cur_weapon_heat < 0:
			cur_weapon_heat = 0
		
		return
	
	if weapon_heat_waiting:
		return
	
	weapon_heat_waiting = true
	await get_tree().create_timer(weapon_heat_cap_wait_time).timeout
	weapon_heat_waiting = false
	cur_weapon_heat -= weapon_heat_cool_rate * delta

# loop around when we leave the screen
func _check_border ():
	if position.x < border_min_x:
		position.x = border_max_x
	if position.x > border_max_x:
		position.x = border_min_x
	if position.y < border_min_y:
		position.y = border_max_y
	if position.y > border_max_y:
		position.y = border_min_y

func increase_score (amount : int):
	score += amount
