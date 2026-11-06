package assetcatalog

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

@(test)
catalog_loads_owned_relative_paths_and_directory_children :: proc(t:^testing.T) {
	directory,error:=os.make_directory_temp("build","assetcatalog-*",context.allocator)
	if !testing.expect(t,error==nil) {return}; defer delete(directory); defer os.remove(directory)
	filename:=fmt.aprintf("%s/assets.json",directory); defer delete(filename); defer os.remove(filename)
	assert(os.write_entire_file(filename,`{"version":1,"assets":{"model.door":"assets/models/door.glb"},"directories":{"dir.levels":"assets/levels/"},"roots":[],"dependencies":{}}`)==nil)
	catalog,open_error:=open(directory)
	if !testing.expect(t,open_error=="",open_error) {return}
	retained,found:=load(&catalog,"model.door",context.allocator)
	testing.expect(t,found && retained=="assets/models/door.glb")
	defer delete(retained)
	for pair in ([][2]string{{"dir.levels","assets/levels"},{"dir.levels/next.level.json","assets/levels/next.level.json"}}) {
		path,ok:=load(&catalog,pair[0],context.allocator)
		testing.expect(t,ok && path==pair[1]); delete(path)
	}
	for key in ([]string{"missing","assets/models/door.glb","dir.levels/../outside","dir.levels//outside","dir.levels/C:/outside","dir.levels/next\\outside","dir.levels/next/"}) {
		_,ok:=load(&catalog,key)
		testing.expect(t,!ok,"unknown names and traversing directory children must fail")
	}
	destroy(&catalog)
	testing.expect(t,retained=="assets/models/door.glb","returned paths outlive the catalog")
	testing.expect(t,catalog.arena==nil)
	_,nil_ok:=load(nil,"model.door"); testing.expect(t,!nil_ok)
}

@(test)
catalog_rejects_invalid_entries_without_changing_engine_state :: proc(t:^testing.T) {
	directory,error:=os.make_directory_temp("build","assetcatalog-invalid-*",context.allocator)
	if !testing.expect(t,error==nil) {return}; defer delete(directory); defer os.remove(directory)
	filename:=fmt.aprintf("%s/assets.json",directory); defer delete(filename); defer os.remove(filename)
	for document in ([]string{
		`[]`, `{"version":2}`, `{"assets":[]}`, `{"assets":{"model":"../outside.glb"}}`,
		`{"assets":{"model":"/outside.glb"}}`, `{"assets":{"model":"C:/outside.glb"}}`,
		`{"assets":{"model":"assets/models/"}}`,
		`{"assets":{"model":4}}`,
		`{"assets":{"same":"one.txt"},"directories":{"same":"folder"}}`,
		`{"assets":{"same":"one.txt","same":"two.txt"}}`, `{} {}`,
	}) {
		assert(os.write_entire_file(filename,document)==nil)
		catalog,open_error:=open(directory)
		testing.expect(t,open_error!="" && catalog.arena==nil,document)
		destroy(&catalog)
	}
	_,path_error:=open(directory,"../assets.json")
	testing.expect(t,path_error!="")
	// The owner allocator is retained, so destruction does not depend on the
	// caller's current scratch allocator.
	assert(os.write_entire_file(filename,`{"assets":{}}`)==nil)
	catalog,open_error:=open(directory)
	if !testing.expect(t,open_error=="",open_error) {return}
	owner_allocator:=context.allocator
	context.allocator=mem.nil_allocator()
	destroy(&catalog)
	context.allocator=owner_allocator
}
