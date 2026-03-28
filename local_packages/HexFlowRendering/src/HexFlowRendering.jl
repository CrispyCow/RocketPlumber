module HexFlowRendering

#= Dependancies =#
# Packages
using ModernGL, TimerOutputs, Artifacts
using StaticArrays, StructArrays, CSyntax.CRef, Accessors
using ColorSchemes, ColorTypes
using FileIO, ImageIO, ImageMagick
# Custom Packages
using RenderEngine, HexFlowTelemetry 
using HexFrame, HexFluids, HexComponentsAPI, FlowEngine, FlowMap, HexFlowControl
import RenderEngine.uniforms_type

#= Exports =#
# Type exports
export ColourType
export BaseSpriteRenderProgram, BaseSpriteUniforms
export LiquidSpriteRenderProgram, LiquidSpriteUniforms
export GasSpriteRenderProgram, GasSpriteUniforms
export ParticleRenderProgram, ParticleUniforms
export Particle, ParticleGroup, ParticleManager

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
export create_particle_group, spawn_particles!, update_particle_physics!
export thrust_dust_particle_effect!, render_particles!
export get_particle_accel_scale, set_particle_accel_scale!
export animation_sprite_picker, animation_vibe_offset, animation_rotate

# Const exports
export hex_size_pixels # used in interactions.jl for view transform
export DEFAULT_EMPTY_FLUID_COLOUR

#= Global references for file paths (set during __init__) =#
const SHADER_DIR = Ref{String}()
const TEXTURE_ATLAS_DIR = Ref{String}()

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
const RENDER_HEIGHT_PIPE_BASE::Int32 = -10             # base pipe sprite (beneath fluid mask)
const RENDER_HEIGHT_PIPE::Int32 = 0                    # pipes drawn above background but beneath nodes/components
const RENDER_HEIGHT_NODE::Int32 = 100000               # nodes drawn above pipes and components, below overlays
const RENDER_HEIGHT_COMPONENT_BEHIND::Int32 = 1000    # for parts sitting behind main sprites (fluidmasks, energy bars)
const RENDER_HEIGHT_COMPONENT_STATIC::Int32 = 2000    # static elements of component sprite
const RENDER_HEIGHT_COMPONENT_ANIM::Int32 = 3000      # animated effects drawn over static elements
const RENDER_HEIGHT_OVERLAY_BASE::Int32 = 101000      # overlays, e.g., stall overlay
const RENDER_HEIGHT_TRACTOR_BEAM::Int32 = RENDER_HEIGHT_BACKGROUND - 100  # tractor beam visuals, deep background

const fluid_colour_lookup = Dict{FluidTags, ColourType}(
    HexFluids.MONOPROP_LIQUID => ColourType(0.608, 0.169, 0.69, 1.0), # purple
    HexFluids.MONOPROP_GAS => ColourType(0.737, 0.569, 0.769, 1.0), # light purple
    HexFluids.COLD_GAS => ColourType(0.71, 0.918, 0.929, 1.0) # light blue
)

"Returns GLfloat RGBA colour from a FluidTag, or default if tag not found."
function get_fluid_colour(tag::FluidTags; default::ColourType = DEFAULT_EMPTY_FLUID_COLOUR)::ColourType
    return get(fluid_colour_lookup, tag, default)
end

"Loads shader source code from the shaders subdirectory."
function grab_shader(name::String)
    return read(joinpath(SHADER_DIR[], name), String)
end

#= Shared OpenGL Objects =#

"Initializes the view transformation uniform buffer object."
function viewtransform_glubo_init(map::GLObjectMap)
    return setup_glubo!(map, :ViewTransform_UBO, 48, 1, "ViewBlock")
end

"Sets the view transformation matrix in the UBO."
function set_view_ubo(map::GLObjectMap, viewT::SMatrix{3, 3, Float32})
    packed_view = vec(vcat(viewT, SMatrix{1, 3, Float32}(0, 0, 0)))  # std140 padding

    return set_ubo(map, :ViewTransform_UBO, packed_view)
end

"Initializes the main texture atlas and loads sprite metadata."
function texatlas1_gltex_init(map::GLObjectMap)
    texname = :TileTextureAtlas1
    texdata = load(joinpath(TEXTURE_ATLAS_DIR[], "$texname.png"))
    setup_gltex!(map, texname, texdata)
    return setup_glsprite!(map, texname, TEXTURE_ATLAS_DIR[])
end

#= Render Program Definitions and setup =#

