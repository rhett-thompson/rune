#!/bin/sh
# Generates the original two-joint model with standard awk and base64 utilities.
set -eu
if [ "$#" -ne 0 ]; then
    case "$1" in --help|-h) printf '%s\n' 'Usage: examples/skeletal_animation_3d/generate_fixture.sh'; exit 0 ;; esac
    printf '%s\n' 'This generator takes no arguments.' >&2; exit 1
fi
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM
LC_ALL=C awk -v binary="$temporary/arm.bin" -v metadata="$temporary/metadata.json" '
function byte(value) { printf "%c",value > binary; byte_count++ }
function integer(value,size, i) { for(i=0;i<size;i++) { byte(value%256); value=int(value/256) } }
function float32(value, sign,exponent,mantissa) {
    sign=value<0?2147483648:0; if(value<0) value=-value
    if(value==0) { integer(sign,4); return }
    exponent=int(log(value)/log(2)); if(2^exponent>value) exponent--
    mantissa=int(value/(2^exponent)*8388608+0.5)-8388608
    if(mantissa==8388608) { exponent++; mantissa=0 }
    integer(sign+(exponent+127)*8388608+mantissa,4)
}
function accessor(values,count,type,components,component_type,minimum,maximum, offset,i,item) {
    while(byte_count%4) byte(0)
    offset=byte_count
    for(i=1;i<=count;i++) if(component_type==5123) integer(values[i],2); else float32(values[i])
    item=sprintf("{\"bufferView\":%d,\"componentType\":%d,\"count\":%d,\"type\":\"%s\"",accessor_count,component_type,count/components,type)
    if(minimum!="") item=item ",\"min\":" minimum ",\"max\":" maximum
    views[accessor_count]=sprintf("{\"buffer\":0,\"byteOffset\":%d,\"byteLength\":%d}",offset,byte_count-offset)
    accessors[accessor_count++]=item "}"
}
function rotations(angles, count,i,half,j) {
    count=split(angles,a," "); j=0
    for(i=1;i<=count;i++) { half=a[i]*atan2(0,-1)/360; r[++j]=0; r[++j]=0; r[++j]=sin(half); r[++j]=cos(half) }
    accessor(r,j,"VEC4",4,5126)
}
BEGIN {
    byte_count=0; accessor_count=0
    face_normals[1]="0 0 1"; face_vertices[1]="-1 0 1 1 0 1 1 1 1 -1 1 1"
    face_normals[2]="0 0 -1"; face_vertices[2]="1 0 -1 -1 0 -1 -1 1 -1 1 1 -1"
    face_normals[3]="1 0 0"; face_vertices[3]="1 0 1 1 0 -1 1 1 -1 1 1 1"
    face_normals[4]="-1 0 0"; face_vertices[4]="-1 0 -1 -1 0 1 -1 1 1 -1 1 -1"
    face_normals[5]="0 1 0"; face_vertices[5]="-1 1 1 1 1 1 1 1 -1 -1 1 -1"
    face_normals[6]="0 -1 0"; face_vertices[6]="-1 0 -1 1 0 -1 1 0 1 -1 0 1"
    for(bone=0;bone<2;bone++) for(face=1;face<=6;face++) {
        split(face_normals[face],n," "); split(face_vertices[face],v," "); base=position_count/3
        for(i=0;i<4;i++) {
            positions[++position_count]=v[i*3+1]*0.18; positions[++position_count]=v[i*3+2]+bone; positions[++position_count]=v[i*3+3]*0.18
            for(j=1;j<=3;j++) normals[++normal_count]=n[j]
            joints[++joint_count]=bone; joints[++joint_count]=0; joints[++joint_count]=0; joints[++joint_count]=0
            weights[++weight_count]=1; weights[++weight_count]=0; weights[++weight_count]=0; weights[++weight_count]=0
        }
        indices[++index_count]=base; indices[++index_count]=base+1; indices[++index_count]=base+2; indices[++index_count]=base; indices[++index_count]=base+2; indices[++index_count]=base+3
    }
    accessor(positions,position_count,"VEC3",3,5126,"[-0.18,0,-0.18]","[0.18,2,0.18]")
    accessor(normals,normal_count,"VEC3",3,5126); accessor(joints,joint_count,"VEC4",4,5123); accessor(weights,weight_count,"VEC4",4,5126); accessor(indices,index_count,"SCALAR",1,5123)
    split("1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 1 0 0 0 0 1 0 0 0 0 1 0 0 -1 0 1",binds," "); accessor(binds,32,"MAT4",16,5126)
    split("0 0.5 1 1.5 2",times," "); accessor(times,5,"SCALAR",1,5126,"[0]","[2]")
    rotations("0 75 0 -75 0"); rotations("-25 0 25 0 -25")
    printf "{\"byteLength\":%d,\"bufferViews\":[",byte_count > metadata
    for(i=0;i<accessor_count;i++) printf "%s%s",i?",":"",views[i] > metadata
    printf "],\"accessors\":[" > metadata
    for(i=0;i<accessor_count;i++) printf "%s%s",i?",":"",accessors[i] > metadata
    print "]}" > metadata
    close(binary); close(metadata)
}'
data=$(base64 "$temporary/arm.bin" | tr -d '\r\n')
metadata=$(cat "$temporary/metadata.json")
byte_length=$(wc -c < "$temporary/arm.bin" | tr -d ' ')
# The generated metadata carries the accessor offsets; the surrounding glTF is declarative.
mkdir -p "$directory/assets"
{
    printf '%s' '{"asset":{"version":"2.0","generator":"Rune two-joint fixture generator"},"scene":0,"scenes":[{"nodes":[0,1]}],"nodes":[{"name":"Arm","mesh":0,"skin":0},{"name":"Root","children":[2]},{"name":"Tip","translation":[0,1,0]}],"skins":[{"joints":[1,2],"skeleton":1,"inverseBindMatrices":5}],"meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"JOINTS_0":2,"WEIGHTS_0":3},"indices":4}]}],"animations":[{"name":"bend","samplers":[{"input":6,"output":7,"interpolation":"LINEAR"}],"channels":[{"sampler":0,"target":{"node":2,"path":"rotation"}}]},{"name":"sway","samplers":[{"input":6,"output":8,"interpolation":"LINEAR"}],"channels":[{"sampler":0,"target":{"node":1,"path":"rotation"}}]}],'
    printf '"buffers":[{"byteLength":%s,"uri":"data:application/octet-stream;base64,%s"}],' "$byte_length" "$data"
    printf '%s\n' "$metadata" | sed 's/^{"byteLength":[0-9]*,//'
} > "$directory/assets/arm.gltf"
printf 'Wrote assets/arm.gltf (%s binary bytes, two joints, two clips).\n' "$byte_length"
