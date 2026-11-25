#include "blend_stack_node.h"
#include "pose_search.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_gasp_native(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(PoseSearch);
	GDREGISTER_CLASS(BlendStackNode);
}

static void uninitialize_gasp_native(ModuleInitializationLevel p_level) {
}

extern "C" {
GDExtensionBool GDE_EXPORT gasp_native_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_gasp_native);
	init_obj.register_terminator(uninitialize_gasp_native);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
