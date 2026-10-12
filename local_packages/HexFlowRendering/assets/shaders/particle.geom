#version 410

/*  LAYOUT  */
layout(points) in;
layout(triangle_strip, max_vertices = 4) out;

/*  INPUTS  */
in vec2 particle_center[];  // game coordinates from vertex shader
in vec4 vertex_colour[];

/*  OUTPUTS  */
flat out vec4 particle_colour;

/*  UNIFORM BLOCKS  */
layout(std140) uniform ViewBlock {mat3 view_transform;};

/*  UNIFORMS  */
uniform float particle_size;  // size in pixels

void main()
{
    // Get the particle center in game coordinates
    vec2 center = particle_center[0];
    
    // Calculate half the particle size in game units
    float half_size_game_units = particle_size * 0.5;
    
    // Create 4 vertices for the quad in game space, centered at particle position
    vec2 offsets[4] = vec2[4](
        vec2(-half_size_game_units, -half_size_game_units),  // bottom-left
        vec2( half_size_game_units, -half_size_game_units),  // bottom-right
        vec2(-half_size_game_units,  half_size_game_units),  // top-left
        vec2( half_size_game_units,  half_size_game_units)   // top-right
    );
    
    // Emit vertices, applying view transform to each
    for (int i = 0; i < 4; i++) {
        vec2 vertex_game_space = center + offsets[i];
        vec3 vertex_clip_space = view_transform * vec3(vertex_game_space, 1.0);
        gl_Position = vec4(vertex_clip_space.xy, 0.0, 1.0);
        particle_colour = vertex_colour[0];
        EmitVertex();
    }
    
    EndPrimitive();
}
