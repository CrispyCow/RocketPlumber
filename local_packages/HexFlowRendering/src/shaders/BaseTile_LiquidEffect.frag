#version 410

in vec2 atlas_texcoord;
in vec2 local_texcoord;

uniform sampler2D texunit;
uniform vec4 colour_multiply;
uniform float x_uncliped;
uniform float gameticks;
uniform vec2 object_translation;

out vec4 outColor;

const float PI = 3.14159265;

// fBm parameters (compile-time constants)
#define FBM_OCTAVES 3
const float fbmBaseFreq = 2.0;      // Base frequency for fBm
const float fbmSpeed = 0.2;       // Time scaling for fBm animation (slowed 3x from 0.8)
const float fbmMagnitude = 0.4;    // Effect strength (brightness modulation)
const float directionChangeSpeed = 0.2; // How fast the flow direction rotates
const float oscillationFrequency = 0.4; // How fast the velocity oscillates

/* ---------------------------
   Simple 2D value noise
   --------------------------- */
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

/* ---------------------------
   Generate pseudo-random angle from position
   Returns value in range [0, 2*PI]
   --------------------------- */
float hash_angle(vec2 p) {
    return hash(p) * 2.0 * PI;
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);

    // Four corners
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    // Smooth interpolation
    vec2 u = f * f * (3.0 - 2.0 * f);

    return mix(a, b, u.x) +
           (c - a) * u.y * (1.0 - u.x) +
           (d - b) * u.x * u.y;
}

/* ---------------------------
   Fractal Brownian Motion (3 octaves, compile-time unrolled)
   Returns normalized value approximately in range [-1, 1]
   --------------------------- */
float fbm(vec2 p, float time_offset) {
    // Pre-computed normalization factor for 3 octaves: 2*(1 - 2^(-3)) = 1.75
    const float total_amplitude = 1.75;
    
    float value = 0.0;
    
    // Octave 1: amplitude = 1.0, frequency = fbmBaseFreq
    value += 1.0 * noise(p * fbmBaseFreq + time_offset);
    
    // Octave 2: amplitude = 0.5, frequency = fbmBaseFreq * 2
    value += 0.5 * noise(p * (fbmBaseFreq * 2.0) + time_offset * 1.3);
    
    // Octave 3: amplitude = 0.25, frequency = fbmBaseFreq * 4
    value += 0.25 * noise(p * (fbmBaseFreq * 4.0) + time_offset * 1.7);
    
    // Normalize to approximately [-1, 1] and convert noise [0,1] to [-1,1]
    return (value / total_amplitude) * 2.0 - 1.0;
}

void main()
{
    if (local_texcoord.x > x_uncliped) {
        outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
        vec4 baseColor = texture(texunit, atlas_texcoord) * colour_multiply;
        float time = gameticks / 60.0;

        // Use object position to offset the noise pattern uniquely per tile
        vec2 position_offset = object_translation * 2.47;
        
        // Generate a base flow direction unique to this tile that slowly rotates
        float current_angle = hash_angle(object_translation * 0.1) + time * directionChangeSpeed;
        vec2 flow_direction = vec2(cos(current_angle), sin(current_angle));
        
        // Create oscillating velocity: sin gives values from -1 to +1
        // Each tile has a unique phase offset based on position
        float phase_offset = hash(object_translation * 0.1) * 2.0 * PI;
        float oscillating_velocity = sin(time * oscillationFrequency + phase_offset);
        
        // Apply oscillating movement in the current direction
        vec2 oscillating_offset = flow_direction * (oscillating_velocity * fbmSpeed);
        
        // Generate fBm pattern with oscillating motion in rotating direction
        float fbm_pattern = fbm(local_texcoord + position_offset + oscillating_offset, 0.0);
        
        // Apply brightness modulation
        float brightness = 1.0 + fbm_pattern * fbmMagnitude;
        
        outColor = vec4(baseColor.rgb * brightness, baseColor.a);
    }
}
