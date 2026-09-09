#include <metal_stdlib>
using namespace metal;

struct Particle { float4 position; float4 velocity; };
// Mass-weighted second central moment: diagonal xyz + trace, off-diagonal xy/xz/yz.
struct SecondMoment { float4 diagonal; float4 offDiagonal; };
struct DynamicsUniforms {
    float4 center0, center1, bulk0, bulk1;
    uint count, starCount, galaxyCount, seed;
    float dt, softening, theta;
    uint mode;
    float4 model0, model1, component0, component1;
    uint4 allocation;
};
struct RenderUniforms { float4x4 transform; float4 appearance; };
struct StarVertex { float4 position [[position]]; float size [[point_size]]; float4 color; };

uint hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16);
}
float random01(uint x) { return (float(hash(x) & 0x00ffffffu) + 0.5) / 16777216.0; }
float gaussian(uint x) { return sqrt(-2 * log(max(1e-7, random01(x)))) * cos(2 * M_PI_F * random01(x + 913u)); }
float3 tilted(float3 p, float angle) {
    return float3(p.x, p.y * cos(angle) - p.z * sin(angle), p.y * sin(angle) + p.z * cos(angle));
}
float3 sphere(uint seed) {
    float z = 2 * random01(seed) - 1;
    float phi = 2 * M_PI_F * random01(seed + 1);
    return float3(sqrt(max(0.0, 1 - z * z)) * cos(phi), sqrt(max(0.0, 1 - z * z)) * sin(phi), z);
}
float radiusRow(float radius) { return clamp(log(max(radius, 0.01) / 0.01) / log(6400.0) * 255, 0.0, 254.999); }

kernel void initializeGalaxies(device Particle *p [[buffer(0)]], constant DynamicsUniforms &u [[buffer(1)]],
    const device float *radii [[buffer(2)]], const device float *speeds [[buffer(3)]],
    const device float4 *kinematics [[buffer(4)]], uint id [[thread_position_in_grid]]) {
    if (id >= u.count) return;
    bool halo = id >= u.starCount;
    uint populationCount = halo ? u.count - u.starCount : u.starCount;
    uint populationID = halo ? id - u.starCount : id;
    uint first = halo ? u.allocation.y : u.allocation.x;
    uint galaxy = populationID < first ? 0 : 1;
    uint perGalaxy = galaxy == 0 ? first : populationCount - first;
    uint local = galaxy == 0 ? populationID : populationID - first;
    float4 model = galaxy == 0 ? u.model0 : u.model1;
    float4 component = galaxy == 0 ? u.component0 : u.component1;
    radii += galaxy * 4096;
    speeds += galaxy * 256 * 128;
    kinematics += galaxy * 256;
    uint seed = local / 2 + u.seed * 747796405u + galaxy * 2891336453u + (halo ? 10000019u : 0u);
    float4 center = galaxy == 0 ? u.center0 : u.center1;
    float3 position, velocity;
    if (halo || model.w > 0.5) {
        float q = clamp(random01(seed) * 4096 - 0.5, 0.0, 4094.999);
        uint q0 = uint(q);
        float r = mix(radii[q0], radii[q0 + 1], fract(q));
        position = sphere(seed + 1) * r;
        float row = radiusRow(r), vq = clamp(random01(seed + 3) * 128 - 0.5, 0.0, 126.999);
        uint i = uint(row) * 128 + uint(vq);
        float v0 = mix(speeds[i], speeds[i + 1], fract(vq));
        float v1 = mix(speeds[i + 128], speeds[i + 129], fract(vq));
        velocity = sphere(seed + 4) * mix(v0, v1, fract(row));
    } else {
        float r = 10;
        uint attempt = 0;
        while (r > 7) {
            r = -log(max(1e-8, random01(seed + 31u * attempt) * random01(seed + 31u * attempt + 1)));
            attempt++;
        }
        float angle = random01(seed + 101) * 2 * M_PI_F;
        float zq = clamp(random01(seed + 102), 0.0001, 0.9999);
        float z = component.z * 0.5 * log(zq / (1 - zq));
        float3 radial = float3(cos(angle), sin(angle), 0);
        float3 tangent = float3(-sin(angle), cos(angle), 0);
        float row = radiusRow(r);
        float4 k = mix(kinematics[uint(row)], kinematics[uint(row) + 1], fract(row));
        position = radial * r + float3(0, 0, z);
        velocity = radial * (k.y * gaussian(seed + 110)) + tangent * (model.z * (k.x + k.z * gaussian(seed + 120)))
                 + float3(0, 0, k.w * gaussian(seed + 130));
    }
    float sign = (local & 1u) == 0 ? 1.0 : -1.0;
    position = tilted(position * (sign * model.y), center.w) + center.xyz;
    velocity = tilted(velocity * (sign * sqrt(model.x / model.y)), center.w) + (galaxy == 0 ? u.bulk0.xyz : u.bulk1.xyz);
    p[id].position = float4(position, (halo ? component.y : component.x) * model.x / float(perGalaxy));
    p[id].velocity = float4(velocity, float(galaxy + (halo ? 2 : 0)));
}

