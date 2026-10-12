#=
Scope: Game-specific rendering helpers, programs, particles, and animation
Formatter: Runic
=#

module HexFlowRendering

#= Dependencies =#
# Packages
using ModernGL, TimerOutputs, RelocatableFolders
using StaticArrays, CSyntax.CRef, Accessors
using ColorSchemes, ColorTypes
using PNGFiles
# Custom Packages
using RenderEngine, HexFlowTelemetry, TypeGroupedDicts
using HexFrame, HexFluids, HexComponentsAPI, FlowEngine, FlowMap, HexFlowControl
import RenderEngine.uniforms_type
import RenderEngine.get_vao_symbol

#= Exports =#
# Type exports
export ColourType
export BaseSpriteRenderProgram, BaseSpriteUniforms
export LiquidSpriteRenderProgram, LiquidSpriteUniforms
export GasSpriteRenderProgram, GasSpriteUniforms
export ParticleRenderProgram, ParticleUniforms
export SpriteRenderCommand
export Particle, ParticleManager

# Function exports
export get_fluid_colour
export viewtransform_glubo_init, set_view_ubo
export texatlas1_gltex_init
export basesprite_glprog_init, liquidsprite_glprog_init, gassprite_glprog_init
export particle_glprog_init
export setup_basesprite_uniforms
export render_basic_sprite, render_basic_tile, render_basic_pipe
export render_beam!
export render_liquid_sprite, render_gas_sprite, render_liquid_tile, render_gas_tile
export render_pipe
export tile_queued_render!, node_queued_render!, pipe_queued_render!, ship_surface_queued_render!
export tile_particle_spawn!
export spawn_particle!, spawn_particles!, update_particle_physics!
export thrust_dust_particle_effect!, render_particles!
export get_particle_accel_scale, set_particle_accel_scale!
export animation_sprite_picker, animation_vibe_offset, animation_rotate
export shader_dir, texture_atlas_dir

# Const exports
export hex_size_pixels # used in interactions.jl for view transform
export DEFAULT_EMPTY_FLUID_COLOUR

#= Package-owned runtime resources =#
const SHADER_DIR = @path joinpath(@__DIR__, "..", "assets", "shaders")
const TEXTURE_ATLAS_DIR = @path joinpath(@__DIR__, "..", "assets", "texture_atlas")

"Return the package-owned shader resource directory."
shader_dir() = String(SHADER_DIR)

"Return the package-owned texture-atlas resource directory."
texture_atlas_dir() = String(TEXTURE_ATLAS_DIR)

#= ---------- Particle Acceleration Tuning ----------- =#

const _particle_accel_scale = Threads.Atomic{Float64}(0.2)

"Visual scaling factor applied to ship acceleration when drifting particles."
get_particle_accel_scale()::Float64 = _particle_accel_scale[]

"Set the visual scaling factor for particle acceleration drift."
function set_particle_accel_scale!(value::Float64)
    _particle_accel_scale[] = value
    return nothing
end

#= Basic Constants and Helper Functions =#
const ColourType = SVector{4, Float32}
const hex_size_pixels = 256
const hex_width, hex_height = 2, sqrt(3)
const pipe_length, pipe_thickness = 1, 0.1
const VIEW_BLOCK_BINDING::GLuint = 0
const DEFAULT_PIPE_COLOUR::ColourType = ColourType(0.1, 0.1, 0.1, 1.0)
const DEFAULT_EMPTY_FLUID_COLOUR::ColourType = ColourType(0.0, 0.0, 0.0, 1.0)  # Default colour for empty/unknown fluids (opaque black)

const NODE_VOLTAGE_COLORSCHEME = ColorSchemes.inferno  # Color scheme for node voltage/pressure visualization

#= Render height layers (see src/render_height.md) =#
const RENDER_HEIGHT_BACKGROUND::Int32 = -1000
const RENDER_HEIGHT_PIPE_RANK_MULTIPLIER::Int32 = 10  # spacing between pipe stacking ranks
const RENDER_HEIGHT_PIPE_BASE::Int32 = -10             # legacy flat pipe layer beneath RENDER_HEIGHT_PIPE
const RENDER_HEIGHT_PIPE::Int32 = 0                    # legacy flat pipe layer; rank-based pipes use RENDER_HEIGHT_PIPE_RANK_MULTIPLIER
const RENDER_HEIGHT_NODE::Int32 = 100000               # nodes drawn above pipes and components, below overlays
const RENDER_HEIGHT_COMPONENT_BEHIND::Int32 = 1000    # for parts sitting behind main sprites (fluidmasks, energy bars)
const RENDER_HEIGHT_COMPONENT_STATIC::Int32 = 2000    # static elements of component sprite
const RENDER_HEIGHT_COMPONENT_ANIM::Int32 = 3000      # animated effects drawn over static elements
const RENDER_HEIGHT_OVERLAY_BASE::Int32 = 101000      # overlays, e.g., stall overlay
const RENDER_HEIGHT_TRACTOR_BEAM::Int32 = RENDER_HEIGHT_BACKGROUND - 100  # tractor beam visuals, deep background

"RGB the fluid colour fades toward at the ambient (cold) end of the temperature scale."
const FLUID_COLD_FLOOR_RGB::SVector{3, Float32} = SVector{3, Float32}(0.08, 0.08, 0.08)

const fluid_colour_lookup = Dict{FluidType, ColourType}(
    HexFluids.MONOPROP_LIQUID => ColourType(0.608, 0.169, 0.69, 1.0), # purple
    HexFluids.MONOPROP_GAS => ColourType(0.737, 0.569, 0.769, 1.0), # light purple
    HexFluids.COLD_GAS => ColourType(0.71, 0.918, 0.929, 1.0), # light blue
    HexFluids.FUEL_LIQUID => ColourType(0.95, 0.65, 0.1, 1.0), # orange-yellow
    HexFluids.OXIDISER_LIQUID => ColourType(0.15, 0.55, 0.95, 1.0), # vivid medium blue
    HexFluids.BIPROP_EXHAUST => ColourType(1.0, 0.6, 0.1, 1.0), # orange-white flame
)

