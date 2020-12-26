tool
extends "scatter_path.gd"


export var global_seed := 0 setget _set_global_seed
export var use_instancing := true setget _set_instancing
export var disable_updates_in_game := true

var modifier_stack setget _set_modifier_stack

var _namespace = preload("./namespace.gd").new()
var _transforms
var _items := []
var _total_proportion: int
var _was_duplicated := false


func _ready() -> void:
	if not modifier_stack:
		modifier_stack = _namespace.ModifierStack.new()
		modifier_stack.just_created = true

	self.connect("curve_updated", self, "update")
	_discover_items()


func add_child(node, legible_name := false) -> void:
	.add_child(node, legible_name)
	_discover_items()


func remove_child(node) -> void:
	.remove_child(node)
	_discover_items()


func _get_configuration_warning() -> String:
	#_discover_items()
	if _items.empty():
		return "Scatter requires at least one ScatterItem node as a child to work."
	return ""


func _get_property_list() -> Array:
	var list := []
	
	# Used to display the modifier stack in an inspector plugin.
	list.push_back({
		name = "modifier_stack",
		type = TYPE_OBJECT,
		hint_string =  "ScatterModifierStack",
	})
	return list


func _get(property):
	if property == "modifier_stack":
		return modifier_stack
	return null


func _set(property, value):
	if property == "modifier_stack":
		# TODO: This duplicate is there because I couldn't find a way to detect
		# when a node is duplicated from the editor and I don't want multiple
		# scatter nodes to share the same stack.
		modifier_stack = value.duplicate(7)
		call_deferred("clear")
		return true
	
	# For some reason, set_modifier_stack is not always called when duplicating
	# a node, but other parameters like transforms are so we check that as well
	if property == "transform":
		if modifier_stack:
			modifier_stack = modifier_stack.duplicate(7)
		else:
			modifier_stack = _namespace.ModifierStack.new()
			modifier_stack.just_created = true
		# Duplicate the curve item too. If someone want to share data, it has
		# to be explicitely done by the user

		call_deferred("_make_curve_unique")
		call_deferred("clear")
	
	return false


func clear() -> void:
	_discover_items()
	_delete_duplicates()
	_delete_multimeshes()


func update() -> void:
	if disable_updates_in_game and not Engine.is_editor_hint():
		return

	_discover_items()
	if not _items.empty():
		_transforms = _namespace.Transforms.new()
		_transforms.set_path(self)
		modifier_stack.update(_transforms, global_seed)
		
		if use_instancing:
			_create_multimesh()
		else:
			_create_duplicates()
	
	var parent = get_parent()
	if parent and parent.has_method("update"):
		parent.update()


# Loop through children to find all the ScatterItem nodes
func _discover_items() -> void:
	_items.clear()
	_total_proportion = 0

	for c in get_children():
		if c is _namespace.ScatterItem:
			_items.append(c)
			_total_proportion += c.proportion
	
	if is_inside_tree():
		get_tree().emit_signal("node_configuration_warning_changed", self)


func _create_duplicates() -> void:
	var offset := 0
	var transforms_count: int = _transforms.list.size()

	for item in _items:
		var count = int(round(float(item.proportion) / _total_proportion * transforms_count))
		var root = _get_or_create_instances_root(item)
		var instances = root.get_children()
		var child_count = instances.size()
		
		for i in count:
			if (offset + i) >= transforms_count:
				return
			var instance
			if i < child_count:
				# Grab an instance from the pool if there's one available
				instance = instances[i]
			else:
				# If not, create one
				instance = _create_instance(item, root)
			
			instance.transform = _transforms.list[offset + i]
		
		# Delete the unused instances left in the pool if any
		if count < child_count:
			for i in (child_count - count):
				instances[count + i].queue_free()
		
		offset += count


func _get_or_create_instances_root(item):
	var root: Spatial
	if item.has_node("Duplicates"):
		root = item.get_node("Duplicates")
	else:
		root = Spatial.new()
		root.set_name("Duplicates")
		item.add_child(root)
		root.set_owner(get_tree().get_edited_scene_root())
	root.translation = Vector3.ZERO
	return root


func _create_instance(item, root):
	# Create item and add it to the scene
	var instance = load(item.item_path).instance()
	root.add_child(instance)
	instance.set_owner(get_tree().get_edited_scene_root())
	return instance


func _delete_duplicates():
	for item in _items:
		if item.has_node("Duplicates"):
			item.get_node("Duplicates").queue_free()


func _create_multimesh() -> void:
	var offset := 0
	var transforms_count: int = _transforms.list.size()
	
	for item in _items:
		var count = int(round(float(item.proportion) / _total_proportion * transforms_count))
		var mmi = _setup_multi_mesh(item, count)
		if not mmi:
			return

		for i in count:
			if (offset + i) >= transforms_count:
				return
			
			# Apply local scale multiplier to each transform
			var t = _transforms.list[offset + i]
			var origin = t.origin
			t.origin = Vector3.ZERO
			t = t.scaled(Vector3.ONE * item.scale_modifier)
			t.origin = origin
			
			mmi.multimesh.set_instance_transform(i, t)
			
		offset += count


func _setup_multi_mesh(item, count):
	var instance = item.get_node("MultiMeshInstance")
	if not instance:
		instance = MultiMeshInstance.new()
		instance.set_name("MultiMeshInstance")
		item.add_child(instance)
		instance.set_owner(get_tree().get_edited_scene_root())
	
	if not instance.multimesh:
		instance.multimesh = MultiMesh.new()
	
	instance.translation = Vector3.ZERO

	var node = load(item.item_path)
	if not node:
		printerr("Warning: ", item.item_path, " is not a valid scene file")
		return
	
	var mesh_instance = _get_mesh_from_scene(node.instance())
	if not mesh_instance:
		printerr("Warning: No MeshInstance found in ", item.item_path)
		return
	
	instance.material_override = mesh_instance.get_surface_material(0)
	instance.multimesh.instance_count = 0 # Set this to zero or you can't change the other values
	instance.multimesh.mesh = mesh_instance.mesh
	instance.multimesh.transform_format = 1
	instance.multimesh.instance_count = count

	return instance


func _get_mesh_from_scene(node):
	if node is MeshInstance:
		return node
	
	for c in node.get_children():
		var res = _get_mesh_from_scene(c)
		if res:
			node.remove_child(res)
			return res
	
	return null


func _delete_multimeshes() -> void:
	if _items.empty():
		_discover_items()

	for item in _items:
		if item.has_node("MultiMeshInstance"):
			item.get_node("MultiMeshInstance").queue_free()


func _set_global_seed(val: int) -> void:
	global_seed = val
	update()


func _set_instancing(val: bool) -> void:
	use_instancing = val
	if use_instancing:
		_delete_duplicates()
	else:
		_delete_multimeshes()
	
	update()


func _set_modifier_stack(val) -> void:
	modifier_stack = _namespace.ModifierStack.new()
	modifier_stack.stack = val.duplicate_stack()
	
	if not modifier_stack.is_connected("stack_changed", self, "update"):
		modifier_stack.connect("stack_changed", self, "update")


func _make_curve_unique() -> void:
	curve = curve.duplicate(true)
	_update_from_curve()
