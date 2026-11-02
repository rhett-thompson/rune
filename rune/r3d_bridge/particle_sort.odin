package r3d_bridge

import "core:math"

// Typed comparisons and copies avoid generic smoothsort's indirect comparator
// and byte swaps. Stable ties retain source order. Scratch is reserved by the
// owner before any worker can sort; the callback never allocates.
@(private)
sort_particle_billboards :: proc(state:^Particle_Billboard_Batch) {
	count:=len(state.instances)
	if count<2 {return}
	if len(state.sort_scratch)<count {
		// Stable, allocation-free fallback if owner-side scratch growth failed.
		for i in 1..<count {
			instance:=state.instances[i];j:=i
			for j>0 && instance.depth>state.instances[j-1].depth {
				state.instances[j]=state.instances[j-1];j-=1
			}
			state.instances[j]=instance
		}
		return
	}
	source,destination:=state.instances[:],state.sort_scratch[:count]
	// Stable byte-wise radix passes retain all float depth precision. Equal
	// depths (including +/-zero) have the same key and keep their input order.
	// Nonfinite camera math can produce NaNs; retain comparison-sort behavior
	// for those inputs, whose depths have no numeric total ordering.
	finite_order:=true
	for instance in source {if math.is_nan(instance.depth) {finite_order=false;break}}
	if count>=256 && finite_order {
		histograms:[4][256]int
		for instance in source {
			key:=particle_depth_key(instance.depth)
			for pass in 0..<4 {histograms[pass][(key>>u32(pass*8))&255]+=1}
		}
		for pass in 0..<4 {
			offset:=0
			for &bucket in histograms[pass] {size:=bucket;bucket=offset;offset+=size}
			for instance in source {
				bucket:=(particle_depth_key(instance.depth)>>u32(pass*8))&255
				destination[histograms[pass][bucket]]=instance
				histograms[pass][bucket]+=1
			}
			source,destination=destination,source
		}
		return // Four passes finish in the original instance buffer.
	}
	for width:=1; width<count; width*=2 {
		for first:=0; first<count; first+=width*2 {
			middle,last:=min(first+width,count),min(first+width*2,count)
			a,b:=first,middle
			for i in first..<last {
				if a<middle && (b>=last || !(source[b].depth>source[a].depth)) {
					destination[i]=source[a];a+=1
				} else {destination[i]=source[b];b+=1}
			}
		}
		source,destination=destination,source
	}
	if raw_data(source)!=raw_data(state.instances) {copy(state.instances[:],source)}
}

@(private)
particle_depth_key :: #force_inline proc(depth:f32) -> u32 {
	bits:=transmute(u32)depth
	if depth==0 {bits=0}
	// Map IEEE sign/magnitude to ascending unsigned order, then invert for
	// back-to-front depth. Infinities retain their ordinary numeric order.
	ascending:=~bits if bits&0x80000000!=0 else bits~u32(0x80000000)
	return ~ascending
}
