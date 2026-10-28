package assets

import "core:testing"

@(test)
material_dependency_revisions_isolate_previews_sources_and_variants :: proc(t: ^testing.T) {
	manager:=material_preview_test_manager();defer shutdown(&manager)
	a:=Material_Data{texture="deps/a.png",surface_shader="deps/a.glsl",roughness=0.5}
	b:=Material_Data{texture="deps/b.png",normal="deps/b-normal.png",roughness=0.5}
	manager.materials[retain_path(&manager,"a.json")]={data=clone_material_data(a)}
	manager.materials[retain_path(&manager,"b.json")]={data=clone_material_data(b)}
	update_material_path_dependencies(&manager,"a.json",a)
	update_material_path_dependencies(&manager,"b.json",b)
	a_revision:=material_path_revision(&manager,"a.json")
	b_revision:=material_path_revision(&manager,"b.json")
	b_fingerprint:=material_dependency_fingerprint(&manager,"b.json",b)
	preview:=a;preview.roughness=0.1
	assert(set_material_preview(&manager,"a.json",preview))
	testing.expect(t,material_path_revision(&manager,"a.json")!=a_revision)
	testing.expect(t,material_path_revision(&manager,"b.json")==b_revision && material_dependency_fingerprint(&manager,"b.json",b)==b_fingerprint,
		"an unrelated preview preserves B's path revision and complete dependency fingerprint")
	assert(clear_material_preview(&manager,"a.json"))
	a_revision=material_path_revision(&manager,"a.json")
	material_texture_committed(&manager,"deps/b.png",manager.material_texture_watches["deps/b.png"]+1)
	testing.expect(t,material_path_revision(&manager,"a.json")==a_revision)
	testing.expect(t,material_path_revision(&manager,"b.json")!=b_revision && material_dependency_fingerprint(&manager,"b.json",b)!=b_fingerprint,
		"a material's own image edit invalidates it without changing its authored values")
	before_commit:=material_dependency_fingerprint(&manager,"b.json",b)
	material_texture_committed(&manager,"deps/b.png",manager.material_texture_watches["deps/b.png"])
	testing.expect(t,material_dependency_fingerprint(&manager,"b.json",b)!=before_commit,
		"a late GPU commit invalidates cached handles even after polling consumed the same file stamp")
	before_shader:=material_dependency_fingerprint(&manager,"a.json",a)
	material_texture_committed(&manager,"deps/a.glsl",manager.material_texture_watches["deps/a.glsl"]+1)
	testing.expect(t,material_dependency_fingerprint(&manager,"a.json",a)!=before_shader,"shader file edits participate in the fingerprint")
	base:=material_dependency_fingerprint(&manager,"b.json",b)
	for variant in 0..<3 {
		changed:=b
		switch variant {case 0:changed.wrap="repeat";case 1:changed.filter="point";case 2:changed.mipmaps=true}
		testing.expect(t,material_dependency_fingerprint(&manager,"b.json",changed)!=base,
			"the same path remains sensitive to independent sampler variants")
	}
}

@(test)
generated_orm_retirement_preserves_leases_and_unrelated_borrows :: proc(t: ^testing.T) {
	manager:=material_preview_test_manager();defer shutdown(&manager)
	manager.generated_orm_textures=make(map[u64]Texture_Asset)
	manager.generated_orm_states=make(map[u64]Generated_ORM_State)
	// Zero GPU handles keep this ownership regression window-independent; the
	// graphics validator checks the same transitions with actual textures.
	manager.generated_orm_textures[11]={}
	manager.generated_orm_states[11]={paths={"shared.png","",""},references=2}
	watch_material_source(&manager,"shared.png")
	material_texture_committed(&manager,"shared.png",manager.material_texture_watches["shared.png"]+1)
	testing.expect(t,manager.generated_orm_states[11].retired && manager.generated_orm_states[11].references==2)
	release_material_orm_texture(&manager,11)
	_,held:=manager.generated_orm_textures[11]
	testing.expect(t,held,"retired textures survive while another material retains its lease")
	release_material_orm_texture(&manager,11)
	_,held=manager.generated_orm_textures[11]
	testing.expect(t,!held,"the final release reclaims a retired entry")
	manager.generated_orm_textures[22]={}
	register_generated_orm(&manager,22,Material_Data{})
	record_generated_orm_borrow(&manager,22,"a.json")
	record_generated_orm_borrow(&manager,22,"b.json")
	retire_generated_orm_material(&manager,"a.json")
	_,held=manager.generated_orm_textures[22]
	testing.expect(t,held && len(manager.generated_orm_states[22].borrowed_materials)==1,
		"changing A does not destroy an ORM texture still borrowed by unrelated B")
	retire_generated_orm_material(&manager,"b.json")
	_,held=manager.generated_orm_textures[22]
	testing.expect(t,!held,"unused legacy material variants are reclaimed")
}
