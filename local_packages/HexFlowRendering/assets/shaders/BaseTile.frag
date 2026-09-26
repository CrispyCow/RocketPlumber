#version 410

/*  INPUTS  */
in vec2 atlas_texcoord;
in vec2 local_texcoord;

/*  UNIFORMS  */
uniform sampler2D texunit;
uniform vec4 colour_multiply;
uniform vec2 unclipped_texcoord; // maximum visible local texture coordinate per axis

/*  OUTPUTS  */
out vec4 outColor;

void main()
{
    if (any(greaterThan(local_texcoord, unclipped_texcoord))) {
        // Opaque black preserves the background of basic clipped masks.
        outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
        // otherwise return colour sampled from texture
        outColor = texture(texunit, atlas_texcoord) * colour_multiply;
    }
}