"Returns GLfloat RGBA colour from a FluidType, or default if fluid is nothing or not found."
function get_fluid_colour(fluid::Union{FluidType, Nothing}; default::ColourType = DEFAULT_EMPTY_FLUID_COLOUR)::ColourType
    isnothing(fluid) && return default
    return get(fluid_colour_lookup, fluid, default)
end

"Temperature-aware variant: lerps between FLUID_COLD_FLOOR_RGB at ambient and the reference colour at the fluid's reference temperature. Fluids without a defined reference temperature (or whose reference equals ambient) return the unscaled colour, so callers can pass temperature unconditionally."
function get_fluid_colour(
        fluid::Union{FluidType, Nothing}, temperature::Float64;
        default::ColourType = DEFAULT_EMPTY_FLUID_COLOUR
    )::ColourType
    isnothing(fluid) && return default
    base = get(fluid_colour_lookup, fluid, default)
    t_ref = HexFluids.lookup_fluid_reference_temperature(fluid)
    t_amb = HexFluids.THERMAL_AMBIENT_TEMPERATURE_K
    (isnothing(t_ref) || t_ref <= t_amb) && return base
    t = clamp((temperature - t_amb) / (t_ref - t_amb), 0.0, 1.0)
    rgb = FLUID_COLD_FLOOR_RGB .+ Float32(t) .* (SVector{3, Float32}(base[1], base[2], base[3]) .- FLUID_COLD_FLOOR_RGB)
    return ColourType(rgb[1], rgb[2], rgb[3], base[4])
end

"Loads shader source code from the shaders subdirectory."
function grab_shader(name::String)
    return read(joinpath(shader_dir(), name), String)
end

"Load the main texture-atlas PNG with the direct PNG-only runtime path."
function load_texatlas1_png(atlas_dir::AbstractString = texture_atlas_dir())
    return PNGFiles.load(joinpath(atlas_dir, "TileTextureAtlas1.png"))
end

#= Shared OpenGL Objects =#

"Initializes the view transformation uniform buffer object."
function viewtransform_glubo_init(map::GLObjectMap)
    return setup_glubo!(map, :ViewTransform_UBO, 48, 1, "ViewBlock")
end

"Sets the view transformation matrix in the UBO, packed for std140 layout (3 columns of vec4)."
function set_view_ubo(map::GLObjectMap, viewT::SMatrix{3, 3, Float32})
    # std140 pads each column of a mat3 to vec4 (4 floats with trailing zero)
    packed_view = SVector{12, Float32}(
        viewT[1, 1], viewT[2, 1], viewT[3, 1], 0.0f0,
        viewT[1, 2], viewT[2, 2], viewT[3, 2], 0.0f0,
        viewT[1, 3], viewT[2, 3], viewT[3, 3], 0.0f0,
    )
    return set_ubo(map, :ViewTransform_UBO, packed_view)
end

"Initializes the main texture atlas and loads sprite metadata."
function texatlas1_gltex_init(map::GLObjectMap)
    texname = :TileTextureAtlas1
    atlas_dir = texture_atlas_dir()
    texdata = load_texatlas1_png(atlas_dir)
    setup_gltex!(map, texname, texdata)
    return setup_glsprite!(map, texname, atlas_dir)
end

#= Render Program Definitions and setup =#

"Base sprite rendering program for general-purpose textured sprites."
struct BaseSpriteRenderProgram <: AbstractRenderProgram end
@kwdef struct BaseSpriteUniforms <: AbstractRenderUniforms{BaseSpriteRenderProgram}
    uv_offset::SVector{2, GLfloat}
    uv_scale::SVector{2, GLfloat}
    sprite_scale::SVector{2, GLfloat}  # Precomputed: (cropped_size_px .* (1/hex_size_pixels)) * user_scale
    sprite_offset::SVector{2, GLfloat}  # Precomputed translation in hex units to re-center the cropped sprite
    sprite_rotate::SMatrix{2, 2, GLfloat, 4}  # Sprite rotation applied before scaling and offsetting (for animation)
    object_rotation::SMatrix{2, 2, GLfloat, 4}
    object_translation::SVector{2, GLfloat}
    texunit::GLint
    colour_multiply::SVector{4, GLfloat}
    unclipped_texcoord::SVector{2, GLfloat}
end
uniforms_type(::Type{BaseSpriteRenderProgram}) = BaseSpriteUniforms
get_vao_symbol(::BaseSpriteRenderProgram) = :UnitQuad_VAO

"Helper function to initialize sprite-based rendering programs with shared VAO setup."
function basesprite_init_helper(map::GLObjectMap, prog::AbstractRenderProgram, vertname::String, fragname::String)
    tilevert = grab_shader(vertname)
    tilefrag = grab_shader(fragname)
    tilelayout = [
        VboAttribFormat(:position, 2, GL_FLOAT, GL_FALSE),
        VboAttribFormat(:texcoord, 2, GL_FLOAT, GL_FALSE),
    ]
    setup_glprog!(map, prog, tilevert, tilefrag, tilelayout)
    bind_ubo(map, typeof(prog)(), :ViewTransform_UBO)

    # Unit quad centered at origin, positions in [-0.5, 0.5], texcoords top-left origin
    positions = SVector{2, Float32}[
        (-0.5f0, 0.5f0),   # top-left
        (0.5f0, 0.5f0),   # top-right
        (0.5f0, -0.5f0),   # bottom-right
        (-0.5f0, -0.5f0),    # bottom-left
    ]
    elements = SVector{3, UInt32}[
        (0, 1, 2),
        (2, 3, 0),
    ]
    texcoords = SVector{2, Float32}[
        (0, 1),
        (1, 1),
        (1, 0),
        (0, 0),
    ]
    interleaved_buffer = [vcat(p, t) for (p, t) in zip(positions, texcoords)]
    flat_buffer = collect(vcat(interleaved_buffer...))
    flat_elements = reduce(vcat, elements)
    return setup_static_glvao!(map, typeof(prog)(), :UnitQuad_VAO, flat_buffer, flat_elements)
end

"Initializes the base sprite rendering program."
function basesprite_glprog_init(map::GLObjectMap)
    return basesprite_init_helper(map, BaseSpriteRenderProgram(), "BaseTile.vert", "BaseTile.frag")