"Base sprite rendering program for general-purpose textured sprites."
struct BaseSpriteRenderProgram <: AbstractRenderProgram end
@kwdef struct BaseSpriteUniforms <: AbstractRenderUniforms{BaseSpriteRenderProgram}
    uv_offset::SVector{2, GLfloat}
    uv_scale::SVector{2, GLfloat}
    sprite_scale::SVector{2, GLfloat}  # Precomputed: (cropped_size_px .* (1/hex_size_pixels)) * user_scale
    sprite_offset::SVector{2, GLfloat}  # Precomputed translation in hex units to re-center the cropped sprite
    sprite_rotate::SMatrix{2, 2, GLfloat}  # Sprite rotation applied before scaling and offsetting (for animation)
    object_rotation::SMatrix{2, 2, GLfloat}
    object_translation::SVector{2, GLfloat}
    texunit::GLint
    colour_multiply::SVector{4, GLfloat}
    x_uncliped::GLfloat
end
uniforms_type(::Type{BaseSpriteRenderProgram}) = BaseSpriteUniforms

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
    sprite_rotate::SMatrix{2, 2, GLfloat}
    object_rotation::SMatrix{2, 2, GLfloat}
    object_translation::SVector{2, GLfloat}
    texunit::GLint
    colour_multiply::SVector{4, GLfloat}
    x_uncliped::GLfloat
    gameticks::GLfloat
end
uniforms_type(::Type{LiquidSpriteRenderProgram}) = LiquidSpriteUniforms

"Gas sprite rendering program with animated gas shader effects."
struct GasSpriteRenderProgram <: AbstractRenderProgram end

@kwdef struct GasSpriteUniforms <: AbstractRenderUniforms{GasSpriteRenderProgram}
    uv_offset::SVector{2, GLfloat}
    uv_scale::SVector{2, GLfloat}
    sprite_scale::SVector{2, GLfloat}
    sprite_offset::SVector{2, GLfloat}
    sprite_rotate::SMatrix{2, 2, GLfloat}
    object_rotation::SMatrix{2, 2, GLfloat}
    object_translation::SVector{2, GLfloat}
    texunit::GLint
    colour_multiply::SVector{4, GLfloat}
    x_uncliped::GLfloat
    gameticks::GLfloat
end
uniforms_type(::Type{GasSpriteRenderProgram}) = GasSpriteUniforms

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
    particle_colour::SVector{4, GLfloat}
end
uniforms_type(::Type{ParticleRenderProgram}) = ParticleUniforms

"Initializes the particle rendering program with geometry shader and dynamic VAO."
function particle_glprog_init(map::GLObjectMap)
    vert_code = grab_shader("particle.vert")
    geom_code = grab_shader("particle.geom")
    frag_code = grab_shader("particle.frag")

    layout = [
        VboAttribFormat(:position, 2, GL_FLOAT, GL_FALSE),
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
    r_base = 0.50f0 + 0.25f0 * Float32((h & 0xFF) / 255)
    g_base = 0.50f0 + 0.25f0 * Float32(((h >> 8) & 0xFF) / 255)
    b_base = 0.50f0 + 0.25f0 * Float32(((h >> 16) & 0xFF) / 255)
    
    # Bias towards grey/brown by reducing blue slightly and keeping r >= g
    r = clamp(r_base, 0.53f0, 0.75f0)
    g = clamp(g_base * 0.98f0, 0.50f0, 0.72f0)
    b = clamp(b_base * 0.90f0, 0.45f0, 0.68f0)
    
    return SVector{4, Float32}(r, g, b, 1.0f0)
end

"Pale bright green tint applied to the selected ship's surface tiles."
const SHIP_SELECTED_TINT = SVector{4, Float32}(0.7f0, 1.0f0, 0.7f0, 1.0f0)

"""
Compute BaseSpriteUniforms for any sprite. This function contains the common logic
used by all sprite renderers. It returns a BaseSpriteUniforms value (not a RenderCommand)
so callers can adapt or copy fields into their own uniform structs.
"""
function setup_basesprite_uniforms(
        glmap::GLObjectMap, sprite::Symbol, rotation_matrix::SMatrix{2, 2, GLfloat}, position::SVector{2, Float32};
        colour::SVector{4, Float32} = SVector{4, Float32}(1.0, 1.0, 1.0, 1.0),
        scale::AbstractFloat = 1.0,
        transparency::AbstractFloat = 1.0,
        x_unclipped::AbstractFloat = 1.0,
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
        x_uncliped = GLfloat(x_unclipped)
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

    return RenderCommand(base_uniforms, :UnitQuad_VAO, draw_height)
end

"Returns a RenderCommand for a basic tile sprite at the given position and rotation."
function render_basic_tile(
        glmap::GLObjectMap, sprite::Symbol, rotation::HexAxis, position::TileCoord;
        pos_offset = nothing,
        kwargs...
    )::RenderCommand
    return render_basic_sprite(glmap, sprite, hex_rotmats[rotation], position; pos_offset = pos_offset, kwargs...)
end

"Returns a RenderCommand for a basic pipe sprite at the given edge position and rotation."
function render_basic_pipe(
        glmap::GLObjectMap, sprite::Symbol, rotation::HexAxis, position::EdgeCoord;
        pos_offset = nothing,
        kwargs...
    )::RenderCommand
    # Transpose rotation matrix to convert from column-vector to row-vector convention
    rotation_matrix = get_rotmat(position)'
    position_vec = glvec(position)
    # Apply position offset if provided
    if !isnothing(pos_offset)
        offset_vec = glvec(pos_offset)
        position_vec = position_vec .+ offset_vec
    end

    return render_basic_sprite(glmap, sprite, rotation_matrix, position_vec; kwargs...)
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
        x_uncliped = base.x_uncliped,
        gameticks = GLfloat(gameticks)
    )
    return RenderCommand(u, :UnitQuad_VAO, draw_height)
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
        x_uncliped = base.x_uncliped,
        gameticks = GLfloat(gameticks)
    )
    return RenderCommand(u, :UnitQuad_VAO, draw_height)
