// Bounded, allocation-free world-space bursts. The caller owns the value pool;
// rendering borrows its live prefix and never advances simulation.
package particles

import "core:math"

Burst3D :: struct {
	lifetime, speed: [2]f32,
	// Full cone width in degrees: 180 emits into the surface's hemisphere.
	spread: f32,
	gravity: [3]f32,
	start_size, end_size: f32,
	start_color, end_color: [4]u8,
	seed: u32,
}

Particle3D :: struct {
	position, velocity, gravity: [3]f32,
	age, lifetime: f32,
	start_size, end_size: f32,
	start_color, end_color: [4]u8,
}

Pool3D :: struct($Capacity: int) {
	particles: [Capacity]Particle3D,
	count: int,
	random: u32,
}

valid_burst_3d :: proc(settings: Burst3D) -> bool {
	if settings.lifetime[0]<=0 || settings.lifetime[1]<settings.lifetime[0] ||
		settings.speed[0]<0 || settings.speed[1]<settings.speed[0] ||
		settings.spread<0 || settings.spread>360 || settings.start_size<0 || settings.end_size<0 {return false}
	for v in ([]f32{settings.lifetime[0],settings.lifetime[1],settings.speed[0],settings.speed[1],
		settings.spread,settings.gravity[0],settings.gravity[1],settings.gravity[2],settings.start_size,settings.end_size}) {
		if math.is_nan(v) || math.is_inf(v) {return false}
	}
	return true
}

// Overflow drops new births. Each particle retains its birth-time settings,
// so overlapping bursts may have different colors, sizes, and lifetimes.
emit_burst_3d :: proc(pool: ^Pool3D($N), settings: Burst3D, count: int, origin, direction: [3]f32) -> int {
	if count<=0 || !valid_burst_3d(settings) {return 0}
	for v in origin {if math.is_nan(v) || math.is_inf(v) {return 0}}
	length:=math.sqrt(direction[0]*direction[0]+direction[1]*direction[1]+direction[2]*direction[2])
	if length<0.0001 || math.is_nan(length) || math.is_inf(length) {return 0}
	axis:=direction/length
	helper:=[3]f32{0,1,0} if abs(axis[1])<0.9 else [3]f32{1,0,0}
	tangent:=[3]f32{axis[1]*helper[2]-axis[2]*helper[1],axis[2]*helper[0]-axis[0]*helper[2],axis[0]*helper[1]-axis[1]*helper[0]}
	tangent/=math.sqrt(tangent[0]*tangent[0]+tangent[1]*tangent[1]+tangent[2]*tangent[2])
	bitangent:=[3]f32{axis[1]*tangent[2]-axis[2]*tangent[1],axis[2]*tangent[0]-axis[0]*tangent[2],axis[0]*tangent[1]-axis[1]*tangent[0]}
	if pool.random==0 {pool.random=settings.seed if settings.seed!=0 else 1}
	spawned:=min(count,N-pool.count)
	cone_cos:=math.cos(settings.spread*f32(math.PI/360))
	for _ in 0..<spawned {
		// Uniform solid-angle sampling avoids clumping on the cone's axis.
		cosine:=cone_cos+(1-cone_cos)*next_random_unit(&pool.random)
		sine:=math.sqrt(max(f32(0),1-cosine*cosine))
		angle:=next_random_unit(&pool.random)*f32(2*math.PI)
		speed:=settings.speed[0]+(settings.speed[1]-settings.speed[0])*next_random_unit(&pool.random)
		pool.particles[pool.count]={
			position=origin,velocity=(axis*cosine+(tangent*math.cos(angle)+bitangent*math.sin(angle))*sine)*speed,
			gravity=settings.gravity,lifetime=settings.lifetime[0]+(settings.lifetime[1]-settings.lifetime[0])*next_random_unit(&pool.random),
			start_size=settings.start_size,end_size=settings.end_size,start_color=settings.start_color,end_color=settings.end_color,
		}
		pool.count+=1
	}
	return spawned
}

update_3d :: proc(pool: ^Pool3D($N), dt: f32) {
	if dt<=0 || math.is_nan(dt) || math.is_inf(dt) {return}
	i:=0
	for i<pool.count {
		p:=&pool.particles[i]
		p.age+=dt
		if p.age>=p.lifetime {pool.count-=1; pool.particles[i]=pool.particles[pool.count]; continue}
		p.position+=p.velocity*dt+p.gravity*(0.5*dt*dt)
		p.velocity+=p.gravity*dt
		i+=1
	}
}

appearance_3d :: proc(p: Particle3D) -> (size: f32, color: [4]u8) {
	// Share the existing size/color interpolation with 2D effects.
	return appearance(Particle2D{age=p.age,lifetime=p.lifetime,start_size=p.start_size,end_size=p.end_size,start_color=p.start_color,end_color=p.end_color})
}

clear_3d :: proc(pool: ^Pool3D($N)) {pool.count=0; pool.random=0}

@(private)
next_random_unit :: proc(random: ^u32) -> f32 {
	x:=random^; x~=x<<13; x~=x>>17; x~=x<<5; random^=x
	return f32(x>>8)/16777216
}