end

"Liquid sprite rendering program with animated liquid shader effects."
struct LiquidSpriteRenderProgram <: AbstractRenderProgram end

@kwdef struct LiquidSpriteUniforms <: AbstractRenderUniforms{LiquidSpriteRenderProgram}
    uv_offset::SVector{2, GLfloat}
    uv_scale::SVector{2, GLfloat}
    sprite_scale::SVector{2, GLfloat}
    sprite_offset::SVector{2, GLfloat}
    sprite_rotate::SMatrix{2, 2, GLfloat, 4}
    object_rotation::SMatrix{2, 2, GLfloat, 4}
    object_translation::SVector{2, GLfloat}
    texunit::GLint
    colour_multiply::SVector{4, GLfloat}
    unclipped_texcoord::SVector{2, GLfloat}
    gameticks::GLfloat
end
uniforms_type(::Type{LiquidSpriteRenderProgram}) = LiquidSpriteUniforms
get_vao_symbol(::LiquidSpriteRenderProgram) = :UnitQuad_VAO

"Gas sprite rendering program with animated gas shader effects."
struct GasSpriteRenderProgram <: AbstractRenderProgram end

@kwdef struct GasSpriteUniforms <: AbstractRenderUniforms{GasSpriteRenderProgram}
    uv_offset::SVector{2, GLfloat}
    uv_scale::SVector{2, GLfloat}
    sprite_scale::SVector{2, GLfloat}
    sprite_offset::SVector{2, GLfloat}
    sprite_rotate::SMatrix{2, 2, GLfloat, 4}
    object_rotation::SMatrix{2, 2, GLfloat, 4}
    object_translation::SVector{2, GLfloat}
    texunit::GLint
    colour_multiply::SVector{4, GLfloat}
    unclipped_texcoord::SVector{2, GLfloat}
    gameticks::GLfloat
end
uniforms_type(::Type{GasSpriteRenderProgram}) = GasSpriteUniforms
get_vao_symbol(::GasSpriteRenderProgram) = :UnitQuad_VAO

"Concrete union of all queued sprite render commands. Enables isbits inline vector storage."
const SpriteRenderCommand = Union{
    RenderCommand{BaseSpriteRenderProgram, BaseSpriteUniforms},
    RenderCommand{LiquidSpriteRenderProgram, LiquidSpriteUniforms},
    RenderCommand{GasSpriteRenderProgram, GasSpriteUniforms},
}

"Initializes the liquid sprite rendering program."
function liquidsprite_glprog_init(map::GLObjectMap)
    return basesprite_init_helper(map, LiquidSpriteRenderProgram(), "BaseTile.vert", "BaseTile_LiquidEffect.frag")
end

"Initializes the gas sprite rendering program."
function gassprite_glprog_init(map::GLObjectMap)
    return basesprite_init_helper(map, GasSpriteRenderProgram(), "BaseTile.vert", "BaseTile_GasEffect.frag")
end

"Particle rendering program using geometry shader for billboarded quads."
struct ParticleRenderProgram <: AbstractRenderProgram end
@kwdef struct ParticleUniforms <: AbstractRenderUniforms{ParticleRenderProgram}
    particle_size::GLfloat
end
uniforms_type(::Type{ParticleRenderProgram}) = ParticleUniforms

"Initializes the particle rendering program with geometry shader and dynamic VAO."
function particle_glprog_init(map::GLObjectMap)
    vert_code = grab_shader("particle.vert")
    geom_code = grab_shader("particle.geom")
    frag_code = grab_shader("particle.frag")

    layout = [
        VboAttribFormat(:position, 2, GL_FLOAT, GL_FALSE),
        VboAttribFormat(:colour, 4, GL_FLOAT, GL_FALSE),
    ]

    setup_glprog!(map, ParticleRenderProgram(), vert_code, frag_code, geom_code, layout)
    bind_ubo(map, ParticleRenderProgram(), :ViewTransform_UBO)

    setup_dynamic_glvao!(map, ParticleRenderProgram(), :Particles_VAO, PARTICLE_VAO_MAX_COUNT, GL_DYNAMIC_DRAW)

    return nothing
end

#= Rendering Helper Functions =#

"Generate a subtle colour tint for a ship surface based on its name (deterministic hash)"
function get_ship_surface_colour(ship_name::Symbol)::SVector{4, Float32}
    # Primary ship gets pure white (no tint)
    if ship_name == :primary
        return SVector{4, Float32}(1.0f0, 1.0f0, 1.0f0, 1.0f0)
    end

    # Hash the ship name to get deterministic pseudo-random values
    h = hash(ship_name)

    # Extract components from hash for noticeable grey/brown variation
    # Range: 0.50 to 0.75 for clearly distinct non-primary appearance
    r_base = 0.5f0 + 0.25f0 * Float32((h & 0xFF) / 255)
    g_base = 0.5f0 + 0.25f0 * Float32(((h >> 8) & 0xFF) / 255)
    b_base = 0.5f0 + 0.25f0 * Float32(((h >> 16) & 0xFF) / 255)

    # Bias towards grey/brown by reducing blue slightly and keeping r >= g
    r = clamp(r_base, 0.53f0, 0.75f0)
    g = clamp(g_base * 0.98f0, 0.5f0, 0.72f0)
    b = clamp(b_base * 0.9f0, 0.45f0, 0.68f0)

    return SVector{4, Float32}(r, g, b, 1.0f0)
end

"Pale bright green tint applied to the selected ship's surface tiles."
const SHIP_SELECTED_TINT = SVector{4, Float32}(0.7f0, 1.0f0, 0.7f0, 1.0f0)

