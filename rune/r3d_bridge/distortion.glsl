// Two ellipsoids per matrix: center/strength, inverse radius/phase. The native
// user-uniform parser supports sixteen uniforms, but no uniform arrays.
uniform mat4 u_volumes0;
uniform mat4 u_volumes1;
uniform mat4 u_volumes2;
uniform mat4 u_volumes3;
uniform mat4 u_volumes4;
uniform mat4 u_volumes5;
uniform mat4 u_volumes6;
uniform mat4 u_volumes7;
uniform mat4 u_volumes8;
uniform mat4 u_volumes9;
uniform mat4 u_volumes10;
uniform mat4 u_volumes11;
uniform mat4 u_volumes12;
uniform mat4 u_volumes13;
uniform mat4 u_volumes14;
uniform mat4 u_volumes15;

mat4 distortionPair(int pair) {
    if(pair==0) return u_volumes0;
    if(pair==1) return u_volumes1;
    if(pair==2) return u_volumes2;
    if(pair==3) return u_volumes3;
    if(pair==4) return u_volumes4;
    if(pair==5) return u_volumes5;
    if(pair==6) return u_volumes6;
    if(pair==7) return u_volumes7;
    if(pair==8) return u_volumes8;
    if(pair==9) return u_volumes9;
    if(pair==10) return u_volumes10;
    if(pair==11) return u_volumes11;
    if(pair==12) return u_volumes12;
    if(pair==13) return u_volumes13;
    if(pair==14) return u_volumes14;
    return u_volumes15;
}

void fragment() {
    COLOR=FetchColor(PIXCOORD);
    vec4 unprojected=MATRIX_INV_PROJECTION*vec4(TEXCOORD*2.0-1.0,1.0,1.0);
    vec3 viewRay=PROJECTION_MODE==1 ? vec3(0.0,0.0,-1.0) : normalize(unprojected.xyz);
    vec3 ray=mat3(MATRIX_INV_VIEW)*viewRay;
    vec3 origin=CAMERA_POSITION;
    if(PROJECTION_MODE==1) origin+=mat3(MATRIX_INV_VIEW)*vec3(unprojected.xy/unprojected.w,0.0);
    float forward=max(-viewRay.z,0.0001);
    float sceneDistance=FetchDepth(PIXCOORD)/forward;
    vec2 total=vec2(0.0);
    float foregroundDepth=0.0;
    for(int i=0;i<32;i++) {
        mat4 pair=distortionPair(i/2);
        vec4 center=pair[(i%2)*2];
        vec4 shape=pair[(i%2)*2+1];
        if(center.w<=0.0) break;
        if(any(lessThanEqual(shape.xyz,vec3(0.0)))) continue;
        vec3 viewCenter=(MATRIX_VIEW*vec4(center.xyz,1.0)).xyz;
        float radius=max(1.0/shape.x,max(1.0/shape.y,1.0/shape.z));
        // Reject pixels outside a conservative projected sphere before doing
        // ray/ellipsoid work. Near-plane crossings deliberately keep all pixels.
        if(-viewCenter.z>radius) {
            vec4 clip=MATRIX_PROJECTION*vec4(viewCenter,1.0);
            vec2 screenCenter=clip.xy/clip.w*0.5+0.5;
            float divisor=PROJECTION_MODE==1 ? 1.0 : max(-viewCenter.z-radius,0.0001);
            vec2 perspectiveExpansion=PROJECTION_MODE==1 ? vec2(1.0) : vec2(1.0)+abs(viewCenter.xy)/(-viewCenter.z);
            vec2 screenRadius=abs(vec2(MATRIX_PROJECTION[0][0],MATRIX_PROJECTION[1][1]))*radius*perspectiveExpansion/(2.0*divisor);
            if(any(greaterThan(abs(TEXCOORD-screenCenter),screenRadius))) continue;
        }
        vec3 o=(origin-center.xyz)*shape.xyz;
        vec3 d=ray*shape.xyz;
        float aa=dot(d,d), bb=dot(o,d);
        float discriminant=bb*bb-aa*(dot(o,o)-1.0);
        if(discriminant<=0.0) continue;
        float entry=max(0.0,(-bb-sqrt(discriminant))/aa);
        float exit=(-bb+sqrt(discriminant))/aa;
        float end=min(exit,sceneDistance);
        if(end<=entry) continue;
        float sampleDistance=clamp(-bb/aa,entry,end);
        vec3 q=o+d*sampleDistance;
        float envelope=1.0-smoothstep(0.05,1.0,dot(q,q));
        envelope*=envelope*clamp((end-entry)/max(exit-entry,0.0001),0.0,1.0);
        float phase=shape.w;
        vec2 wave=vec2(sin(q.y*14.0-phase*2.0+sin(q.z*6.0+phase)),
                       sin(q.y*11.0-phase+sin(q.x*7.0-phase*2.0)))*0.72;
        float distanceScale=PROJECTION_MODE==1 ? 1.0 : max(sampleDistance*forward,NEAR_PLANE);
        vec2 offset=wave*envelope*center.w*vec2(MATRIX_PROJECTION[0][0],MATRIX_PROJECTION[1][1])/(2.0*distanceScale);
        if(dot(offset,offset)<1e-18) continue;
        vec2 candidate=TEXCOORD+offset;
        if(any(lessThan(candidate,TEXEL_SIZE*0.5)) || any(greaterThan(candidate,vec2(1.0)-TEXEL_SIZE*0.5))) continue;
        // A neighboring foreground silhouette must not be pulled into the air.
        float entryDepth=entry*forward;
        if(SampleDepth(candidate)+0.001<entryDepth) continue;
        total+=offset;
        foregroundDepth=max(foregroundDepth,entryDepth);
    }
    // Keep overlapping fields subtle and the depth guard local to the footprint.
    vec2 pixels=total/TEXEL_SIZE;
    total*=min(1.0,4.0/max(length(pixels),0.0001));
    vec2 displaced=clamp(TEXCOORD+total,TEXEL_SIZE*0.5,vec2(1.0)-TEXEL_SIZE*0.5);
    if(dot(total,total)>0.0 && SampleDepth(displaced)+0.001>=foregroundDepth) COLOR=SampleColor(displaced);
}
