package main

import "core:fmt"
import "core:slice"
import "rune:ecs"

// Game-owned data components: ordinary item IDs/counts serialize without
// runtime entity handles. The helpers accept any actor carrying Inventory.
Inventory :: struct {items: map[string]int}
Pickup :: struct {item_id: string, quantity: int}
Door_State :: struct {required_key: string, unlocked, open: bool}
Inventory_Stack_Limit :: 99

register_course_components :: proc(registry:^ecs.Component_Registry) -> bool {
	return ecs.register_component(registry,"ThirdPersonController",Third_Person_Settings,Third_Person_Defaults) &&
		ecs.register_component(registry,"Inventory",Inventory,Inventory{}) &&
		ecs.register_component(registry,"Pickup",Pickup,Pickup{quantity=1}) &&
		ecs.register_component(registry,"DoorState",Door_State,Door_State{}) &&
		ecs.register_component(registry,"ZoneEffect",Zone_Effect,Zone_Effect{damage=25}) &&
		ecs.register_component(registry,"Health",Health,Default_Health) &&
		ecs.register_component(registry,"RespawnPoint",Respawn_Point,Default_Respawn_Point)
}

item_name :: proc(id:string) -> string {
	if id=="brass_key" {return "Brass key"}
	return id
}
inventory_count :: proc(world:^ecs.World,actor:ecs.Entity,id:string) -> int {
	value,found:=ecs.get(world,actor,Inventory)
	if !found {return 0}
	return max(0,value.items[id])
}
inventory_add :: proc(world:^ecs.World,actor:ecs.Entity,id:string,quantity:int) -> bool {
	value,found:=ecs.get(world,actor,Inventory)
	if !found || id=="" || quantity<=0 || quantity>Inventory_Stack_Limit {return false}
	count:=value.items[id]
	if count<0 || count>Inventory_Stack_Limit-quantity {return false}
	// get() borrows its map. Copy before editing; set() owns the replacement.
	items:=make(map[string]int,context.temp_allocator)
	for key,n in value.items {items[key]=n}
	items[id]=count+quantity
	return ecs.set(world,actor,Inventory{items=items})
}
collect_pickup :: proc(world:^ecs.World,actor,target:ecs.Entity) -> string {
	if !ecs.is_enabled(world,target) || !ecs.is_enabled(world,actor) {return ""}
	pickup,found:=ecs.get(world,target,Pickup)
	if !found {return ""}
	if !inventory_add(world,actor,pickup.item_id,pickup.quantity) {return "Cannot carry this item."}
	// The disabled entity and its children are saved along with the inventory.
	ecs.set_enabled(world,target,false)
	return fmt.tprintf("Collected %s.",item_name(pickup.item_id))
}
inventory_summary :: proc(world:^ecs.World,actor:ecs.Entity) -> string {
	value,found:=ecs.get(world,actor,Inventory)
	if !found || len(value.items)==0 {return "Inventory: empty"}
	ids:=make([dynamic]string,context.temp_allocator)
	for id,count in value.items {if count>0 {append(&ids,id)}}
	slice.sort(ids[:])
	result:="Inventory: "
	for id,i in ids {
		if i>0 {result=fmt.tprintf("%s, ",result)}
		result=fmt.tprintf("%s%s x%d",result,item_name(id),value.items[id])
	}
	return result
}