kernel void reduceBounds(const device Particle *p [[buffer(0)]], constant DynamicsUniforms &u [[buffer(1)]],
    device float4 *scratch [[buffer(2)]], uint id [[thread_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]], uint group [[threadgroup_position_in_grid]]) {
    threadgroup float3 low[256], high[256];
    low[lane] = id < u.count ? p[id].position.xyz : float3(INFINITY);
    high[lane] = id < u.count ? p[id].position.xyz : float3(-INFINITY);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (lane < stride) { low[lane] = min(low[lane], low[lane + stride]); high[lane] = max(high[lane], high[lane + stride]); }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0) { scratch[group * 2] = float4(low[0], 0); scratch[group * 2 + 1] = float4(high[0], 0); }
}
kernel void finishBounds(const device float4 *scratch [[buffer(0)]], device float4 *bounds [[buffer(1)]],
    constant uint &groups [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id != 0) return;
    float3 lo = float3(INFINITY), hi = float3(-INFINITY);
    for (uint i = 0; i < groups; i++) { lo = min(lo, scratch[i * 2].xyz); hi = max(hi, scratch[i * 2 + 1].xyz); }
    float3 extent = hi - lo;
    float side = max(1.0, max(extent.x, max(extent.y, extent.z)) * 1.0001 + 0.001);
    bounds[0] = float4((lo + hi) * 0.5 - side * 0.5, side);
}
// A compact binary radix tree over (63-bit Morton key, unique particle ID).
// Topology follows Karras, HPG 2012. Each leaf contains exactly one body.
uint2 morton(float3 position, float4 bounds) {
    uint3 cell = uint3(clamp((position - bounds.xyz) * (2097152.0 / bounds.w), 0.0, 2097151.0));
    ulong code = 0;
    for (uint b = 0; b < 21; b++) {
        code |= ulong((cell.x >> b) & 1u) << (3 * b);
        code |= ulong((cell.y >> b) & 1u) << (3 * b + 1);
        code |= ulong((cell.z >> b) & 1u) << (3 * b + 2);
    }
    return uint2(uint(code >> 32), uint(code));
}
kernel void makeKeys(const device Particle *p [[buffer(0)]], constant DynamicsUniforms &u [[buffer(1)]],
    const device float4 *bounds [[buffer(2)]], device uint4 *keys [[buffer(3)]],
    constant uint &capacity [[buffer(4)]], uint id [[thread_position_in_grid]]) {
    if (id >= capacity) return;
    keys[id] = id < u.count ? uint4(morton(p[id].position.xyz, bounds[0]), id, 0) : uint4(UINT_MAX);
}
bool keyLess(uint4 a, uint4 b) { return a.x < b.x || (a.x == b.x && (a.y < b.y || (a.y == b.y && a.z < b.z))); }
kernel void sortKeys(device uint4 *keys [[buffer(0)]], constant uint4 &stage [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id >= stage.z) return;
    uint other = id ^ stage.y;
    if (other <= id) return;
    uint4 a = keys[id], b = keys[other];
    bool ascending = (id & stage.x) == 0;
    if (ascending ? keyLess(b, a) : keyLess(a, b)) { keys[id] = b; keys[other] = a; }
}
int prefix(const device uint4 *keys, int a, int b, int count) {
    if (b < 0 || b >= count) return -1;
    uint4 x = keys[a] ^ keys[b];
    return x.x != 0 ? int(clz(x.x)) : x.y != 0 ? 32 + int(clz(x.y)) : 64 + int(clz(x.z));
}
// links = (left child, right child, first sorted ordinal, last sorted ordinal).
// Parent pointers occupy a separate buffer: no competing struct-wide writes.
kernel void buildTopology(const device uint4 *keys [[buffer(0)]], constant DynamicsUniforms &u [[buffer(1)]],
    device uint4 *links [[buffer(2)]], device uint *parents [[buffer(3)]], device uint *levels [[buffer(4)]],
    uint id [[thread_position_in_grid]]) {
    int n = int(u.count), i = int(id);
    if (i >= n - 1) return;
    int direction = prefix(keys, i, i + 1, n) > prefix(keys, i, i - 1, n) ? 1 : -1;
    int outside = prefix(keys, i, i - direction, n);
    int limit = 2;
    while (prefix(keys, i, i + limit * direction, n) > outside) limit *= 2;
    int length = 0;
    for (int step = limit / 2; step >= 1; step /= 2) {
        if (prefix(keys, i, i + (length + step) * direction, n) > outside) length += step;
    }
    int end = i + length * direction;
    int first = min(i, end), last = max(i, end);
    int common = prefix(keys, first, last, n);
    int split = first, step = last - first;
    do {
        step = (step + 1) / 2;
        int candidate = split + step;
        if (candidate < last && prefix(keys, first, candidate, n) > common) split = candidate;
    } while (step > 1);
    uint left = split == first ? uint(n - 1 + split) : uint(split);
    uint right = split + 1 == last ? uint(n + split) : uint(split + 1);
    links[id] = uint4(left, right, uint(first), uint(last));
    levels[id] = uint(common);
    parents[left] = id; parents[right] = id;
    if (id == 0) parents[0] = UINT_MAX;
}
kernel void initializeLeaves(const device Particle *p [[buffer(0)]], const device uint4 *keys [[buffer(1)]],
    constant DynamicsUniforms &u [[buffer(2)]], device float4 *nodes [[buffer(3)]],
    device float4 *low [[buffer(4)]], device float4 *high [[buffer(5)]],
    device SecondMoment *moments [[buffer(6)]], uint id [[thread_position_in_grid]]) {
    if (id >= u.count) return;
    uint leaf = u.count - 1 + id;
    float4 body = p[keys[id].z].position;
    nodes[leaf] = body;
    moments[leaf] = {float4(0), float4(0)};
    low[leaf] = high[leaf] = float4(body.xyz, 0);
}
kernel void buildEscapes(const device uint4 *links [[buffer(0)]], const device uint *parents [[buffer(1)]],
    constant DynamicsUniforms &u [[buffer(2)]], device uint *escapes [[buffer(3)]], uint id [[thread_position_in_grid]]) {
    if (id >= u.count * 2 - 1) return;
    uint cursor = id, next = UINT_MAX;
    while (cursor != 0) {
        uint parent = parents[cursor];
        uint4 link = links[parent];
        if (link.x == cursor) { next = link.y; break; }
        cursor = parent;
    }
    escapes[id] = next;
}
// A child's common prefix is strictly longer than its parent's. Separate passes
// descending through the 96 key bits provide device-wide visibility without
// spin locks or unsupported acquire/release device atomics.
kernel void refitLevel(const device uint4 *links [[buffer(0)]], const device uint *levels [[buffer(1)]],
    constant DynamicsUniforms &u [[buffer(2)]], constant uint &level [[buffer(3)]],
    device float4 *nodes [[buffer(4)]], device float4 *low [[buffer(5)]], device float4 *high [[buffer(6)]],
    device SecondMoment *moments [[buffer(7)]], uint id [[thread_position_in_grid]]) {
    if (id >= u.count - 1 || levels[id] != level) return;
    uint2 children = links[id].xy;
    float4 a = nodes[children.x], b = nodes[children.y];
    float mass = a.w + b.w;
    float3 separation = a.xyz - b.xyz;
    float reducedMass = a.w * b.w / mass;
    SecondMoment ma = moments[children.x], mb = moments[children.y];
    float3 diagonal = ma.diagonal.xyz + mb.diagonal.xyz + reducedMass * separation * separation;
    float3 off = ma.offDiagonal.xyz + mb.offDiagonal.xyz
        + reducedMass * float3(separation.x * separation.y, separation.x * separation.z, separation.y * separation.z);
    moments[id] = {float4(diagonal, diagonal.x + diagonal.y + diagonal.z), float4(off, 0)};
    nodes[id] = float4((a.xyz * a.w + b.xyz * b.w) / mass, mass);
    float3 lo = min(low[children.x].xyz, low[children.y].xyz);
    float3 hi = max(high[children.x].xyz, high[children.y].xyz);
    // Diagonal of the actual bounding box: conservative for elongated nodes.
    low[id] = float4(lo, dot(hi - lo, hi - lo));
    high[id] = float4(hi, 0);
}
float4 interaction(float3 position, float4 source, float epsilon) {
    float3 d = source.xyz - position;
    float inv = rsqrt(dot(d, d) + epsilon * epsilon);
    return float4(d * (source.w * inv * inv * inv), -source.w * inv);
}
// Second-order Taylor expansion of the SAME Plummer-softened potential.
// The trace term must be retained; an unsoftened traceless formula is incorrect
// when epsilon is nonzero. Leaves continue to use the exact pair interaction.
float4 quadrupoleInteraction(float3 position, float4 source, SecondMoment moment, float epsilon) {
    float3 d = source.xyz - position;
    float inv = rsqrt(dot(d, d) + epsilon * epsilon);
    float inv2 = inv * inv, inv3 = inv * inv2, inv5 = inv3 * inv2;
    float3 diagonal = moment.diagonal.xyz, off = moment.offDiagonal.xyz;
    float trace = moment.diagonal.w;
    float3 cd = diagonal * d + float3(off.x * d.y + off.y * d.z,
                                     off.x * d.x + off.z * d.z,
                                     off.y * d.x + off.z * d.y);
    float q = dot(d, cd);
    float3 acceleration = d * (source.w * inv3 + (7.5 * q * inv2 - 1.5 * trace) * inv5) - 3 * cd * inv5;
    float potential = -source.w * inv - 0.5 * (3 * q * inv2 - trace) * inv3;
    return float4(acceleration, potential);
}
kernel void treeGravity(const device uint4 *keys [[buffer(0)]], constant DynamicsUniforms &u [[buffer(1)]],
    const device uint4 *links [[buffer(2)]], const device uint *escapes [[buffer(3)]], const device float4 *low [[buffer(4)]],
    const device float4 *nodes [[buffer(5)]], device float4 *acceleration [[buffer(6)]],
    constant uint &start [[buffer(7)]], const device SecondMoment *moments [[buffer(8)]],
    uint threadID [[thread_position_in_grid]]) {
    uint ordinal = start + threadID;
    if (ordinal >= u.count) return;
    uint ownLeaf = u.count - 1 + ordinal;
    float3 position = nodes[ownLeaf].xyz;
    float4 force = 0;
    uint index = 0;
    while (index != UINT_MAX) {
        float4 node = nodes[index];
        if (index >= u.count - 1) {
            if (index != ownLeaf) force += interaction(position, node, u.softening);
        } else {
            uint4 link = links[index];
            bool contains = ordinal >= link.z && ordinal <= link.w;
            float size2 = low[index].w;
            float3 delta = node.xyz - position;
            if (!contains && (size2 == 0 || size2 < u.theta * u.theta * dot(delta, delta))) {
                force += quadrupoleInteraction(position, node, moments[index], u.softening);
            } else { index = link.x; continue; }
        }
        index = escapes[index];
    }
    acceleration[keys[ordinal].z] = force;
}
kernel void finishKick(device Particle *p [[buffer(0)]], const device float4 *acceleration [[buffer(1)]],
    constant DynamicsUniforms &u [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id < u.count) p[id].velocity.xyz += acceleration[id].xyz * (u.dt * 0.5);
}
kernel void driftParticles(device Particle *p [[buffer(0)]], const device float4 *acceleration [[buffer(1)]],
    constant DynamicsUniforms &u [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= u.count) return;
    p[id].velocity.xyz += acceleration[id].xyz * (u.dt * 0.5);
    p[id].position.xyz += p[id].velocity.xyz * u.dt;
}
// Small-N independent oracle used only by the validation executable.
kernel void directGravity(const device Particle *p [[buffer(0)]], constant DynamicsUniforms &u [[buffer(1)]],
    device float4 *acceleration [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= u.count) return;
    float4 force = 0;
    for (uint j = 0; j < u.count; j++) if (j != id) force += interaction(p[id].position.xyz, p[j].position, u.softening);
    acceleration[id] = force;
}