"""
Compute the shared sprite uniforms used by all sprite renderers.

`unclipped_texcoord` gives the maximum visible local texture coordinate on each
axis. Values are expected in the range 0 to 1, with `(1, 1)` disabling clipping.
The result is a `BaseSpriteUniforms` value so animated renderers can copy the
shared fields into their specialised uniform structs.
"""
function setup_basesprite_uniforms(
        glmap::GLObjectMap, sprite::Symbol, rotation_matrix::SMatrix{2, 2, GLfloat}, position::SVector{2, Float32};
        colour::SVector{4, Float32} = SVector{4, Float32}(1.0, 1.0, 1.0, 1.0),
        scale::AbstractFloat = 1.0,
        transparency::AbstractFloat = 1.0,
        unclipped_texcoord::SVector{2, <:AbstractFloat} = SVector{2, Float32}(1.0, 1.0),
        sprite_offset_tweak_px::SVector{2, <:AbstractFloat} = SVector{2, Float32}(0.0, 0.0),
        sprite_rotation_tweak_mat::SMatrix{2, 2, GLfloat} = SMatrix{2, 2, GLfloat}(1, 0, 0, 1)
    )
    sprite_data = getdata_glsprite(glmap, sprite)

    pixels_to_hex = 1 / float(hex_size_pixels)

    # Convert sprite size from pixels to hex units and apply scale
    sprite_px = SVector{2}(sprite_data.cropped_size_px...)
    sprite_scale = (sprite_px .* pixels_to_hex) .* GLfloat(scale)

    # Compute sprite offset: crop offset plus optional tweaks, converted to hex units
    raw_co = sprite_data.crop_offset_px
    crop_px = SVector{2}(raw_co...)
    tweak_px = SVector{2, Float32}(sprite_offset_tweak_px...)
    sprite_offset = ((crop_px .+ tweak_px) .* pixels_to_hex) .* GLfloat(scale)

    # Fold transparency into colour alpha channel
    final_transparency = GLfloat(transparency) * colour[4]
    colour_out = setindex(colour, final_transparency, 4)

    return BaseSpriteUniforms(
        uv_offset = sprite_data.uv_offset,
        uv_scale = sprite_data.uv_scale,
        sprite_scale = SVector{2, GLfloat}(GLfloat.(sprite_scale)),
        sprite_offset = sprite_offset,
        sprite_rotate = sprite_rotation_tweak_mat,
        object_rotation = rotation_matrix,
        object_translation = position,
        texunit = getdata_gltex(glmap, sprite_data.texname).tex_unit,
        colour_multiply = colour_out,
        unclipped_texcoord = SVector{2, GLfloat}(unclipped_texcoord)
    )
end


"Returns a RenderCommand for a basic sprite at the given position and rotation matrix."
function render_basic_sprite(
        glmap::GLObjectMap, sprite::Symbol, rotation_matrix::SMatrix{2, 2, GLfloat}, position;
        pos_offset = nothing,
        draw_height::Int32 = RENDER_HEIGHT_OVERLAY_BASE,
        kwargs...
    )::RenderCommand
    posvec = position isa SVector{2, Float32} ? position : glvec(position)
    # Apply position offset if provided
    if !isnothing(pos_offset)
        offset_vec = glvec(pos_offset)
        posvec = posvec .+ offset_vec
    end
    base_uniforms = setup_basesprite_uniforms(glmap, sprite, rotation_matrix, posvec; kwargs...)

    return RenderCommand(base_uniforms, draw_height)
end

"Returns a RenderCommand for a basic tile sprite at the given position and rotation."
function render_basic_tile(
        glmap::GLObjectMap, sprite::Symbol, rotation::HexAxis, position::TileCoord;
        mirrored::Bool = false,
        pos_offset = nothing,
        kwargs...
    )::RenderCommand
    return render_basic_sprite(glmap, sprite, tile_orientation_matrix(rotation, mirrored), position; pos_offset = pos_offset, kwargs...)
end

"Returns a RenderCommand for a basic pipe sprite at the given pipe segment position."
function render_basic_pipe(
        glmap::GLObjectMap, sprite::Symbol, position::PipeCoord;
        pos_offset = nothing,
        kwargs...
    )::RenderCommand
    rotation_matrix = get_rotmat(position)'
    position_vec = glvec(position)
    return render_basic_sprite(glmap, sprite, rotation_matrix, position_vec; pos_offset = pos_offset, kwargs...)
end

"Returns a RenderCommand for a basic pipe sprite at the given pipe segment position."
function render_basic_pipe(
        glmap::GLObjectMap, sprite::Symbol, rotation::HexAxis, position::PipeCoord;
        pos_offset = nothing,
        kwargs...
    )::RenderCommand
    return render_basic_pipe(glmap, sprite, position; pos_offset = pos_offset, kwargs...)
end


"Returns a RenderCommand for a sprite with animated liquid effect."
function render_liquid_sprite(
        glmap::GLObjectMap, sprite::Symbol, rotation_matrix::SMatrix{2, 2, GLfloat}, position;
        pos_offset = nothing,
        gameticks::Integer = 0,
        draw_height::Int32 = RENDER_HEIGHT_COMPONENT_BEHIND,
        kwargs...
    )::RenderCommand
    posvec = position isa SVector{2, Float32} ? position : glvec(position)
    # Apply position offset if provided
    if !isnothing(pos_offset)
        offset_vec = glvec(pos_offset)
        posvec = posvec .+ offset_vec
    end
    base = setup_basesprite_uniforms(glmap, sprite, rotation_matrix, posvec; kwargs...)

    u = LiquidSpriteUniforms(
        uv_offset = base.uv_offset,
        uv_scale = base.uv_scale,
        sprite_scale = base.sprite_scale,
        sprite_offset = base.sprite_offset,
        sprite_rotate = base.sprite_rotate,
        object_rotation = base.object_rotation,
        object_translation = base.object_translation,
        texunit = base.texunit,
        colour_multiply = base.colour_multiply,
        unclipped_texcoord = base.unclipped_texcoord,
        gameticks = GLfloat(gameticks)
    )
    return RenderCommand(u, draw_height)
end

