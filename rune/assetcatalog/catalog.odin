// Explicit asset-name lookup. Rune's existing loaders still consume paths.
package assetcatalog

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

Catalog :: struct {
	root, manifest: string,
	assets, directories: map[string]string,
	arena: ^mem.Dynamic_Arena,
	allocator: mem.Allocator,
}

// Open parses the catalog once. It does not load assets, change paths in authored
// JSON, or configure engine loaders. The caller owns the result until destroy.
open :: proc(root:string, manifest:string="assets.json") -> (Catalog,string) {
	if !relative_path_valid(manifest) {return {},"Asset catalog filename must be project-relative"}
	arena,allocation_error:=mem.new(mem.Dynamic_Arena)
	if allocation_error!=nil {return {},"Could not allocate asset catalog"}
	result:=Catalog{arena=arena,allocator=context.allocator}
	mem.dynamic_arena_init(arena,block_allocator=result.allocator,array_allocator=result.allocator)
	success:=false
	defer if !success {destroy(&result)}
	context.allocator=mem.dynamic_arena_allocator(arena)
	result.root=strings.clone(root) or_else ""
	result.manifest=strings.clone(manifest) or_else ""
	filename,path_error:=filepath.join({root,manifest})
	if path_error!=nil {return {},"Invalid asset catalog filename"}
	bytes,read_error:=os.read_entire_file(filename,context.allocator)
	if read_error!=nil {return {},"Could not read asset catalog"}
	parser:=json.make_parser(bytes,.JSON,true)
	value,parse_error:=json.parse_value(&parser)
	if parse_error!=nil || parser.curr_token.kind!=.EOF || strings.contains(string(bytes),"\x00") {
		return {},"Could not parse asset catalog JSON"}
	object,object_ok:=value.(json.Object)
	if !object_ok {return {},"Asset catalog must be an object"}
	if raw,present:=object["version"]; present {
		version,valid:=raw.(json.Integer)
		if !valid || version!=1 {return {},"Asset catalog version must be 1"}
	}
	result.assets=make(map[string]string)
	result.directories=make(map[string]string)
	for field in ([]string{"assets","directories"}) {
		raw,present:=object[field]
		if !present {continue}
		entries,valid:=raw.(json.Object)
		if !valid {return {},"Asset catalog assets and directories must be objects"}
		for key,raw_path in entries {
			path,path_ok:=raw_path.(json.String)
			if !key_valid(key) || !path_ok {return {},"Asset catalog entries must map names to relative paths"}
			text:=string(path)
			if field=="directories" && strings.has_suffix(text,"/") {text=text[:len(text)-1]}
			if !relative_path_valid(text) {return {},"Asset catalog entries must map names to relative paths"}
			if field=="assets" {result.assets[key]=text} else {result.directories[key]=text}
		}
	}
	for key in result.assets {
		if _,duplicate:=result.directories[key]; duplicate {return {},"Asset and directory names must be distinct"}
	}
	success=true
	return result,""
}

destroy :: proc(catalog:^Catalog) {
	if catalog==nil || catalog.arena==nil {return}
	mem.dynamic_arena_destroy(catalog.arena)
	mem.free(catalog.arena,catalog.allocator)
	catalog^={}
}

// Returns an owned project-relative filename for an exact asset/directory name,
// or a child of a named directory. Free it with the supplied allocator.
// Unknown names fail; ordinary filenames remain the existing loaders' concern.
load :: proc(catalog:^Catalog,key:string,allocator:=context.temp_allocator) -> (string,bool) {
	if catalog==nil {return "",false}
	if path,found:=catalog.assets[key]; found {owned,error:=strings.clone(path,allocator); return owned,error==nil}
	if path,found:=catalog.directories[key]; found {owned,error:=strings.clone(path,allocator); return owned,error==nil}
	if slash:=strings.index_byte(key,'/'); slash>0 {
		if directory,found:=catalog.directories[key[:slash]]; found {
			child:=key[slash+1:]
			if !relative_path_valid(child) {return "",false}
			return fmt.aprintf("%s/%s",directory,child,allocator=allocator),true
		}
	}
	return "",false
}

@(private)
key_valid :: proc(key:string)->bool {
	return key!="" && key==strings.trim_space(key) && !strings.contains_any(key,"/\\:\x00")
}

@(private)
relative_path_valid :: proc(path:string)->bool {
	if path=="" || strings.has_suffix(path,"/") || strings.contains_any(path,"\\:\x00") {return false}
	remaining:=path
	for part in strings.split_iterator(&remaining,"/") {
		if part=="" || part=="." || part==".." {return false}
		for character in part {if character<32 {return false}}
	}
	return true
}