// Large-N oracle: exact direct sum for a bounded sample of target particles.
kernel void directGravitySamples(const device Particle *p [[buffer(0)]], constant DynamicsUniforms &u [[buffer(1)]],
    device float4 *result [[buffer(2)]], const device uint *targets [[buffer(3)]],
    constant uint &sampleCount [[buffer(4)]], uint id [[thread_position_in_grid]]) {
    if (id >= sampleCount) return;
    uint target = targets[id];
    float4 force = 0;
    for (uint j = 0; j < u.count; j++) if (j != target) force += interaction(p[target].position.xyz, p[j].position, u.softening);
    result[id] = force;
}

vertex StarVertex starVertex(uint id [[vertex_id]],
                             const device Particle *stars [[buffer(0)]],
                             constant RenderUniforms &u [[buffer(1)]]) {
    Particle p = stars[id];
    StarVertex out;
    out.position = u.transform * float4(p.position.xyz, 1);
    float brightness = random01(id + 173u);
    out.size = (1.25 + pow(brightness, 14.0) * 3.0) * u.appearance.x;
    float3 cool = mix(float3(0.17, 0.45, 0.85), float3(0.76, 0.9, 1.0), brightness * brightness);
    float3 warm = mix(float3(0.85, 0.29, 0.09), float3(1.0, 0.86, 0.61), brightness * brightness);
    bool halo = p.velocity.w >= 2.0;
    float3 color = fmod(p.velocity.w, 2.0) < 0.5 ? cool : warm;
    if (halo) color = mix(color, float3(0.4, 0.45, 0.5), 0.7);
    float emphasis = u.appearance.z > 0.5 && fmod(p.velocity.w, 2.0) < 0.5 ? 0.12 : 1.0;
    out.color = float4(color, u.appearance.y * (halo ? 0.07 : 1.0) * emphasis);
    return out;
}

vertex StarVertex backgroundVertex(uint id [[vertex_id]], constant RenderUniforms &u [[buffer(1)]]) {
    StarVertex out;
    out.position = float4(random01(id * 3 + 710) * 2 - 1, random01(id * 3 + 711) * 2 - 1, 0.99, 1);
    out.size = (0.6 + pow(random01(id * 3 + 712), 14.0) * 1.8) * u.appearance.x;
    out.color = float4(0.4, 0.54, 0.7, 0.32);
    return out;
}

fragment float4 starFragment(StarVertex in [[stage_in]], float2 uv [[point_coord]]) {
    float r = length(uv * 2 - 1);
    float glow = exp(-r * r * 4.5) * (1.0 - smoothstep(0.65, 1.0, r));
    return float4(in.color.rgb, glow * in.color.a);
}

// Accumulate unclipped radiance before compressing it for the display / MP4.
struct ScreenVertex { float4 position [[position]]; float2 uv; };
vertex ScreenVertex fullScreenVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2u, id & 2u);
    return {float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv};
}
fragment float4 toneMapFragment(ScreenVertex in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 radiance = max(source.sample(linearSampler, in.uv).rgb, float3(0));
    return float4(radiance / (1 + radiance), 1);
}
