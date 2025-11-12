#version 410

/*  INPUTS  */
in vec2 atlas_texcoord;
in vec2 local_texcoord;

/*  UNIFORMS  */
uniform sampler2D texunit;
uniform vec4 colour_multiply;
uniform float x_uncliped; // 0.0 to 1.0
uniform float gameticks;  // animation driver
uniform vec2 object_translation;

/*  OUTPUTS  */
out vec4 outColor;

/*  CONFIGURABLE CONSTANTS  */
const vec2 noiseBlocks = vec2(100.0, 100.0); // number of noise cells across UV space
const float noiseStrength = 0.15;          // brightness modulation strength
const float changeInterval = 15.0;         // ticks between new patterns (e.g., 15 ticks = 0.25s at 60fps)

// Stronger hash function
float hash(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)),
             dot(p, vec2(269.5, 183.3)));
    return fract(sin(p.x) * 43758.5453 + sin(p.y) * 789221.123);
}

void main()
{
    if (local_texcoord.x > x_uncliped) {
        // black if clipped
        outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
        // Base colour
        vec4 baseColor = texture(texunit, atlas_texcoord) * colour_multiply;

        // Use object position to create unique patterns per tile
        vec2 position_offset = object_translation * 2.47;
        
        // Quantize UVs to create blocky pixels, with position-based offset
        vec2 blockUV = floor((local_texcoord + position_offset) * noiseBlocks);

        // Figure out which "interval" we're in
        float intervalIndex = floor(gameticks / changeInterval);
        float blendFactor   = fract(gameticks / changeInterval); // 0 → 1 over the interval
        
        // Apply smoothstep for smoother transitions (ease-in-ease-out)
        blendFactor = smoothstep(0.0, 1.0, blendFactor);

        // Two seeds: current and next
        float nA = hash(blockUV + vec2(intervalIndex * 13.37, intervalIndex * 0.37));
        float nB = hash(blockUV + vec2((intervalIndex + 1.0) * 7.13, (intervalIndex + 1.0) * 19.97));

        // Interpolate between them with smoothed blend
        float noiseVal = mix(nA, nB, blendFactor);

        // Map noise from [0,1] to brightness multiplier range
        float brightness = 1.0 + (noiseVal - 0.5) * 2.0 * noiseStrength;

        // Apply brightness modulation
        outColor = vec4(baseColor.rgb * brightness, baseColor.a);
    }
}
