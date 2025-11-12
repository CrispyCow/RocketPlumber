#version 410

in vec2 atlas_texcoord;
in vec2 local_texcoord;

uniform sampler2D texunit;
uniform vec4 colour_multiply;
uniform float x_uncliped;
uniform float gameticks;

out vec4 outColor;

const float PI = 3.14159265;

// Frequencies
const float freq1 = 1.9;
const float freq2 = 1.2;
const float freq3 = 3.2;

// Speeds
const float speed1 = 0.8;
const float speed2 = 1.1;
const float speed3 = 0.6;

// Brightness modulation
const float waveStrength = 0.1;

/* ---------------------------
   Simple 2D value noise
   --------------------------- */
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
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
   Smoothly varying angle from noise
   --------------------------- */
float noiseAngle(float t, float seed) {
    // Scale time for slower drift
    float n = noise(vec2(t * 0.1, seed));
    return n * 2.0 * PI; // Map [0,1] → [0, 2π]
}

void main()
{
    if (local_texcoord.x > x_uncliped) {
        outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
        vec4 baseColor = texture(texunit, atlas_texcoord) * colour_multiply;
        float time = gameticks / 60.0;

        // Get smoothly changing angles from noise
        float angle1 = noiseAngle(time, 1.0);
        float angle2 = noiseAngle(time, 2.0);
        float angle3 = noiseAngle(time, 3.0);

        // Convert to direction vectors
        vec2 dir1 = vec2(cos(angle1), sin(angle1));
        vec2 dir2 = vec2(cos(angle2), sin(angle2));
        vec2 dir3 = vec2(cos(angle3), sin(angle3));

        // Waves
        float wave1 = sin(dot(local_texcoord, dir1) * freq1 * 2.0 * PI + time * speed1 * 2.0 * PI);
        float wave2 = sin(dot(local_texcoord, dir2) * freq2 * 2.0 * PI + time * speed2 * 2.0 * PI);
        float wave3 = sin(dot(local_texcoord, dir3) * freq3 * 2.0 * PI + time * speed3 * 2.0 * PI);

        float pattern = (wave1 + wave2 + wave3) / 3.0;
        float brightness = 1.0 + pattern * waveStrength;

        outColor = vec4(baseColor.rgb * brightness, baseColor.a);
    }
}