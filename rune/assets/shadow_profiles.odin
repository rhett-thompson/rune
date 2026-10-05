package assets

import "core:encoding/json"
import "core:os"
import "rune:shadows"

Shadow_Profile_Asset :: struct {settings: shadows.Settings, revision: u64, stamp: i64}

shadow_profile :: proc(manager: ^Asset_Manager, path: string) -> (shadows.Settings,u64,bool) {
	if manager==nil || path=="" {return {},0,false}
	if manager.shadow_profiles==nil {manager.shadow_profiles=make(map[string]Shadow_Profile_Asset)}
	if _,found:=manager.shadow_profiles[path]; !found {
		manager.shadow_profiles[retain_path(manager,path)]={}
		load_shadow_profile(manager,path,.Load)
	}
	a:=manager.shadow_profiles[path]
	return a.settings,a.revision,a.revision!=0
}

load_shadow_profile :: proc(manager: ^Asset_Manager, path: string, operation: Asset_Operation) {
	a:=manager.shadow_profiles[path]
	full_path:=resolve_path(manager,path)
	a.stamp=modified_time(full_path)
	bytes,err:=os.read_entire_file(full_path,context.allocator)
	defer delete(bytes)
	value: json.Value
	ok:=err==nil && json.unmarshal(bytes,&value,allocator=context.temp_allocator)==nil
	settings: shadows.Settings
	if ok {settings,ok=shadows.from_json(value)}
	if !ok {
		report_failure(manager,{kind=.ShadowProfile,operation=operation,source_path=path,field="shadow_profile",asset_path=path,
			detail="Cannot load shadow profile: expected valid shadow settings; keeping the last working profile, or disabling shadows if none loaded"})
	} else {
		a.settings=settings
		a.revision+=1
		resolve_asset_failure(manager,path,"shadow_profile",path)
	}
	manager.shadow_profiles[path]=a
}

refresh_shadow_profiles :: proc(manager: ^Asset_Manager) {
	for path,a in manager.shadow_profiles {
		if modified_time(resolve_path(manager,path))!=a.stamp {load_shadow_profile(manager,path,.Reload)}
	}
}