"Returns a RenderCommand for a sprite with animated gas effect."
function render_gas_sprite(
        glmap::GLObjectMap, sprite::Symbol, rotation_matrix::SMatrix{2, 2, GLfloat}, position;
        pos_offset = nothing,
        gameticks::Integer = 0,
        draw_height::Int32 = RENDER_HEIGHT_COMPONENT_BEHIND,
        kwargs...
    )::RenderCommand
    posvec = position isa SVector{2, Float32} ? position : glvec(position)
    # Apply position offset if provided
    if !isnothing(pos_offset)
        offset_vec = glvec(pos_offset)
        posvec = posvec .+ offset_vec
    end
    base = setup_basesprite_uniforms(glmap, sprite, rotation_matrix, posvec; kwargs...)

    u = GasSpriteUniforms(
        uv_offset = base.uv_offset,
        uv_scale = base.uv_scale,
        sprite_scale = base.sprite_scale,
        sprite_offset = base.sprite_offset,
        sprite_rotate = base.sprite_rotate,
        object_rotation = base.object_rotation,
        object_translation = base.object_translation,
        texunit = base.texunit,
        colour_multiply = base.colour_multiply,
        unclipped_texcoord = base.unclipped_texcoord,
        gameticks = GLfloat(gameticks)
    )
    return RenderCommand(u, draw_height)
end

"Returns a RenderCommand for a basic tile sprite with animated liquid effect."
function render_liquid_tile(
        glmap::GLObjectMap, sprite::Symbol, rotation::HexAxis, position::AbstractBasicCoordSystem, gameticks::Integer;
        mirrored::Bool = false,
        pos_offset = nothing,
        kwargs...
    )::RenderCommand
    return render_liquid_sprite(glmap, sprite, tile_orientation_matrix(rotation, mirrored), position; pos_offset = pos_offset, gameticks = gameticks, kwargs...)
end

"Returns a RenderCommand for a basic tile sprite with animated gas effect."
function render_gas_tile(
        glmap::GLObjectMap, sprite::Symbol, rotation::HexAxis, position::AbstractBasicCoordSystem, gameticks::Integer;
        mirrored::Bool = false,
        pos_offset = nothing,
        kwargs...
    )::RenderCommand
    return render_gas_sprite(glmap, sprite, tile_orientation_matrix(rotation, mirrored), position; pos_offset = pos_offset, gameticks = gameticks, kwargs...)
end

"Render a dotted beam between two coordinates using repeated sprites with animated noise."
function render_beam!(
        queue::Vector{<:RenderCommand},
        glmap::GLObjectMap,
        gameticks::Int64,
        start_coord,
        end_coord;
        num_elements::Int = 50,
        noise_magnitude::Float64 = 0.1,
        scale::Float32 = 1.0f0,
        colour::ColourType = ColourType(1.0f0, 1.0f0, 1.0f0, 1.0f0),
        draw_height::Int32 = Int32(RENDER_HEIGHT_TRACTOR_BEAM)
    )
    num_elements <= 0 && return nothing

    start_cart = convert(CartesianCoord, start_coord)
    end_cart = convert(CartesianCoord, end_coord)

    dx = end_cart.x - start_cart.x
    dy = end_cart.y - start_cart.y

    steps = max(num_elements - 1, 1)
    base_uniforms = setup_basesprite_uniforms(
        glmap, :MoveArrow_arrow_start, rotmat_2D(0.0), glvec(start_cart);
        colour = colour, scale = scale
    )

    for i in 0:(num_elements - 1)
        t = i / steps
        # Per-element vibing - use a hash of the index to produce a unique deterministic seed per element
        # Constrain the hash to a small positive integer to avoid platform-dependent signed/unsigned issues
        idx_hash = Int64(UInt(hash(i)) % UInt(1_000_000))
        noise_x, noise_y = animation_vibe_offset(gameticks + idx_hash; magnitude = noise_magnitude)
        x = start_cart.x + dx * t + noise_x
        y = start_cart.y + dy * t + noise_y
        uniforms = @set base_uniforms.object_translation = glvec(CartesianCoord(x, y))
        push!(queue, RenderCommand(uniforms, draw_height))
    end

    return nothing
end

#= Queued Render Functions =#

"Height offset applied to animating ships so their full render stack sits above stationary overlays."
const ANIMATING_SHIP_RENDER_HEIGHT_OFFSET = Int32(1_500_000_000)

"Return the per-ship render height offset: non-zero only while the ship is in a transitional docking state."
function _ship_render_height_offset(ship::ShipState)::Int32
    status = get_docking_status(ship)
    return (status isa ConnectedDockStat) ? Int32(0) : ANIMATING_SHIP_RENDER_HEIGHT_OFFSET
end

"Map a base draw height into the correct per-ship layer."
_ship_draw_height(ship::ShipState, base_height::Integer)::Int32 = Int32(base_height) + _ship_render_height_offset(ship)

"Map a base draw height into the correct per-ship layer when only the owning ship name is available."
function _ship_draw_height(gamemap::GameMap, ship_name::Union{Nothing, Symbol}, base_height::Integer)::Int32
    isnothing(ship_name) && return Int32(base_height)
    return _ship_draw_height(get_ship_state(gamemap, ship_name), base_height)
end

"Renders all tile components in the gamemap by iterating the global components dict with per-ship offset/height lookup."
function tile_queued_render!(
        queue::Vector{<:RenderCommand}, map::GLObjectMap,
        gamemap::GameMap, derivedmapstate::DerivedMapState,
        mna_state::MNA_StateSnapshot, gamestate::GameState
    )
    isempty(gamemap.ships) && return nothing

    foreachpair(gamemap.components) do coord, tilecomp
        ship_state = get_ship_state(gamemap, tilecomp.ship)
        render_map_elem!(
            queue, tilecomp;
            glmap = map, mna_state, derivedmapstate,
            gameticks = gamestate.ticks, position = coord,
            pos_offset = get_render_offset(ship_state),
            render_height_offset = _ship_render_height_offset(ship_state),
        )
        return nothing
    end
    return nothing
end

