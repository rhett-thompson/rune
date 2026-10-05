// Renderer-independent shadow profile data and per-light overrides.
package shadows

import "core:encoding/json"
import "core:math"
import "rune:jsonutil"

Optional :: union($T: typeid) {T}

Settings :: struct {
	enabled: bool,
	softness, opacity, depth_bias, slope_bias: f32,
	update_mode: string,
	interval_ms: i32,
}

Defaults :: Settings{enabled=true,softness=1,opacity=1,depth_bias=0.005,slope_bias=0.01,update_mode="continuous",interval_ms=250}

// Nil means inherit; false and zero are explicit overrides. No heap pointers.
Overrides :: struct {
	enabled: Optional(bool),
	softness, opacity, depth_bias, slope_bias: Optional(f32),
	update_mode: Optional(string),
	interval_ms: Optional(i32),
}

valid_mode :: proc(mode: string) -> bool {
	return mode=="continuous" || mode=="interval" || mode=="manual"
}

valid :: proc(s: Settings) -> bool {
	for v in ([4]f32{s.softness,s.opacity,s.depth_bias,s.slope_bias}) {
		if v<0 || math.is_nan(v) || math.is_inf(v) {return false}
	}
	return s.opacity<=1 && valid_mode(s.update_mode) && s.interval_ms>0
}

resolve :: proc(base: Settings, overrides: Overrides) -> Settings {
	s := base
	if v,ok:=overrides.enabled.(bool); ok {s.enabled=v}
	if v,ok:=overrides.softness.(f32); ok {s.softness=v}
	if v,ok:=overrides.opacity.(f32); ok {s.opacity=v}
	if v,ok:=overrides.depth_bias.(f32); ok {s.depth_bias=v}
	if v,ok:=overrides.slope_bias.(f32); ok {s.slope_bias=v}
	if v,ok:=overrides.update_mode.(string); ok {s.update_mode=v}
	if v,ok:=overrides.interval_ms.(i32); ok {s.interval_ms=v}
	return s
}

overrides_valid :: proc(o: Overrides) -> bool {return valid(resolve(Defaults,o))}

overrides_from_json :: proc(value: json.Value, allow_schema:=false) -> (Overrides,bool) {
	object,ok := value.(json.Object)
	if !ok {return {},false}
	o: Overrides
	for key,v in object {
		if key=="$schema" && allow_schema {if _,ok:=v.(json.String); !ok {return {},false}; continue}
		// Runtime snapshots retain null fields so console edits can address them.
		switch key {
		case "enabled","softness","opacity","depth_bias","slope_bias","update_mode","interval_ms":
		case: return {},false
		}
		if v==nil {continue}
		if null,ok:=v.(json.Null); ok && null==nil {continue}
		switch key {
		case "enabled":
			b,ok:=v.(json.Boolean); if !ok {return {},false}; o.enabled=bool(b)
		case "update_mode":
			m,ok:=v.(json.String); if !ok || !valid_mode(m) {return {},false}
			// Canonical literals avoid borrowing strings from the JSON document.
			switch m {case "continuous": o.update_mode="continuous"; case "interval": o.update_mode="interval"; case "manual": o.update_mode="manual"}
		case "interval_ms":
			n,ok:=v.(json.Integer); if !ok || n<=0 || n>2147483647 {return {},false}; o.interval_ms=i32(n)
		case:
			n,ok:=jsonutil.number(v); if !ok {return {},false}
			switch key {case "softness": o.softness=n; case "opacity": o.opacity=n; case "depth_bias": o.depth_bias=n; case "slope_bias": o.slope_bias=n}
		}
	}
	return o,overrides_valid(o)
}

from_json :: proc(value: json.Value) -> (Settings,bool) {
	if object,ok:=value.(json.Object); ok {
		for _,v in object {
			if v==nil {return {},false}
			if _,null:=v.(json.Null); null {return {},false}
		}
	}
	o,ok:=overrides_from_json(value,true)
	if !ok {return {},false}
	return resolve(Defaults,o),true
}

