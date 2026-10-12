#version 410

/*  INPUTS  */
flat in vec4 particle_colour;

/*  OUTPUTS  */
out vec4 outColor;

void main()
{
    outColor = particle_colour;
}