"Renders all node vertices with colours based on MNA voltage/pressure values."
function node_queued_render!(queue::Vector{<:RenderCommand}, map::GLObjectMap, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot)
    for node in keys(derivedmapstate.primarynodes)
        if !is_axis(node.dir)  # Skip if node isn't a vertex
            continue
        end

        # Determine colour based on MNA voltage, falling back to 0.0 for missing/invalid values
        voltage_clamped = if haskey(mna_state.node_voltages_scaled, node)
            vs = mna_state.node_voltages_scaled[node]
            vs = isfinite(vs) ? vs : 0.0  # Handle NaN/infinite values
            clamp(Float32(vs), 0.0f0, 1.0f0)
        else
            0.0
        end
        c = get(NODE_VOLTAGE_COLORSCHEME, voltage_clamped)
        colour = SVector{4, Float32}(Float32(c.r), Float32(c.g), Float32(c.b), 1.0f0)

        # Get ship offset for this node
        ship_name = find_ship_for_node(node, gamemap)
        ship_offset = get_ship_render_offset(gamemap, ship_name)
        node_height = _ship_draw_height(gamemap, ship_name, RENDER_HEIGHT_NODE)

        position = glvec(node)
        # Apply position offset
        if ship_offset != AxialCoord(0.0, 0.0)
            offset_vec = glvec(ship_offset)
            position = position .+ offset_vec
        end
        rotation_matrix = hex_rotmats[HexFrame.Q_POS]

        # Render pressure mask with voltage colour
        push!(
            queue, render_basic_sprite(
                map, :Node_pressuremask, rotation_matrix, position;
                colour = colour, transparency = 1.0, draw_height = node_height
            )
        )

        # Render frame on top
        push!(
            queue, render_basic_sprite(
                map, :Node_frame, rotation_matrix, position;
                draw_height = node_height + Int32(10)
            )
        )
    end
    return nothing
end

"Renders all pipe behaviors in the gamemap by iterating the global pipes dict with per-ship offset/height lookup."
function pipe_queued_render!(
        queue::Vector{<:RenderCommand}, map::GLObjectMap,
        gamemap::GameMap, derivedmapstate::DerivedMapState, gamestate::GameState
    )
    isempty(gamemap.ships) && return nothing

    foreachpair(gamemap.pipe_behaviors) do coord, pipe
        ship_state = get_ship_state(gamemap, pipe.ship)
        render_pipe_map!(
            queue, pipe;
            glmap = map, rotation = HexFrame.Q_POS, position = coord, transparency = 1.0,
            derivedmapstate, gameticks = gamestate.ticks,
            pos_offset = get_render_offset(ship_state),
            render_height_offset = _ship_render_height_offset(ship_state),
        )
        return nothing
    end
    return nothing
end

"Render ship surface background tiles with per-ship colour tint and position offset"
function ship_surface_queued_render!(
        queue::Vector{<:RenderCommand}, map::GLObjectMap, gamemap::GameMap;
        selected_ship::Union{Nothing, Symbol} = nothing
    )
    isempty(gamemap.ships) && return nothing

    for (coord, ship_name) in each_surface_owner(gamemap)
        ship = get_ship_state(gamemap, ship_name)
        ship_offset = get_render_offset(ship)
        ship_colour = (ship_name === selected_ship ? SHIP_SELECTED_TINT : get_ship_surface_colour(ship_name))

        push!(
            queue, render_basic_tile(
                map,
                :ShipSurface_basic,
                HexFrame.Q_POS,
                coord;
                colour = ship_colour,
                transparency = 1.0,
                draw_height = _ship_draw_height(ship, RENDER_HEIGHT_BACKGROUND),
                pos_offset = ship_offset
            )
        )
    end
    return nothing
end

# ===============================================================
# Particle System
# ===============================================================

const PARTICLE_VAO_MAX_COUNT = 10000
const MAX_CATCHUP_TICKS::Int = 8 # Maximum back-fill ticks after a GC pause or sim speed burst

"Immutable particle with Float32 position and colour, Float64 velocity, and expiry tick."
struct Particle
    position::SVector{2, Float32}
    velocity::SVector{2, Float64}
    colour::ColourType
    vanishing_time::Int64
end

"Particles of a shared size, with a reusable interleaved position/colour buffer for rendering."
mutable struct ParticleManager
    particles::Vector{Particle}
    size::Float32
    last_update_tick::Int64
    last_spawn_tick::Int64
    render_buffer::Vector{SVector{6, Float32}}
end

"Create a particle manager with capacity for one GPU batch."
function ParticleManager(size::Float32 = 5.0f0)
    particles = Particle[]
    render_buffer = SVector{6, Float32}[]
    sizehint!(particles, PARTICLE_VAO_MAX_COUNT)
    sizehint!(render_buffer, PARTICLE_VAO_MAX_COUNT)

    return ParticleManager(particles, size, -1, -1, render_buffer) # -1 ticks mark uninitialised managers
end

"Append a particle with its position, velocity, colour and expiry tick."
function spawn_particle!(manager::ParticleManager, position::SVector{2, Float32}, velocity::SVector{2, Float64}, vanishing_time::Int64; colour::ColourType)
    push!(manager.particles, Particle(position, velocity, colour, vanishing_time))
    return nothing
end

"Append particles with a shared colour and expiry tick; creation_time is retained for batch callers."
function spawn_particles!(
        manager::ParticleManager,
        positions::Vector{SVector{2, Float32}},
        velocities::Vector{SVector{2, Float64}},
        creation_time::Int64,
        vanishing_time::Int64;
        colour::ColourType
    )
    @timeit render_loop_timer "spawn_batch" begin
        @assert length(positions) == length(velocities) "Position and velocity vectors must have equal length"

        for i in eachindex(positions)
            spawn_particle!(manager, positions[i], velocities[i], vanishing_time; colour)
        end
    end
    return nothing
end

"Advance a particle position through Float64 precision and back to Float32."
@inline function _advance_pos(pos::SVector{2, Float32}, vel::SVector{2, Float64}, dt::Int)
    new_pos = SVector{2, Float64}(pos) + vel * dt
    return SVector{2, Float32}(new_pos)
end

"""
Expire and advance particles once per game tick, applying scaled ship-frame acceleration.
Velocity is updated before position, using all ticks since the previous update.
"""
function update_particle_physics!(manager::ParticleManager, gamestate::GameState; base_ups::Float64 = BASE_UPS)
    current_tick = gamestate.ticks

    # First-frame initialisation: skip physics
    if manager.last_update_tick < 0
        manager.last_update_tick = current_tick
        return nothing
    end

    current_tick == manager.last_update_tick && return nothing

    delta_ticks = current_tick - manager.last_update_tick
    manager.last_update_tick = current_tick

    @timeit render_loop_timer "update_physics" begin
        accel = gamestate.acceleration_ship_frame
        accel_corrected = SVector{2, Float64}(-accel[1], accel[2]) # x-axis inverted for render coords
        velocity_change = accel_corrected * (get_particle_accel_scale() / base_ups) * delta_ticks

        write_idx = 0
        particles = manager.particles
        @inbounds for particle in particles
            particle.vanishing_time <= current_tick && continue

            velocity = particle.velocity + velocity_change
            position = _advance_pos(particle.position, velocity, delta_ticks)
            write_idx += 1
            particles[write_idx] = Particle(position, velocity, particle.colour, particle.vanishing_time)
        end
        resize!(particles, write_idx)
    end
    return nothing