end

"Returns a RenderCommand for a basic tile sprite with animated liquid effect."
function render_liquid_tile(
        glmap::GLObjectMap, sprite::Symbol, rotation::HexAxis, position::AbstractBasicCoordSystem, gameticks::Integer;
        pos_offset = nothing,
        kwargs...
    )::RenderCommand
    return render_liquid_sprite(glmap, sprite, hex_rotmats[rotation], position; pos_offset = pos_offset, gameticks = gameticks, kwargs...)
end

"Returns a RenderCommand for a basic tile sprite with animated gas effect."
function render_gas_tile(
        glmap::GLObjectMap, sprite::Symbol, rotation::HexAxis, position::AbstractBasicCoordSystem, gameticks::Integer;
        pos_offset = nothing,
        kwargs...
    )::RenderCommand
    return render_gas_sprite(glmap, sprite, hex_rotmats[rotation], position; pos_offset = pos_offset, gameticks = gameticks, kwargs...)
end

"Returns RenderCommands for a pipe using sprite-based rendering with base pipe and fluid effects."
function render_pipe(glmap::GLObjectMap, pipe::EdgeCoord, colour::ColourType; transparency::AbstractFloat = 1.0f0, gameticks::Integer = 0)
    # Transpose rotation matrix to convert from column-vector to row-vector convention
    rotation_matrix = get_rotmat(pipe)'
    position = glvec(pipe)

    base_cmd = render_basic_sprite(
        glmap, :BigPipes_Edge, rotation_matrix, position;
        colour = SVector{4, Float32}(1.0, 1.0, 1.0, 1.0), transparency = transparency, draw_height = RENDER_HEIGHT_PIPE_BASE
    )

    fluid_cmd = render_basic_sprite(
        glmap, :BigPipes_Edge_fluidmask, rotation_matrix, position;
        colour = colour, transparency = transparency, draw_height = RENDER_HEIGHT_PIPE
    )

    return [base_cmd, fluid_cmd]
end

"Returns RenderCommands for a pipe by deriving its fluid type and colour from `derivedmapstate`."
function render_pipe(glmap::GLObjectMap, pipe::EdgeCoord, derivedmapstate::DerivedMapState; transparency::AbstractFloat = 1.0f0, gameticks::Integer = 0)
    v1_tag = get(derivedmapstate.nodeactualfluids, to_nodecoord(pipe.v1), HexFluids.NONE)
    v2_tag = get(derivedmapstate.nodeactualfluids, to_nodecoord(pipe.v2), HexFluids.NONE)
    tag = prioritise_fluidtag(v1_tag, v2_tag)
    colour = get_fluid_colour(tag, DEFAULT_PIPE_COLOUR)

    rotation_matrix = get_rotmat(pipe)'
    position = glvec(pipe)

    base_cmd = render_basic_sprite(
        glmap, :BigPipes_Edge, rotation_matrix, position;
        colour = SVector{4, Float32}(1.0, 1.0, 1.0, 1.0), transparency = transparency, draw_height = RENDER_HEIGHT_PIPE_BASE
    )

    # Render fluid effect based on fluid type
    fluid_cmd = if HexFluids.is_liquid(tag)
        render_liquid_sprite(
            glmap, :BigPipes_Edge_fluidmask, rotation_matrix, position;
            colour = colour, transparency = transparency, draw_height = RENDER_HEIGHT_PIPE, gameticks = gameticks
        )
    elseif HexFluids.is_gas(tag)
        render_gas_sprite(
            glmap, :BigPipes_Edge_fluidmask, rotation_matrix, position;
            colour = colour, transparency = transparency, draw_height = RENDER_HEIGHT_PIPE, gameticks = gameticks
        )
    else
        # No fluid or unknown - use basic sprite
        render_basic_sprite(
            glmap, :BigPipes_Edge_fluidmask, rotation_matrix, position;
            colour = colour, transparency = transparency, draw_height = RENDER_HEIGHT_PIPE
        )
    end

    return [base_cmd, fluid_cmd]
