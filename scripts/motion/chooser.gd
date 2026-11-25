# Evaluates the sample's chooser tables (extracted/data/choosers.json) like Unreal's
# Chooser.cpp EvaluateChooser: columns filter the rows in order, then each remaining row's result
# is collected (AllResults mode) or the first one wins. Nested and evaluate-chooser results recurse.
# The context is a Dictionary of the anim blueprint's variables, keyed by the column's property
# chain joined with "." (for example "Speed2D", "TrajectoryCollision.TimeToLand"). Enum columns
# compare by the enumerator's display name ("OnGround", "Crouch"...).
class_name ChooserEvaluator
extends RefCounted

var _choosers: Dictionary
var missing_inputs := {}


func _init(choosers_json: Dictionary) -> void:
	_choosers = choosers_json


## Every result asset (paths) of a chooser asset, in row order.
func evaluate_all(chooser: String, context: Dictionary) -> Array:
	var out := []
	var entry: Dictionary = _choosers[chooser]
	_evaluate_table(entry, entry["root_table"], context, out, true)
	return out


## The first result asset of a chooser asset, or "" when nothing passes.
func evaluate_first(chooser: String, context: Dictionary) -> String:
	var out := []
	var entry: Dictionary = _choosers[chooser]
	_evaluate_table(entry, entry["root_table"], context, out, false)
	return out[0] if out.size() > 0 else ""


func _evaluate_table(entry: Dictionary, table_name: String, context: Dictionary, out: Array, all: bool) -> bool:
	var table: Dictionary = entry["tables"][table_name]
	var rows: Array = []
	for r: Dictionary in table["rows"]:
		if not r.get("disabled", false):
			rows.append(int(r["index"]))
	for col: Dictionary in table["columns"]:
		if col.get("bDisabled", false) or col.get("is_output", false):
			continue
		rows = _filter(col, rows, context)
	var any := false
	for index in rows:
		var row: Dictionary = table["rows"][index]
		if _collect(entry, row["result"], context, out, all):
			any = true
			if not all:
				return true
	if not any and table.has("fallback_result") and table["fallback_result"] != null:
		any = _collect(entry, table["fallback_result"], context, out, all)
	return any


func _collect(entry: Dictionary, result: Dictionary, context: Dictionary, out: Array, all: bool) -> bool:
	match result.get("type"):
		"Asset":
			if result.get("asset") == null:
				return false
			out.append(result["asset"])
			return true
		"NestedChooser":
			return _evaluate_table(entry, result["chooser"], context, out, all)
		"EvaluateChooser":
			var other: Dictionary = _choosers.get(result["chooser"], {})
			if other.is_empty():
				return false
			return _evaluate_table(other, other["root_table"], context, out, all)
	return false


func _filter(col: Dictionary, rows: Array, context: Dictionary) -> Array:
	var input: Dictionary = col.get("input", {})
	var key := ".".join(PackedStringArray(input.get("property_chain", [])))
	if not context.has(key):
		# A column whose input can't be read lets every row through (Chooser.cpp).
		missing_inputs[key] = true
		return rows
	var value = context[key]
	var values: Array = col.get("row_values", [])
	var out := []
	for index in rows:
		if index >= values.size():
			continue  # rows past the column's values are dropped
		if _passes(col["type"], values[index], value, col):
			out.append(index)
	return out


static var _enums := {}


## An enumerator's value from its display name (extracted/data/enums.json); -1 when unknown.
static func _enum_value(col: Dictionary, display_name: String) -> int:
	if _enums.is_empty():
		_enums = JSON.parse_string(FileAccess.get_file_as_string("res://extracted/data/enums.json"))
	var enum_name := String(col.get("input", {}).get("enum", "")).get_file()
	for e: Dictionary in _enums.get(enum_name, {}).get("entries", []):
		if e["display_name"] == display_name:
			return int(e["value"])
	return -1


static func _passes(type: String, cell, value, col: Dictionary) -> bool:
	match type:
		"BoolColumn":
			# JSON numbers are floats: 0 MatchFalse, 1 MatchTrue, 2 MatchAny.
			var v := int(cell.get("value", 2)) if cell is Dictionary else int(cell)
			return v == 2 or (v == 1) == bool(value)
		"EnumColumn":
			var cmp: String = cell.get("comparison", {}).get("name", "MatchEqual")
			if cmp == "MatchAny":
				return true
			var equal: bool = str(cell.get("display_name")) == str(value)
			return equal if cmp == "MatchEqual" else not equal
		"MultiEnumColumn":
			# FChooserMultiEnumRowData::Evaluate: an empty mask passes, else the value's bit must be set.
			var mask := int(cell.get("mask", 0))
			var bit := _enum_value(col, str(value))
			return mask == 0 or (bit >= 0 and (mask & (1 << bit)) != 0)
		"FloatRangeColumn":
			var v := float(value)
			if col.get("bWrapInput", false):
				v = wrapf(v, -180.0, 180.0)
				if float(cell["Max"]) < float(cell["Min"]):
					return (cell["bNoMin"] or v >= float(cell["Min"])) or (cell["bNoMax"] or v <= float(cell["Max"]))
			return (cell["bNoMin"] or v >= float(cell["Min"])) and (cell["bNoMax"] or v <= float(cell["Max"]))
	return true