end

"""
Get the viewport bounding box in game (hex) coordinates.
Returns (bottom_left, top_right) as SVector{2,Float32}.
Computes the inverse of the view transform applied to NDC corners.
"""
function get_viewport_bounds_game_coords(viewstate)
    ndc_bottom_left = SVector{2, Float32}(-1.0f0, -1.0f0)
    ndc_top_right = SVector{2, Float32}(1.0f0, 1.0f0)

    # Inverse NDC scale
    inv_sx = viewstate.fb_width / (2.0f0 * hex_size_pixels)
    inv_sy = viewstate.fb_height / (2.0f0 * hex_size_pixels)

    inv_zoom = 1.0f0 / viewstate.view_zoom
    view_offset = SVector{2, Float32}(viewstate.view_x, viewstate.view_y)

    # Transform NDC corners back to game space: S^-1 -> Z^-1 -> T^-1
    zoomed_bl = SVector{2, Float32}(ndc_bottom_left[1] * inv_sx, ndc_bottom_left[2] * inv_sy)
    zoomed_tr = SVector{2, Float32}(ndc_top_right[1] * inv_sx, ndc_top_right[2] * inv_sy)

    panned_bl = zoomed_bl .* inv_zoom
    panned_tr = zoomed_tr .* inv_zoom

    game_bl = panned_bl .- view_offset
    game_tr = panned_tr .- view_offset

    return (game_bl, game_tr)
end

"""
Interpolate, cull and pack visible particles as (x, y, r, g, b, a), preserving spawn order.
Providing a map also culls particles behind stationary ship surfaces.
Returns the visible count; the render buffer reuses its capacity between frames.
"""
function cull_particles_to_buffer!(
        manager::ParticleManager,
        bottom_left::SVector{2, Float32},
        top_right::SVector{2, Float32},
        timestamp::Float64,
        ups::Float64,
        gamemap::Union{GameMap, Nothing}
    )
    @timeit render_loop_timer "cull_particles" begin
        time_since_last_tick = time() - timestamp
        passed_time_fraction = clamp(time_since_last_tick / (1.0 / ups), 0.0, 1.0)
        min_x, min_y = bottom_left
        max_x, max_y = top_right

        resize!(manager.render_buffer, length(manager.particles))
        write_idx = 0
        @inbounds for particle in manager.particles
            pos = SVector{2, Float32}(
                particle.position[1] + Float32(particle.velocity[1] * passed_time_fraction),
                particle.position[2] + Float32(particle.velocity[2] * passed_time_fraction)
            )
            min_x <= pos[1] <= max_x && min_y <= pos[2] <= max_y || continue

            if !isnothing(gamemap)
                tile = round_to_tile_cartesian(Float64(pos[1]), Float64(pos[2]))
                owner = get_surface_shiptag(gamemap, tile)
                !isnothing(owner) && !is_ship_moving(gamemap, owner) && continue
            end

            colour = particle.colour
            write_idx += 1
            manager.render_buffer[write_idx] = SVector{6, Float32}(pos[1], pos[2], colour[1], colour[2], colour[3], colour[4])
        end
        resize!(manager.render_buffer, write_idx)
        return write_idx
    end
end

"""
Spawn dust with random velocities from the corresponding snapshot's derived ship-surface edge tiles.
Gated to spawn only once per game tick, with catch-up spawning for missed ticks (GC pauses, sim speed > 1x).
Catch-up particles are pre-advanced along their velocity to avoid clumping at the spawn point.
"""
function thrust_dust_particle_effect!(
        manager::ParticleManager,
        gamestate::GameState,
        gamemap::GameMap,
        derivedmapstate::DerivedMapState;
        num_particles_per_tile::Int = 1,
        colour::SVector{4, Float32} = SVector{4, Float32}(0.5f0, 0.5f0, 0.5f0, 1.0f0)
    )
    PARTICLE_LIFETIME_TICKS = Int(1.5 * BASE_UPS)  # 1.5 seconds at BASE_UPS
    PARTICLE_VELOCITY_RANGE = 0.2

    @timeit render_loop_timer "spawn_effect" begin
        current_tick = gamestate.ticks

        # First-frame initialisation -- no catch-up on first call
        if manager.last_spawn_tick < 0
            manager.last_spawn_tick = current_tick - 1 # allows first-frame spawn with 0 missed ticks
        end

        current_tick == manager.last_spawn_tick && return nothing

        missed_ticks = clamp(current_tick - manager.last_spawn_tick - 1, 0, MAX_CATCHUP_TICKS)
        manager.last_spawn_tick = current_tick

        ticks_to_spawn = 1 + missed_ticks # current tick + back-fill

        @timeit render_loop_timer "generate_particles" begin
            edge_tiles = derivedmapstate.ship_surface_edge
            isempty(edge_tiles) && return nothing

            for tick_offset in 0:(ticks_to_spawn - 1)
                spawn_tick = current_tick - tick_offset
                prev_len = length(manager.particles)

                for tile_coord in edge_tiles
                    ship_name = get_surface_shiptag(gamemap, tile_coord)
                    isnothing(ship_name) && continue

                    offset_vec = glvec(get_ship_render_offset(gamemap, ship_name))
                    tile_pos = glvec(tile_coord) .+ offset_vec
                    for _ in 1:num_particles_per_tile
                        velocity = SVector{2, Float64}(
                            (rand() - 0.5) * PARTICLE_VELOCITY_RANGE,
                            (rand() - 0.5) * PARTICLE_VELOCITY_RANGE
                        )
                        spawn_particle!(manager, tile_pos, velocity, spawn_tick + PARTICLE_LIFETIME_TICKS; colour)
                    end
                end

                # Pre-advance catch-up particles to correct trail position (skip current tick)
                if tick_offset > 0
                    _pre_advance_catchup_particles!(manager, prev_len, tick_offset)
                end
            end
        end
    end

    return nothing