end

"Render a dotted beam between two coordinates using repeated sprites with animated noise."
function render_beam!(
        queue::Vector{RenderCommand},
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

    for i in 0:(num_elements - 1)
        t = i / steps
        # Per-element vibing - use a hash of the index to produce a unique deterministic seed per element
        # Constrain the hash to a small positive integer to avoid platform-dependent signed/unsigned issues
        idx_hash = Int64(UInt(hash(i)) % UInt(1_000_000))
        noise_x, noise_y = animation_vibe_offset(gameticks + idx_hash; magnitude = noise_magnitude)
        x = start_cart.x + dx * t + noise_x
        y = start_cart.y + dy * t + noise_y
        pos = CartesianCoord(x, y)
        push!(
            queue,
            render_basic_sprite(
                glmap,
                :MoveArrow_arrow_start,
                rotmat_2D(0.0),
                pos;
                colour = colour,
                scale = scale,
                draw_height = draw_height
            )
        )
    end

    return nothing
end

#= Queued Render Functions =#

"Height offset applied to animating ships so their full render stack sits above stationary overlays."
const ANIMATING_SHIP_RENDER_HEIGHT_OFFSET = Int32(1_500_000_000)

"Return the per-ship render height offset: non-zero only while the ship is in a transitional docking state."
function _ship_render_height_offset(ship::ShipMap)::Int32
    status = get_docking_status(ship)
    return (status isa ConnectedDockStat) ? Int32(0) : ANIMATING_SHIP_RENDER_HEIGHT_OFFSET
end

"Map a base draw height into the correct per-ship layer."
_ship_draw_height(ship::ShipMap, base_height::Integer)::Int32 = Int32(base_height) + _ship_render_height_offset(ship)

"Map a base draw height into the correct per-ship layer when only the owning ship name is available."
function _ship_draw_height(gamemap::GameMap, ship_name::Union{Nothing, Symbol}, base_height::Integer)::Int32
    isnothing(ship_name) && return Int32(base_height)
    return _ship_draw_height(get_ship(gamemap, ship_name), base_height)
end

"Renders all tile components in the gamemap by delegating to `render_map_elem!` on each component. This implementation iterates each ShipMap and calls the per-ship components, keeping ship-local helper functions intact."
function tile_queued_render!(queue::Vector{RenderCommand}, map::GLObjectMap, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State, gamestate::GameState)
    isempty(gamemap.ships) && return nothing

    for (ship_name, ship) in gamemap.ships
        ship_offset = get_render_offset(ship)
        height_offset = _ship_render_height_offset(ship)
        for (coord, tilecomp) in get_all_components(ship)
            render_map_elem!(queue, tilecomp; glmap = map, mna_state = mna_state, derivedmapstate = derivedmapstate, gameticks = gamestate.ticks, position = coord, pos_offset = ship_offset, render_height_offset = height_offset)
        end
    end
    return nothing
end

"Renders all node vertices with colours based on MNA voltage/pressure values."
function node_queued_render!(queue::Vector{RenderCommand}, map::GLObjectMap, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State)
    nodes = list_nodes(derivedmapstate.allelements)
    isempty(nodes) && return nothing

    for (node, _) in nodes
        if !is_axis(node.dir)  # Skip if node isn't a vertex
            continue
        end

        # Determine colour based on MNA voltage, falling back to 0.0 for missing/invalid values
        colour = begin
            if haskey(mna_state.node_voltages_scaled, node)
                vs = mna_state.node_voltages_scaled[node]
                vs = isfinite(vs) ? vs : 0.0  # Handle NaN/infinite values
                voltage_clamped = clamp(Float32(vs), 0.0f0, 1.0f0)
                c = get(NODE_VOLTAGE_COLORSCHEME, voltage_clamped)
                SVector{4, Float32}(Float32(c.r), Float32(c.g), Float32(c.b), 1.0f0)
            else
                c = get(NODE_VOLTAGE_COLORSCHEME, 0.0)
                SVector{4, Float32}(Float32(c.r), Float32(c.g), Float32(c.b), 1.0f0)
            end
        end

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
        push!(queue, render_basic_sprite(
            map, :Node_pressuremask, rotation_matrix, position;
            colour = colour, transparency = 1.0, draw_height = node_height
        ))

        # Render frame on top
        push!(queue, render_basic_sprite(
            map, :Node_frame, rotation_matrix, position;
            draw_height = node_height + Int32(10)
        ))
    end
    return nothing
end

"Renders all pipe behaviors in the gamemap by delegating to `render_pipe_map!` on each pipe. Iterates each ShipMap." 
function pipe_queued_render!(queue::Vector{RenderCommand}, map::GLObjectMap, gamemap::GameMap, derivedmapstate::DerivedMapState, gamestate::GameState)
    isempty(gamemap.ships) && return nothing

    for (ship_name, ship) in gamemap.ships
        ship_offset = get_render_offset(ship)
        height_offset = _ship_render_height_offset(ship)
        for (edge, pipe_behav) in get_all_pipes(ship)
            rotation = HexFrame.Q_POS  # Default rotation, edge orientation handled by render_pipe_map!
            render_pipe_map!(
                queue, pipe_behav;
                glmap = map,
                rotation = rotation,
                position = edge,
                transparency = 1.0,
                derivedmapstate = derivedmapstate,
                gameticks = gamestate.ticks,
                pos_offset = ship_offset,
                render_height_offset = height_offset
            )
        end
    end

    return nothing
end

"Render ship surface background tiles with per-ship colour tint and position offset"
function ship_surface_queued_render!(
        queue::Vector{RenderCommand}, map::GLObjectMap, gamemap::GameMap;
        selected_ship::Union{Nothing, Symbol} = nothing
    )
    isempty(gamemap.ships) && return nothing

    for (ship_name, ship) in gamemap.ships
        ship_offset = get_render_offset(ship)
        ship_colour = (ship_name === selected_ship ? SHIP_SELECTED_TINT : get_ship_surface_colour(ship_name))

        for coord in get_all_surface_tiles(ship)
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
    end
    return nothing
end

# ===============================================================
# Particle System
# ===============================================================

const PARTICLE_VAO_MAX_COUNT = 10000

"""
Immutable particle with position, velocity, and lifetime.
Position stored as Float32 for direct GPU upload; velocity kept as Float64 for precision.
"""
struct Particle
    position::SVector{2, Float32}
    velocity::SVector{2, Float64}
    creation_time::Int64
    vanishing_time::Int64
end

"""
Mutable container for a group of particles with shared rendering properties.
"""
mutable struct ParticleGroup
    particles::StructArray{Particle}
    colour::SVector{4, Float32}
    size::Float32
end

"""
Create a new particle group with pre-allocated capacity matching VAO size.
"""
function create_particle_group(colour::SVector{4, Float32}, size::Float32)
    particles = StructArray{Particle}(undef, 0)
    sizehint!(particles, PARTICLE_VAO_MAX_COUNT)

    return ParticleGroup(particles, colour, size)
end

"""
Particle manager that automatically organizes particles into groups by color.
All particles within the manager share the same size, but can have different colors.
Groups are created on-demand when particles with new colors are spawned.
Includes a preallocated culling buffer to avoid allocations during viewport culling.
"""
mutable struct ParticleManager
    groups::Dict{SVector{4, Float32}, ParticleGroup}
    size::Float32
    last_update_tick::Int64
    last_spawn_tick::Int64
    cull_buffer::Vector{SVector{2, Float32}}
end

"""
Create a new particle manager with specified particle size.
"""
function ParticleManager(size::Float32 = 5.0f0)
    cull_buffer = Vector{SVector{2, Float32}}()
    sizehint!(cull_buffer, PARTICLE_VAO_MAX_COUNT)

    return ParticleManager(
        Dict{SVector{4, Float32}, ParticleGroup}(),
        size,
        0,
        0,
        cull_buffer
    )
end

"""
Batch append particles using pre-constructed field vectors.
Low-level interface - all vectors must have equal length.
"""
function spawn_particles!(
        group::ParticleGroup,
        positions::Vector{SVector{2, Float32}},
        velocities::Vector{SVector{2, Float64}},
        creation_times::Vector{Int64},
        vanishing_times::Vector{Int64}
    )
    @timeit render_loop_timer "spawn_batch" begin
        @assert length(positions) == length(velocities) == length(creation_times) == length(vanishing_times) "All field vectors must have equal length"

        append!(group.particles, StructArray{Particle}((positions, velocities, creation_times, vanishing_times)))
    end
    return nothing
end

"""
Batch append particles with scalar creation/vanishing times.
Creates time vectors via fill, then delegates to vector-based method.
"""
function spawn_particles!(
        group::ParticleGroup,
        positions::Vector{SVector{2, Float32}},
        velocities::Vector{SVector{2, Float64}},
        creation_time::Int64,
        vanishing_time::Int64
    )
    n = length(positions)
    @assert length(velocities) == n "Position and velocity vectors must have equal length"

    creation_times = fill(creation_time, n)
    vanishing_times = fill(vanishing_time, n)

    spawn_particles!(group, positions, velocities, creation_times, vanishing_times)
    return nothing
end

"""
Spawn particles into a ParticleManager with specified color.
Automatically routes particles to the appropriate color-keyed group, creating it if needed.
"""
function spawn_particles!(
        manager::ParticleManager,
        positions::Vector{SVector{2, Float32}},
        velocities::Vector{SVector{2, Float64}},
        creation_time::Int64,
        vanishing_time::Int64;
        colour::SVector{4, Float32}
    )
    # Get or create the group for this color
    group = get!(manager.groups, colour) do
        create_particle_group(colour, manager.size)
    end

    # Delegate to the group's spawn function
    spawn_particles!(group, positions, velocities, creation_time, vanishing_time)
    return nothing
end

"""
Update particle physics for a single group. Applies the ship's real acceleration
(from `gamestate.acceleration_ship_frame`, per-second units) scaled by `get_particle_accel_scale()`
to drift particles, simulating the ship accelerating past its own exhaust and dust.
Ship-frame acceleration is used so particle drift is always relative to the ship body,
regardless of any manoeuvre rotation applied for space-map velocity integration.
"""
function update_particle_physics!(group::ParticleGroup, gamestate; base_ups::Float64 = BASE_UPS, delta_ticks::Int = 1)
    @timeit render_loop_timer "update_physics" begin
        current_tick = gamestate.ticks
        particles = group.particles

        # Remove expired particles
        @timeit render_loop_timer "filter_expired" begin
            filter!(p -> p.vanishing_time > current_tick, group.particles)
            particles = group.particles
        end

        length(particles) == 0 && return nothing # exit early if no particles remain

        # Use ship-frame acceleration with visual scaling and per-tick integration
        @timeit render_loop_timer "physics_calc" begin
            accel = gamestate.acceleration_ship_frame
            accel_corrected = SVector{2, Float64}(-accel[1], accel[2]) # x-axis inverted for render coords
            accel_per_tick = accel_corrected * (get_particle_accel_scale() / base_ups)

            # apply for every tick that has elapsed since last update
            particles.velocity .+= Ref(accel_per_tick * delta_ticks)

            # Update positions: Float32 <- (Float64 + velocity*dt) for precision
            positions_f64 = SVector{2, Float64}.(particles.position)
            positions_f64 .+= particles.velocity * delta_ticks
            particles.position .= SVector{2, Float32}.(positions_f64)
        end
    end

    return nothing
end

"Update particle physics for all groups, gated to once per game tick."
function update_particle_physics!(manager::ParticleManager, gamestate; kwargs...)
    current_tick = gamestate.ticks

    # Only update if tick has incremented
    if current_tick == manager.last_update_tick
        return nothing
    end

    # compute how many ticks have elapsed since last update
    delta_ticks = current_tick - manager.last_update_tick
    manager.last_update_tick = current_tick

    for group in values(manager.groups)
        update_particle_physics!(group, gamestate; kwargs..., delta_ticks = delta_ticks)
    end
    return nothing
end

"""
Extract particle positions as flat Float32 array for VBO upload.
Uses reinterpret for zero-copy view of StructArray's contiguous position data.
"""
function get_particle_positions_f32(group::ParticleGroup)
    particle_count = length(group.particles)
    particle_count == 0 && return reinterpret(Float32, SVector{2, Float32}[])

    # StructArray stores position field contiguously; reinterpret as flat Float32 array (zero-copy)
    positions_svec = group.particles.position
    positions_flat = reinterpret(Float32, positions_svec)

    return positions_flat
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
Cull particles to viewport bounds, copying visible positions to manager's preallocated buffer.
Returns the count of visible particles (zero-alloc after buffer is sized).
Optionally culls particles behind ship surface if gamemap is provided (for background particles).
"""
function cull_particles_to_buffer!(
        manager::ParticleManager,
        group::ParticleGroup,
        bottom_left::SVector{2, Float32},
        top_right::SVector{2, Float32},
        timestamp::Float64,
        ups::Float64,
        gamemap::Union{GameMap, Nothing}
    )
    @timeit render_loop_timer "cull_particles" begin
        # Interpolate positions based on timestamp into buffer (optimized, no allocation)
        @timeit render_loop_timer "interpolate" begin
            positions = group.particles.position
            velocities = group.particles.velocity
            particle_count = length(positions)

            time_since_last_tick = time() - timestamp
            passed_time_fraction = clamp(time_since_last_tick / (1.0 / ups), 0.0, 1.0)

            resize!(manager.cull_buffer, particle_count)
            map!(manager.cull_buffer, positions, velocities) do pos, vel
                pos + SVector{2, Float32}(vel * passed_time_fraction)
            end
        end

        # Filter viewport bounds (always)
        @timeit render_loop_timer "filter_viewport" begin
            min_x, min_y = bottom_left
            max_x, max_y = top_right
            filter!(manager.cull_buffer) do pos
                min_x <= pos[1] <= max_x && min_y <= pos[2] <= max_y
            end
        end

        # Filter ship surface (only for background particles when gamemap provided)
        # NOTE: this step as a whole is somewhat expensive, could be ommited if we get cpu bound
        if gamemap !== nothing
            @timeit render_loop_timer "filter_surface" begin
                # Iterate per-ship and test particles in each ship's local coordinate frame.
                # This allows fractional render offsets (non-integer) without rounding ship tiles.
                for (ship_name, ship) in gamemap.ships
                    ship_offset_vec = glvec(get_render_offset(ship))
                    surface_tiles = ship.ship_tiles

                    filter!(manager.cull_buffer) do pos
                        # Reverse-offset particle to ship-local coordinates
                        unoffset_pos = pos .- ship_offset_vec

                        # NOTE: the fact we have to convert to Float64 is an area for possible optimisation
                        # Convert Float32 position to CartesianCoord (Float64) for round_to_tile
                        cart_pos = HexFrame.CartesianCoord(Float64(unoffset_pos[1]), Float64(unoffset_pos[2]))
                        tile = HexFrame.round_to_tile(cart_pos)

                        # Keep particle if NOT behind this ship's surface
                        return !(tile in surface_tiles)
                    end
                end
            end
        end

        return length(manager.cull_buffer)
    end
end

"""
Extract culled particle positions as flat Float32 array for VBO upload.
Operates on the manager's cull_buffer.
"""
function get_culled_positions_f32(manager::ParticleManager, visible_count::Int)
    visible_count == 0 && return reinterpret(Float32, SVector{2, Float32}[])

    visible_positions = view(manager.cull_buffer, 1:visible_count)
    positions_flat = reinterpret(Float32, visible_positions)

    return positions_flat
end

"""
Thrust dust particle effect - spawns particles from ship surface edge tiles with random velocities.
Gated to spawn only once per game tick. Uses batch spawning for efficiency.
Respects per-ship render position offsets.
"""
function thrust_dust_particle_effect!(
        manager::ParticleManager,
        gamestate::GameState,
        gamemap::GameMap;
        num_particles_per_tile::Int = 2,
        colour::SVector{4, Float32} = SVector{4, Float32}(0.5f0, 0.5f0, 0.5f0, 1.0f0)
    )
    PARTICLE_LIFETIME_TICKS = Int(1.5 * BASE_UPS)  # 1.5 seconds at BASE_UPS
    PARTICLE_VELOCITY_RANGE = 0.2

    @timeit render_loop_timer "spawn_effect" begin
        current_tick = gamestate.ticks

        if current_tick == manager.last_spawn_tick  # Only spawn once per tick
            return nothing
        end
        manager.last_spawn_tick = current_tick

        @timeit render_loop_timer "generate_particles" begin
            # Iterate per-ship to apply correct render offsets
            for (ship_name, ship) in gamemap.ships
                ship_offset = get_render_offset(ship)
                offset_vec = glvec(ship_offset)
                
                # Get edge tiles for this ship
                edge_tiles = Set{TileCoord}()
                find_ship_surface_edgetiles!(edge_tiles, ship)
                
                total_particles = length(edge_tiles) * num_particles_per_tile
                total_particles == 0 && continue
                positions = Vector{SVector{2, Float32}}(undef, total_particles)
                velocities = Vector{SVector{2, Float64}}(undef, total_particles)

                idx = 1
                for tile_coord in edge_tiles
                    tile_pos = glvec(tile_coord) .+ offset_vec

                    for _ in 1:num_particles_per_tile
                        positions[idx] = tile_pos
                        velocities[idx] = SVector{2, Float64}((rand() - 0.5) * PARTICLE_VELOCITY_RANGE, (rand() - 0.5) * PARTICLE_VELOCITY_RANGE)
                        idx += 1
                    end
                end

                spawn_particles!(manager, positions, velocities, gamestate.ticks, gamestate.ticks + PARTICLE_LIFETIME_TICKS; colour = colour)
            end
        end
    end

    return nothing
end

"""
Render a particle group, handling batching for groups >PARTICLE_VAO_MAX_COUNT particles.
Culls particles to viewport bounds before upload. Optionally culls particles behind ship surface.
"""
function render_particles!(
        glmap::GLObjectMap,
        manager::ParticleManager,
        group::ParticleGroup,
        bottom_left::SVector{2, Float32},
        top_right::SVector{2, Float32},
        timestamp::Float64,
        ups::Float64,
        gamemap::Union{GameMap, Nothing}
    )
    @timeit render_loop_timer "render_group" begin
        total_count = length(group.particles)
        total_count == 0 && return nothing

        # Cull particles to viewport bounds (and optionally ship surface)
        visible_count = cull_particles_to_buffer!(manager, group, bottom_left, top_right, timestamp, ups, gamemap)
        visible_count == 0 && return nothing

        prog = ParticleRenderProgram()
        vao_capacity = PARTICLE_VAO_MAX_COUNT

        @timeit render_loop_timer "convert_positions" begin
            positions_f32 = get_culled_positions_f32(manager, visible_count)
        end

        num_batches = cld(visible_count, vao_capacity)

        for batch_idx in 1:num_batches
            start_idx = (batch_idx - 1) * vao_capacity + 1
            end_idx = min(batch_idx * vao_capacity, visible_count)
            batch_size = end_idx - start_idx + 1

            batch_start_byte = (start_idx - 1) * 2 + 1  # Positions are interleaved: x1,y1,x2,y2,...
            batch_end_byte = end_idx * 2
            batch_positions = view(positions_f32, batch_start_byte:batch_end_byte)

            @timeit render_loop_timer "upload_vbo" begin
                vao_data = getdata_dynamic_glvao(glmap, prog, :Particles_VAO)
                update_dynamic_vao!(vao_data.vbo_id, batch_positions)
                set_dynamic_vao_draw_count!(glmap, prog, :Particles_VAO, batch_size)
            end

            @timeit render_loop_timer "gl_draw" begin
                glUseProgram(getid_glprog(glmap, prog))
                glBindVertexArray(getid_dynamic_glvao(glmap, prog, :Particles_VAO))
                set_gluniform(glmap, prog, :particle_size, group.size)
                set_gluniform(glmap, prog, :particle_colour, group.colour)
                glDrawArrays(GL_POINTS, 0, batch_size)
            end
        end

        glBindVertexArray(0)
        glUseProgram(0)
    end

    return nothing
end

"""
Render all particle groups in a ParticleManager with viewport culling.
Optionally accepts GameMap for ship surface culling (used for background particles).
"""
function render_particles!(
        glmap::GLObjectMap,
        manager::ParticleManager,
        viewstate::ViewState,
        timestamp::Float64,
        ups::Float64,
        gamemap::Union{GameMap, Nothing} = nothing
    )
    bottom_left, top_right = get_viewport_bounds_game_coords(viewstate)

    for group in values(manager.groups)
        render_particles!(glmap, manager, group, bottom_left, top_right, timestamp, ups, gamemap)
    end
    return nothing
end

"""
This function iterates through all tiles in the gamemap and delegates particle
spawning to each component's collect_effect_particles! implementation.
Passes per-ship render position offset to particle spawning.
"""
function tile_particle_spawn!(
        manager::ParticleManager,
        glmap::GLObjectMap,
        gamemap::GameMap,
        derivedmapstate::DerivedMapState,
        mna_state::MNA_State,
        gamestate::GameState
    )
    # Iterate components per ship so collect_effect_particles! is invoked for every ship's components
    for (ship_name, ship) in gamemap.ships
        ship_offset = get_render_offset(ship)
        for (coord, tilecomp) in get_all_components(ship)
            collect_effect_particles!(
                manager, tilecomp;
                glmap = glmap,
                mna_state = mna_state,
                derivedmapstate = derivedmapstate,
                gameticks = gamestate.ticks,
                position = coord,
                tile = coord,
                pos_offset = ship_offset
            )
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

# ===============================================================
# Module Initialisation
# ===============================================================

"Initialises HexFlowRendering, detecting dev/production mode and setting paths."
function __init__()
    # Auto-detect development mode by checking if Revise is loaded
    if isdefined(Main, :Revise)
        # Development mode: use source files directly for instant updates
        SHADER_DIR[] = joinpath(pkgdir(@__MODULE__), "src", "shaders")
        TEXTURE_ATLAS_DIR[] = joinpath(dirname(dirname(pkgdir(@__MODULE__))), 
                                        "tools", "TexturePacker", "outputs")
        @info "HexFlowRendering: Development mode (using source files for instant updates)"
    else
        # Production mode: use artifacts (bundled by JuliaC automatically)
        artifacts_toml = joinpath(pkgdir(@__MODULE__), "Artifacts.toml")
        SHADER_DIR[] = artifact_path(artifact_hash("shaders", artifacts_toml))
        TEXTURE_ATLAS_DIR[] = artifact_path(artifact_hash("texture_atlas", artifacts_toml))
        @info "HexFlowRendering: Production mode (using bundled artifacts)"
    end
end

end # module HexFlowRendering
