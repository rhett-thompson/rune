package assets

import "core:fmt"
import "rune:navigation"

NavMesh_Asset :: struct {mesh: navigation.Mesh_3D,revision:u64,stamp:i64}
navmesh_data :: proc(manager: ^Asset_Manager,path: string) -> (navigation.Mesh_3D,u64,bool) {
	if manager==nil || path=="" {return {},0,false}
	if manager.navmeshes==nil {manager.navmeshes=make(map[string]NavMesh_Asset)}
	if _,found:=manager.navmeshes[path]; !found {manager.navmeshes[retain_path(manager,path)]={}; load_navmesh(manager,path,.Load)}
	asset:=manager.navmeshes[path]
	return asset.mesh,asset.revision,asset.revision!=0
}
load_navmesh :: proc(manager:^Asset_Manager,path:string,operation:Asset_Operation) {
	old:=manager.navmeshes[path]
	mesh,error:=navigation.load_mesh_3d(resolve_path(manager,path))
	old.stamp=modified_time(resolve_path(manager,path))
	if error!="" {report_failure(manager,{kind=.NavMesh,operation=operation,source_path=path,field="asset",asset_path=path,
		detail=fmt.tprint(error,"; keeping the last working navmesh, or leaving navigation unavailable")})}
	else {navigation.destroy_mesh_3d(&old.mesh); old.mesh=mesh; old.revision+=1; resolve_asset_failure(manager,path,"asset",path)}
	manager.navmeshes[path]=old
}
refresh_navmeshes :: proc(manager:^Asset_Manager) {
	for path,asset in manager.navmeshes {if modified_time(resolve_path(manager,path))!=asset.stamp {load_navmesh(manager,path,.Reload)}}
}
shutdown_navmeshes :: proc(manager:^Asset_Manager) {
	for _,&asset in manager.navmeshes {navigation.destroy_mesh_3d(&asset.mesh)}
	delete(manager.navmeshes); manager.navmeshes=nil
}