end

"Render visible particles in batches of at most 10,000, optionally culling stationary ship surfaces."
function render_particles!(
        glmap::GLObjectMap,
        manager::ParticleManager,
        viewstate::ViewState,
        timestamp::Float64,
        ups::Float64,
        gamemap::Union{GameMap, Nothing} = nothing
    )
    isempty(manager.particles) && return nothing

    bottom_left, top_right = get_viewport_bounds_game_coords(viewstate)
    visible_count = cull_particles_to_buffer!(manager, bottom_left, top_right, timestamp, ups, gamemap)
    visible_count == 0 && return nothing

    prog = ParticleRenderProgram()
    vao_data = getdata_dynamic_glvao(glmap, prog, :Particles_VAO)
    vertices_f32 = reinterpret(Float32, manager.render_buffer)
    glUseProgram(getid_glprog(glmap, prog))
    glBindVertexArray(vao_data.vao_id)
    set_gluniform(glmap, prog, :particle_size, manager.size)

    for first_idx in 1:PARTICLE_VAO_MAX_COUNT:visible_count
        last_idx = min(first_idx + PARTICLE_VAO_MAX_COUNT - 1, visible_count)
        batch_size = last_idx - first_idx + 1
        batch_vertices = view(vertices_f32, (6 * (first_idx - 1) + 1):(6 * last_idx))

        @timeit render_loop_timer "upload_vbo" begin
            update_dynamic_vao!(vao_data.vbo_id, batch_vertices)
        end

        @timeit render_loop_timer "gl_draw" begin
            glDrawArrays(GL_POINTS, 0, batch_size)
        end
    end

    glBindVertexArray(0)
    glUseProgram(0)
    return nothing
end

"Pre-advance only particles appended after prev_count, retaining their velocity, colour and expiry."
function _pre_advance_catchup_particles!(manager::ParticleManager, prev_count::Int, age_ticks::Int)
    @inbounds for i in (prev_count + 1):length(manager.particles)
        particle = manager.particles[i]
        position = _advance_pos(particle.position, particle.velocity, age_ticks)
        manager.particles[i] = Particle(position, particle.velocity, particle.colour, particle.vanishing_time)
    end
    return nothing
end

"""
Spawn foreground (nozzle exhaust) particles for all components, gated to once per game tick.
When ticks have been missed (GC pauses, sim speed > 1x), spawns back-dated batches with
pre-advanced positions to fill gaps in exhaust trails.
"""
function tile_particle_spawn!(
        manager::ParticleManager, glmap::GLObjectMap, gamemap::GameMap,
        derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot, gamestate::GameState
    )
    current_tick = gamestate.ticks

    # First-frame initialisation -- no catch-up on first call
    if manager.last_spawn_tick < 0
        manager.last_spawn_tick = current_tick - 1 # allows first-frame spawn with 0 missed ticks
    end

    current_tick == manager.last_spawn_tick && return nothing

    missed_ticks = clamp(current_tick - manager.last_spawn_tick - 1, 0, MAX_CATCHUP_TICKS)
    manager.last_spawn_tick = current_tick

    # Current tick first, then pre-advanced back-fill for missed ticks
    for age_ticks in 0:missed_ticks
        prev_count = length(manager.particles)
        foreachpair(gamemap.components) do coord, tilecomp
            ship_state = get_ship_state(gamemap, tilecomp.ship)
            collect_effect_particles!(
                manager, tilecomp;
                glmap = glmap, mna_state = mna_state, derivedmapstate = derivedmapstate,
                gameticks = current_tick - age_ticks, position = coord, tile = coord,
                pos_offset = get_render_offset(ship_state)
            )
            return nothing
        end

        if age_ticks > 0
            _pre_advance_catchup_particles!(manager, prev_count, age_ticks)
        end
    end
    return nothing
end

# ===============================================================
# Animation Helpers
# ===============================================================

"Gets a sprite from an animation tuple based on gameticks. Lower speed divisor means faster animation."
function animation_sprite_picker(sprites::NTuple{N, Symbol}, gameticks::Integer, speed_divisor::Integer) where {N}
    sprite_ticks = gameticks ÷ speed_divisor
    sprite_index = sprite_ticks % N + 1
    return sprites[sprite_index]
end

"""
Creates a smooth vibration offset using fractal Brownian motion (fBm).
Returns signed pixel deltas bounded to approximately [-magnitude, +magnitude].
"""
function animation_vibe_offset(gameticks::Int64; speed::Float64 = 100.0, magnitude::Float64 = 2.0, octaves::Int = 3)::Tuple{Float64, Float64}
    t = gameticks * speed * 0.01

    function fbm_1d_raw(x::Float64, octaves::Int)::Float64
        value = 0.0
        amplitude = 1.0
        frequency = 1.0
        for i in 1:octaves
            value += amplitude * sin(x * frequency + i * 1.23)
            amplitude *= 0.5
            frequency *= 2.0
        end
        return value
    end

    total_amp = 2.0 * (1.0 - 2.0^(-octaves))
    scale = magnitude / total_amp

    raw_x = fbm_1d_raw(t + 0.0, octaves)
    raw_y = fbm_1d_raw(t + 100.0, octaves)

    return (scale * raw_x, scale * raw_y)
end

"""
Creates a rotation matrix for sprite animation effects.
The `speed` parameter controls rotation rate (positive = clockwise, negative = counterclockwise).
Returns a 2x2 rotation matrix suitable for sprite rendering uniforms.
"""
function animation_rotate(gameticks::Integer, speed::Float64)::SMatrix{2, 2, Float32}
    angle_degrees = Float32(gameticks * speed * (1.0 / BASE_UPS))
    angle_rad = deg2rad(angle_degrees)
    cos_a = Float32(cos(angle_rad))
    sin_a = Float32(sin(angle_rad))

    return SMatrix{2, 2, Float32}(cos_a, sin_a, -sin_a, cos_a)
end


end # module HexFlowRendering
