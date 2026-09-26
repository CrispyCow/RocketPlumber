#version 410

/*  UNIFORMS  */
uniform vec4 particle_colour;

/*  OUTPUTS  */
out vec4 outColor;

void main()
{
    // Simple flat colour for now
    outColor = particle_colour;
}
