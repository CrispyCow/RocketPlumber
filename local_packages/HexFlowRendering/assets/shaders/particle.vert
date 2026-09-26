#version 410

/*  INPUTS  */
layout(location = 0) in vec2 position;  // game coordinates

/*  OUTPUTS  */
out vec2 particle_center;  // pass game coordinates to geometry shader

void main()
{
    // Pass the game-space position to the geometry shader
    // We don't apply view transform here - geometry shader will do it
    particle_center = position;
}
