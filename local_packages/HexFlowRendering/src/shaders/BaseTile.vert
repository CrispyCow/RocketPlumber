#version 410

/*  INPUTS  */
layout(location = 0) in vec2 position;
layout(location = 1) in vec2 texcoord;

/*  UNIFORM BLOCKS  */
// standard view transform shared uniform block
layout(std140) uniform ViewBlock {mat3 view_transform;};

/*  UNIFORMS  */
// transform the texcoords from sprite space to that sprites section of the texture atlas space
uniform vec2  uv_offset;
uniform vec2  uv_scale;
// scales and offsets sprite quad to account for sprite size, and offset cropping of transaprent pixels
uniform vec2  sprite_scale;
uniform vec2  sprite_offset;
// sprite rotation applied before scaling and offsetting (for animation effects)
uniform mat2  sprite_rotate;
// rotation and translation of the object in the game map
uniform mat2  object_rotation;
uniform vec2  object_translation; 

/*  OUTPUTS  */
out vec2 local_texcoord;
out vec2 atlas_texcoord;

void main()
{
    // Handle Texcoords
    local_texcoord = texcoord;
    atlas_texcoord = (texcoord * uv_scale) + uv_offset;

    // 1. Apply sprite rotation first, then scale and offset to account for sprite size, cropping and any desired scale effects
    vec2 local_from_quad = ((position * sprite_scale) * sprite_rotate) + sprite_offset;
    // 2. Rotate and translate the object as postioned in the map
    vec2 local_pos = (local_from_quad * object_rotation) + object_translation;

    // 3. View (camera) transform: homogeneous 3x3
    vec3 world_pos = view_transform * vec3(local_pos, 1.0);

    // Output clip-space position
    gl_Position = vec4(world_pos.xy, 0.0, 1.0);
}
