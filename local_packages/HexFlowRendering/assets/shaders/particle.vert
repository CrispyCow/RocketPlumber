#version 410

/*  INPUTS  */
layout(location = 0) in vec2 position;  // game coordinates
layout(location = 1) in vec4 colour;

/*  OUTPUTS  */
out vec2 particle_center;  // pass game coordinates to geometry shader
out vec4 vertex_colour;

void main()
{
    // Pass the game-space position to the geometry shader
    // We don't apply view transform here - geometry shader will do it
    particle_center = position;
    vertex_colour = colour;
}
