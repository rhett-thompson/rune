#!/bin/sh
# Rebuild the demo's original hand-authored walkable center surface.
set -eu
if [ "$#" -ne 0 ]; then
    case "$1" in --help|-h) printf '%s\n' 'Usage: examples/navigation_3d/generate_mesh.sh'; exit 0 ;; esac
    printf '%s\n' 'This generator takes no arguments.' >&2; exit 1
fi
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
LC_ALL=C awk '
function vertex(x,y,z, key) {
    key=x SUBSEP y SUBSEP z
    if (!(key in lookup)) { lookup[key]=vertex_count; vertices[vertex_count++]=sprintf("[%g, %g, %g]",x,y,z) }
    return lookup[key]
}
function quad(x0,x1,z0,z1,y0,y1, a,b,c,d) {
    a=vertex(x0,y0,z0); b=vertex(x1,y1,z0); c=vertex(x1,y1,z1); d=vertex(x0,y0,z1)
    triangles[triangle_count++]=sprintf("[%d, %d, %d]",a,b,c)
    triangles[triangle_count++]=sprintf("[%d, %d, %d]",a,c,d)
}
BEGIN {
    vertex_count=0; triangle_count=0
    for(x=-8;x<=-4;x+=2) for(z=-4;z<=2;z+=2) if(x!=-6 || z!=-2) quad(x,x+2,z,z+2,0,0)
    for(x=-2;x<=0;x+=2) for(z=-2;z<=0;z+=2) quad(x,x+2,z,z+2,(x+2)/2,(x+4)/2)
    for(x=2;x<=6;x+=2) for(z=-4;z<=2;z+=2) quad(x,x+2,z,z+2,2,2)
    quad(10,12,0,2,0,0)
    print "{\n  \"$schema\": \"../../schemas/navmesh.schema.json\",\n  \"version\": 1,\n  \"agent_radius\": 0.4,\n  \"agent_height\": 2,\n  \"vertices\": ["
    for(i=0;i<vertex_count;i++) printf "    %s%s\n",vertices[i],i+1<vertex_count?",":""
    print "  ],\n  \"triangles\": ["
    for(i=0;i<triangle_count;i++) printf "    %s%s\n",triangles[i],i+1<triangle_count?",":""
    print "  ]\n}"
}' > "$directory/course.navmesh.json"
printf '%s\n' 'Wrote course.navmesh.json (47 vertices, 56 triangles).'
