#version 410

/*  INPUTS  */
in vec2 atlas_texcoord;
in vec2 local_texcoord;

/*  UNIFORMS  */
uniform sampler2D texunit;
uniform vec4 colour_multiply;
uniform float x_uncliped; // 0.0 to 1.0

/*  OUTPUTS  */
out vec4 outColor;

void main()
{
    if (local_texcoord.x > x_uncliped) {
        // black if clipped
        outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
        // otherwise return colour sampled from texture
        outColor = texture(texunit, atlas_texcoord) * colour_multiply;
    }
}
