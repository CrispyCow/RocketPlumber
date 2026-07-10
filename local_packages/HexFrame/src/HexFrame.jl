module HexFrame

using StaticArrays, LinearAlgebra, StructEquality
import Base: +, -

# Types
export AbstractBasicCoordSystem, AbstractCartesianCoordSystem, AbstractAxialCoordSystem, AbstractDerivedCoordSystem
export CartesianCoord, AxialCoord, TileCoord, VertexCoord, PipeCoord, NodeCoord
export HexAxis, NodePos
export PipeSpanClass, SIDE_SPAN, SHORT_DIAGONAL_SPAN, LONG_DIAGONAL_SPAN
export CartesianBounds, AxialBounds

# Functions
export glvec, to_cartesian, to_axial, round_to_tile, round_to_tile_cartesian, next_enum_val, rotmat_2D
export get_rotmat, is_proper, is_axis, is_grounded, to_proper, to_vertex, to_nodecoord
export to_hexaxis, to_nodepos, get_side_pipes, round_to_side_pipe, rotate, rotate_reverse
export get_tiles, get_adjacent_tiles_for_node, get_adjacent_tiles_for_tile
export nearest_hex_axis, mirror_q_axis, transform_tile_axis, tile_orientation_matrix
export pipe_segment_length, pipe_span_class, is_side_span, is_short_diagonal_span, is_long_diagonal_span
export is_valid_pipe_segment, get_pipe_segments, common_tile_count, get_tile_containing_pipe
export get_stacking_rank, has_higher_stacking_rank
export closest_vertex, nearest_pipe_segment_from_vertex, offset_by_tile

# Lookups
export hex_rotmats

# ===============================================================
# Abstract Types
# ===============================================================

"A basic coordinate system, where math is meaningful. Uses FieldVectors."
abstract type AbstractBasicCoordSystem <: FieldVector{2, Number} end

"Any Cartesian coordinate system, must have elements x and y."
abstract type AbstractCartesianCoordSystem <: AbstractBasicCoordSystem end

"Any axial coordinate system, must have elements q and r."
abstract type AbstractAxialCoordSystem <: AbstractBasicCoordSystem end

"A derived coordinate system where maths is not meaningful. Uses normal structs."
abstract type AbstractDerivedCoordSystem end

# ===============================================================
# Basic Coordinate Types
# ===============================================================

"""
A composite datatype representing a set of coordinates in the Cartesian plane.
1.0 in this reference frame is equal to the length from the center of the hexagon to its vertex.
"""
struct CartesianCoord <: AbstractCartesianCoordSystem
    x::Float64
    y::Float64
end
@struct_hash_equal CartesianCoord

"""
A composite datatype representing coordinates in the axial coordinate frame.
Limited to integers, to represent the coordinate of an actual tile.
"""
struct TileCoord <: AbstractAxialCoordSystem
    q::Int16
    r::Int16
end
@struct_hash_equal TileCoord

"""
A composite datatype representing coordinates in the axial coordinate frame.
Allowed to be Floats.
"""
struct AxialCoord <: AbstractAxialCoordSystem
    q::Float64
    r::Float64
end
@struct_hash_equal AxialCoord

"Converts custom Basic FieldVector types to a cartesian static vector for rendering."
glvec(coord::AbstractBasicCoordSystem)::SVector{2, Float32} = to_cartesian(coord)
glvec(coord::AbstractCartesianCoordSystem)::SVector{2, Float32} = coord
glvec(coord::AbstractDerivedCoordSystem)::SVector{2, Float32} = to_cartesian(coord)

# ===============================================================
# Hex Axes and Rotations
# ===============================================================

"Hex tile vertex/axis Enum, as shown in [cubic/axial coordinate frame](https://www.redblobgames.com/grids/hexagons/#coordinates). Order must match NodePos."
@enum HexAxis::UInt8 Q_POS R_NEG S_POS Q_NEG R_POS S_NEG

"Geometry class for a valid pipe segment."
@enum PipeSpanClass::UInt8 SIDE_SPAN SHORT_DIAGONAL_SPAN LONG_DIAGONAL_SPAN

"Dict of vectors to the vertices of a hexagon relative to its center."
const hex_vert_vecs = Dict(
    Q_POS => AxialCoord(2 / 3, -1 / 3),
    R_NEG => AxialCoord(1 / 3, -2 / 3),
    S_POS => AxialCoord(-1 / 3, -1 / 3),
    Q_NEG => AxialCoord(-2 / 3, 1 / 3),
    R_POS => AxialCoord(-1 / 3, 2 / 3),
    S_NEG => AxialCoord(1 / 3, 1 / 3)
)

"Creates a 2D rotation matrix, θ in degrees."
function rotmat_2D(θ::Real)
    θ_float = convert(Float32, θ)
    return @SMatrix Float32[
        cosd(θ_float) -sind(θ_float)
        sind(θ_float) cosd(θ_float)
    ]
end

"Dict of pre-evaluated rotation matrices for all hex axis directions."
const hex_rotmats = Dict(
    Q_POS => rotmat_2D(0),
    R_NEG => rotmat_2D(300),
    S_POS => rotmat_2D(240),
    Q_NEG => rotmat_2D(180),
    R_POS => rotmat_2D(120),
    S_NEG => rotmat_2D(60)
)

"Reflection matrix across the local Q axis."
const mirror_q_mat = @SMatrix Float32[
    1 0
    0 -1
]

# ===============================================================
# Derived Coordinate Types
# ===============================================================

"""
A composite datatype representing the location of the vertex of a hexagonal grid.
Identified by a TileCoord and a HexAxis.
A 'Proper' VertexCoord should only have dir of Q_POS or Q_NEG to ensure unique representation.
"""
struct VertexCoord <: AbstractDerivedCoordSystem
    tile::TileCoord
    dir::HexAxis
end
@struct_hash_equal VertexCoord

"Type alias for cartesian bounds tuple"
const CartesianBounds = NamedTuple{(:X_POS, :X_NEG, :Y_POS, :Y_NEG), NTuple{4, Float64}}

"Type alias for axial bounds tuple (tile coordinates for each hex axis direction)"
const AxialBounds = NamedTuple{(:Q_POS, :R_NEG, :S_POS, :Q_NEG, :R_POS, :S_NEG), NTuple{6, TileCoord}}
"""
A canonical coordinate for a pipe segment between two valid hex vertices. A proper pipe has both endpoints in
proper `VertexCoord` form, has distinct endpoints, is a valid side, short diagonal, or long diagonal span, and stores
the endpoints in ascending `_vertex_proper_order_key` order.
"""
struct PipeCoord <: AbstractDerivedCoordSystem
    v1::VertexCoord
    v2::VertexCoord

    function PipeCoord(v1::VertexCoord, v2::VertexCoord)
        proper_v1 = to_proper(v1)
        proper_v2 = to_proper(v2)
        proper_v1 == proper_v2 && throw(ArgumentError("PipeCoord endpoints must be distinct"))
        is_valid_pipe_segment(proper_v1, proper_v2) || throw(ArgumentError("vertices do not form a valid pipe segment"))

        if _vertex_proper_order_key(proper_v2) < _vertex_proper_order_key(proper_v1)
            return new(proper_v2, proper_v1)
        end
        return new(proper_v1, proper_v2)
    end
end
@struct_hash_equal PipeCoord

"Dict of offset vectors to neighbour hexes, keyed by the axis direction pointing towards the neighbour."
const hex_neighbour_tiles = Dict(
    Q_POS => TileCoord(1, -1),
    R_NEG => TileCoord(0, -1),
    S_POS => TileCoord(-1, 0),
    Q_NEG => TileCoord(-1, 1),
    R_POS => TileCoord(0, 1),
    S_NEG => TileCoord(1, 0)
)

# ===============================================================
# Coordinate Conversion Functions
# ===============================================================

"Converts from tile coordinates to equivalent Cartesian coordinates."
function to_cartesian(qr::AbstractAxialCoordSystem)::CartesianCoord
    hex_to_pixel_mat = @SMatrix [3 / 2 0; -sqrt(3) / 2 -sqrt(3)]
    return hex_to_pixel_mat * qr
end
to_cartesian(xy::AbstractCartesianCoordSystem)::CartesianCoord = xy

"Converts from Cartesian coordinates to equivalent axial coordinates."
function to_axial(xy::AbstractCartesianCoordSystem)::AxialCoord
    pixel_to_hex_mat = @SMatrix [2 / 3 0; -1 / 3 -sqrt(3) / 3]
    return pixel_to_hex_mat * xy
end

"""
Rounds an axial coordinate to the hex tile it is contained within.
"""
function round_to_tile(qr::AbstractAxialCoordSystem)::TileCoord
    qr_grid = TileCoord(round(qr.q), round(qr.r))
    qr_rem = AxialCoord(qr .- qr_grid)

    if abs(qr_rem.q) >= abs(qr_rem.r)
        offset = @SVector [round(qr_rem.q + 0.5 * qr_rem.r), 0]
    else
        offset = @SVector [0, round(qr_rem.r + 0.5 * qr_rem.q)]
    end

    return qr_grid .+ offset
end

"""
Rounds Cartesian (x, y) coordinates directly to the containing hex tile.
Uses plain Float64 arithmetic without FieldVector intermediates for allocation-free use in hot loops.
Equivalent to `round_to_tile(CartesianCoord(x, y))`.
"""
@inline function round_to_tile_cartesian(x::Float64, y::Float64)::TileCoord
    # to_axial: pixel_to_hex_mat * [x, y]
    q_axial = (2.0 / 3.0) * x
    r_axial = (-1.0 / 3.0) * x + (-sqrt(3.0) / 3.0) * y

    # round_to_tile logic (inlined)
    q_grid = round(Int16, q_axial)
    r_grid = round(Int16, r_axial)
    q_rem = q_axial - Float64(q_grid)
    r_rem = r_axial - Float64(r_grid)

    if abs(q_rem) >= abs(r_rem)
        q_offset = round(Int16, q_rem + 0.5 * r_rem)
        return TileCoord(q_grid + q_offset, r_grid)
    else
        r_offset = round(Int16, r_rem + 0.5 * q_rem)
        return TileCoord(q_grid, r_grid + r_offset)
    end
end

round_to_tile(xy::AbstractCartesianCoordSystem)::TileCoord = round_to_tile_cartesian(Float64(xy.x), Float64(xy.y))

"Gets the axial coordinates of a vertex."
function to_axial(vercoord::VertexCoord)::AxialCoord
    tile_coords = vercoord.tile
    delta = hex_vert_vecs[vercoord.dir]
    return delta + tile_coords
end

"Gets the axial coordinates of a pipe segment midpoint."
function to_axial(coord::PipeCoord)::AxialCoord
    return (to_axial(coord.v1) + to_axial(coord.v2)) ./ 2
end

"Gets the cartesian coordinates of a derived type by calling to_axial."
function to_cartesian(coord::AbstractDerivedCoordSystem)
    return to_cartesian(to_axial(coord))
end

# ===============================================================
# Coordinate Translation Functions
# ===============================================================

"Offset a coordinate by a whole-tile step."
offset_by_tile(coord::TileCoord, offset::TileCoord)::TileCoord = coord + offset

function offset_by_tile(coord::VertexCoord, offset::TileCoord)::VertexCoord
    return VertexCoord(offset_by_tile(coord.tile, offset), coord.dir)
end

function offset_by_tile(coord::PipeCoord, offset::TileCoord)::PipeCoord
    return PipeCoord(offset_by_tile(coord.v1, offset), offset_by_tile(coord.v2, offset))
end

# ===============================================================
# Proper Form Functions
# ===============================================================

"Check if VertexCoord is proper."
function is_proper(vertex::VertexCoord)::Bool
    return (vertex.dir == Q_POS) || (vertex.dir == Q_NEG)
end

"""
Return VertexCoord in "Proper" form.
"""
function to_proper(vertex::VertexCoord)::VertexCoord
    # if dir is Q then vertex is already proper
    if is_proper(vertex)
        return vertex
    end

    # otherwise use precomputed adjacencies
    tile::TileCoord = TileCoord(0, 0)
    dir::HexAxis = Q_POS
    if vertex.dir == R_NEG
        tile = vertex.tile + TileCoord(1, -1)
        dir = Q_NEG
    elseif vertex.dir == S_POS
        tile = vertex.tile + TileCoord(-1, 0)
        dir = Q_POS
    elseif vertex.dir == R_POS
        tile = vertex.tile + TileCoord(-1, 1)
        dir = Q_POS
    elseif vertex.dir == S_NEG
        tile = vertex.tile + TileCoord(1, 0)
        dir = Q_NEG
    else
        error("Unexpected vertex direction in to_proper")
    end

    return VertexCoord(tile, dir)
end

"Return a pipe coordinate in canonical form."
to_proper(pipe::PipeCoord)::PipeCoord = pipe

"Return a proper vertex position as integer axial thirds, avoiding fractional axial offsets."
function _vertex_axial_thirds(vertex::VertexCoord)::Tuple{Int, Int}
    proper_vertex = to_proper(vertex)
    q_offset, r_offset = if proper_vertex.dir === Q_POS
        (2, -1)
    elseif proper_vertex.dir === Q_NEG
        (-2, 1)
    else
        error("to_proper returned an improper vertex in _vertex_axial_thirds")
    end
    q3 = 3 * Int(proper_vertex.tile.q) + q_offset
    r3 = 3 * Int(proper_vertex.tile.r) + r_offset
    return q3, r3
end

"""
Return a stable ordering key for proper pipe endpoint canonicalisation.

Vertices are first converted to proper form, so each physical vertex is represented as either a `Q_POS` or `Q_NEG`
`VertexCoord`. The key compares Cartesian ordering axes derived from integer axial thirds, followed by the axial
thirds and direction as deterministic tie-breakers.
"""
function _vertex_proper_order_key(vertex::VertexCoord)::Tuple{Int, Int, Int, Int, Int}
    proper_vertex = to_proper(vertex)
    q3, r3 = _vertex_axial_thirds(proper_vertex)
    x_key = q3
    y_key = -(q3 + 2 * r3)
    return (x_key, y_key, q3, r3, Int(proper_vertex.dir))
end

"Cartesian length between two pipe endpoint vertices."
function pipe_segment_length(v1::VertexCoord, v2::VertexCoord)::Float64
    delta = to_cartesian(v2) - to_cartesian(v1)
    return sqrt(delta.x^2 + delta.y^2)
end

"Return the number of tiles shared by two vertices."
function common_tile_count(v1::VertexCoord, v2::VertexCoord)::Int
    v2_tiles = get_tiles(v2)
    return count(tile -> tile in v2_tiles, get_tiles(v1))
end

function _pipe_span_class_from_length(length::Float64)::Union{PipeSpanClass, Nothing}
    isapprox(length, 1.0) && return SIDE_SPAN
    isapprox(length, sqrt(3.0)) && return SHORT_DIAGONAL_SPAN
    isapprox(length, 2.0) && return LONG_DIAGONAL_SPAN
    return nothing
end

"Return whether two vertices form one of the valid pipe segments."
function is_valid_pipe_segment(v1::VertexCoord, v2::VertexCoord)::Bool
    proper_v1 = to_proper(v1)
    proper_v2 = to_proper(v2)
    proper_v1 == proper_v2 && return false

    span_class = _pipe_span_class_from_length(pipe_segment_length(proper_v1, proper_v2))
    isnothing(span_class) && return false

    common_count = common_tile_count(proper_v1, proper_v2)
    if span_class === SIDE_SPAN
        return common_count == 2
    end
    return common_count == 1
end

"Return whether a pipe coordinate is geometrically valid."
is_valid_pipe_segment(pipe::PipeCoord)::Bool = is_valid_pipe_segment(pipe.v1, pipe.v2)

"Cartesian length of a pipe segment."
pipe_segment_length(pipe::PipeCoord)::Float64 = pipe_segment_length(pipe.v1, pipe.v2)

"Return the geometry class of a valid pipe segment."
function pipe_span_class(pipe::PipeCoord)::PipeSpanClass
    span_class = _pipe_span_class_from_length(pipe_segment_length(pipe))
    isnothing(span_class) && error("invalid PipeCoord length")
    return span_class
end

is_side_span(pipe::PipeCoord)::Bool = pipe_span_class(pipe) === SIDE_SPAN
is_short_diagonal_span(pipe::PipeCoord)::Bool = pipe_span_class(pipe) === SHORT_DIAGONAL_SPAN
is_long_diagonal_span(pipe::PipeCoord)::Bool = pipe_span_class(pipe) === LONG_DIAGONAL_SPAN

"""
Return a deterministic render/selection stacking rank for a pipe segment.

Higher ranks stack above lower ranks.
Long diagonals use ranks 1-3, short diagonal parallel pairs use ranks 4-6.
All side spans share rank 7.
"""
function get_stacking_rank(pipe::PipeCoord)::Int
    pipe_span_class(pipe) === SIDE_SPAN && return 7

    v1_q3, v1_r3 = _vertex_axial_thirds(pipe.v1)
    v2_q3, v2_r3 = _vertex_axial_thirds(pipe.v2)
    dq3 = abs(v2_q3 - v1_q3)
    dr3 = abs(v2_r3 - v1_r3)

    if dq3 == 4 && dr3 == 2
        return 1
    elseif dq3 == 2 && dr3 == 4
        return 2
    elseif dq3 == 2 && dr3 == 2
        return 3
    elseif dq3 == 3 && dr3 == 0
        return 4
    elseif dq3 == 3 && dr3 == 3
        return 5
    elseif dq3 == 0 && dr3 == 3
        return 6
    end

    error("unknown pipe stacking orientation")
end

"Return whether `a` should stack above `b`."
has_higher_stacking_rank(a::PipeCoord, b::PipeCoord)::Bool = get_stacking_rank(a) > get_stacking_rank(b)

"Return the number of tiles shared by both endpoints of a pipe segment."
common_tile_count(pipe::PipeCoord)::Int = common_tile_count(pipe.v1, pipe.v2)

"Return the tile that contains a non-side pipe segment."
function get_tile_containing_pipe(pipe::PipeCoord)::Union{TileCoord, Nothing}
    common_tile_count(pipe) == 1 || return nothing

    v2_tiles = get_tiles(pipe.v2)
    for tile in get_tiles(pipe.v1)
        tile in v2_tiles && return tile
    end
    error("common_tile_count reported a shared tile, but no tile was found")
end

# ===============================================================
# Neighbour and Adjacency Functions
# ===============================================================

"Returns tiles which touch to the input vertex, CCW from the Q_POS axis."
function get_tiles(vertex::VertexCoord)::NTuple{3, TileCoord}
    proper_vertex = to_proper(vertex)
    base_tile = proper_vertex.tile

    if proper_vertex.dir == Q_POS
        neighbors = (
            base_tile + TileCoord(1, -1),
            base_tile,
            base_tile + TileCoord(1, 0),
        )
    elseif proper_vertex.dir == Q_NEG
        neighbors = (
            base_tile,
            base_tile + TileCoord(-1, 0),
            base_tile + TileCoord(-1, 1),
        )
    else
        error("to_proper returned an improper vertex in get_tiles")
    end

    return neighbors
end

"Return the three vertices connected to the input vertex by side spans."
function _side_adjacent_vertices(vertex::VertexCoord)::NTuple{3, VertexCoord}
    proper_vertex = to_proper(vertex)

    if proper_vertex.dir == Q_POS
        neighbors = (
            VertexCoord(proper_vertex.tile + TileCoord(2, -1), Q_NEG),
            VertexCoord(proper_vertex.tile + TileCoord(1, -1), Q_NEG),
            VertexCoord(proper_vertex.tile + TileCoord(1, 0), Q_NEG),
        )
    elseif proper_vertex.dir == Q_NEG
        neighbors = (
            VertexCoord(proper_vertex.tile - TileCoord(2, -1), Q_POS),
            VertexCoord(proper_vertex.tile - TileCoord(1, -1), Q_POS),
            VertexCoord(proper_vertex.tile - TileCoord(1, 0), Q_POS),
        )
    else
        error("to_proper returned an improper vertex in _side_adjacent_vertices")
    end

    return neighbors
end

"Return the six side-span pipe segments bordering a tile in clockwise order."
function get_side_pipes(tile::TileCoord)::NTuple{6, PipeCoord}
    return ntuple(i -> begin
        V1 = to_proper(VertexCoord(tile, HexAxis(i - 1)))
        V2 = to_proper(VertexCoord(tile, HexAxis(i % length(instances(HexAxis)))))
        PipeCoord(V1, V2)
    end, 6)
end

"Return the three side-span pipe segments incident to a vertex in angular order."
function get_side_pipes(vertex::VertexCoord)::NTuple{3, PipeCoord}
    proper_vertex = to_proper(vertex)
    other_vertexes = _side_adjacent_vertices(proper_vertex)
    return ntuple(i -> PipeCoord(proper_vertex, other_vertexes[i]), 3)
end

"Returns valid pipe segments incident to a vertex in continuous angular order."
function get_pipe_segments(vertex::VertexCoord)::NTuple{12, PipeCoord}
    source = to_proper(vertex)
    t = source.tile

    if source.dir === Q_POS
        return (
            PipeCoord(source, VertexCoord(t + TileCoord( 2, -1), Q_NEG)),
            PipeCoord(source, VertexCoord(t + TileCoord( 1, -1), Q_POS)),
            PipeCoord(source, VertexCoord(t + TileCoord( 2, -2), Q_NEG)),
            PipeCoord(source, VertexCoord(t + TileCoord( 0, -1), Q_POS)),

            PipeCoord(source, VertexCoord(t + TileCoord( 1, -1), Q_NEG)),
            PipeCoord(source, VertexCoord(t + TileCoord(-1,  0), Q_POS)),
            PipeCoord(source, VertexCoord(t,                     Q_NEG)),
            PipeCoord(source, VertexCoord(t + TileCoord(-1,  1), Q_POS)),

            PipeCoord(source, VertexCoord(t + TileCoord( 1,  0), Q_NEG)),
            PipeCoord(source, VertexCoord(t + TileCoord( 0,  1), Q_POS)),
            PipeCoord(source, VertexCoord(t + TileCoord( 2,  0), Q_NEG)),
            PipeCoord(source, VertexCoord(t + TileCoord( 1,  0), Q_POS)),
        )
    elseif source.dir === Q_NEG
        return (
            PipeCoord(source, VertexCoord(t,                     Q_POS)),
            PipeCoord(source, VertexCoord(t + TileCoord( 1, -1), Q_NEG)),
            PipeCoord(source, VertexCoord(t + TileCoord(-1,  0), Q_POS)),
            PipeCoord(source, VertexCoord(t + TileCoord( 0, -1), Q_NEG)),

            PipeCoord(source, VertexCoord(t + TileCoord(-2,  0), Q_POS)),
            PipeCoord(source, VertexCoord(t + TileCoord(-1,  0), Q_NEG)),
            PipeCoord(source, VertexCoord(t + TileCoord(-2,  1), Q_POS)),
            PipeCoord(source, VertexCoord(t + TileCoord(-1,  1), Q_NEG)),

            PipeCoord(source, VertexCoord(t + TileCoord(-2,  2), Q_POS)),
            PipeCoord(source, VertexCoord(t + TileCoord( 0,  1), Q_NEG)),
            PipeCoord(source, VertexCoord(t + TileCoord(-1,  1), Q_POS)),
            PipeCoord(source, VertexCoord(t + TileCoord( 1,  0), Q_NEG)),
        )
    else
        error("to_proper returned an improper vertex in get_pipe_segments")
    end
end

"Returns all valid pipe segments touching or crossing a tile."
function get_pipe_segments(tile::TileCoord)::NTuple{15, PipeCoord}
    qpos = VertexCoord(tile, Q_POS)
    rneg = VertexCoord(tile, R_NEG)
    spos = VertexCoord(tile, S_POS)
    qneg = VertexCoord(tile, Q_NEG)
    rpos = VertexCoord(tile, R_POS)
    sneg = VertexCoord(tile, S_NEG)

    return (
        PipeCoord(qpos, rneg),
        PipeCoord(rneg, spos),
        PipeCoord(spos, qneg),
        PipeCoord(qneg, rpos),
        PipeCoord(rpos, sneg),
        PipeCoord(sneg, qpos),

        PipeCoord(qpos, spos),
        PipeCoord(rneg, qneg),
        PipeCoord(spos, rpos),
        PipeCoord(qneg, sneg),
        PipeCoord(rpos, qpos),
        PipeCoord(sneg, rneg),

        PipeCoord(qpos, qneg),
        PipeCoord(rneg, rpos),
        PipeCoord(spos, sneg),
    )
end

"""
Gets the closest side-span pipe to a basic coordinate.
Uses the dot product to find the most parallel vectors.
"""
function round_to_side_pipe(coord::AbstractBasicCoordSystem)::PipeCoord
    closest_tile::TileCoord = round_to_tile(coord)
    cartesian_coord = to_cartesian(coord)
    vec_from_tile_center = cartesian_coord - to_cartesian(closest_tile)

    side_pipes = get_side_pipes(closest_tile)
    side_pipe_coords = to_cartesian.(side_pipes)
    side_pipes_from_tile_center = map(x -> x - to_cartesian(closest_tile), side_pipe_coords)

    # find the largest dot product of the vectors, which will correspond to the most parallel one
    dot_products = map(x -> dot(vec_from_tile_center, x), side_pipes_from_tile_center)
    return side_pipes[argmax(dot_products)]
end

"Return the closest canonical vertex to a basic coordinate."
function closest_vertex(coord::AbstractBasicCoordSystem)::VertexCoord
    closest_tile = round_to_tile(coord)
    cartesian_coord = to_cartesian(coord)
    vertices = ntuple(i -> to_proper(VertexCoord(closest_tile, HexAxis(i - 1))), 6)
    distances = map(vertices) do vertex
        vertex_cart = to_cartesian(vertex)
        delta = cartesian_coord - vertex_cart
        return delta.x^2 + delta.y^2
    end
    return to_proper(vertices[argmin(distances)])
end

"Return the incident pipe segment whose direction from `source` best matches `coord`."
function nearest_pipe_segment_from_vertex(source::VertexCoord, coord::AbstractBasicCoordSystem)::PipeCoord
    source_vertex = to_proper(source)
    source_cart = to_cartesian(source_vertex)
    cursor_vec = to_cartesian(coord) - source_cart
    cursor_len = sqrt(cursor_vec.x^2 + cursor_vec.y^2)

    candidates = get_pipe_segments(source_vertex)
    cursor_len == 0.0 && return first(candidates)

    best_candidate = first(candidates)
    best_score = -Inf
    for candidate in candidates
        far_vertex = candidate.v1 == source_vertex ? candidate.v2 : candidate.v1
        segment_vec = to_cartesian(far_vertex) - source_cart
        segment_len = sqrt(segment_vec.x^2 + segment_vec.y^2)
        score = (cursor_vec.x * segment_vec.x + cursor_vec.y * segment_vec.y) / (cursor_len * segment_len)
        if score > best_score
            best_score = score
            best_candidate = candidate
        end
    end

    return best_candidate
end

"Gets the correct rotation matrix for a pipe segment."
function get_rotmat(pipe::PipeCoord)
    cart_vec = to_cartesian(AxialCoord(to_axial(pipe.v2) - to_axial(pipe.v1)))
    angle = atand(cart_vec.y, cart_vec.x)
    authored_axis_angle = pipe_span_class(pipe) === SHORT_DIAGONAL_SPAN ? 90.0f0 : 0.0f0
    return rotmat_2D(angle - authored_axis_angle)
end

"""
Returns the 6 tiles adjacent to a given tile coordinate.
Returns a tuple of TileCoords in counter-clockwise order starting from Q_POS direction.
Uses the hex_neighbour_tiles constant for efficient lookup.
"""
function get_adjacent_tiles_for_tile(tile::TileCoord)::NTuple{6, TileCoord}
    return (
        tile + hex_neighbour_tiles[Q_POS],
        tile + hex_neighbour_tiles[R_NEG],
        tile + hex_neighbour_tiles[S_POS],
        tile + hex_neighbour_tiles[Q_NEG],
        tile + hex_neighbour_tiles[R_POS],
        tile + hex_neighbour_tiles[S_NEG],
    )
end

# ===============================================================
# Enum Utility Functions
# ===============================================================

"Cycles through an Int based Enum, wrapping around at the end."
function next_enum_val(enum_val::T) where {T <: Enum}
    next_int = Int(enum_val) + 1
    next_int = next_int % length(instances(T))
    return T(next_int)
end

"""
Rotates an enum by an angle given in terms of another enum.
Works with any enum, but only meaningful for HexAxis.
"""
function rotate(in1::T, in2::T)::T where {T <: Enum}
    sum_int = Int(in1) + Int(in2)
    return T(sum_int % length(instances(T)))
end

"""
Computes the reverse (inverse) rotation for an enum.
For HexAxis, this gives the rotation that undoes the input rotation.
Works with any enum.
"""
function rotate_reverse(rotation::T)::T where {T <: Enum}
    num_values = length(instances(T))
    reverse_int = (num_values - Int(rotation)) % num_values
    return T(reverse_int)
end

"Reflect a hex axis across the local Q axis."
function mirror_q_axis(axis::HexAxis)::HexAxis
    if axis === Q_POS
        return Q_POS
    elseif axis === R_NEG
        return S_NEG
    elseif axis === S_POS
        return R_POS
    elseif axis === Q_NEG
        return Q_NEG
    elseif axis === R_POS
        return S_POS
    elseif axis === S_NEG
        return R_NEG
    else
        error("invalid hexaxis")
    end
end

"Transform a tile-local axis into world orientation, applying mirroring before rotation."
transform_tile_axis(axis::HexAxis, rotation::HexAxis, mirrored::Bool)::HexAxis = rotate(mirrored ? mirror_q_axis(axis) : axis, rotation)

"Return the tile orientation matrix used by render helpers and click-space conversion."
tile_orientation_matrix(rotation::HexAxis, mirrored::Bool) = mirrored ? (mirror_q_mat * hex_rotmats[rotation]) : hex_rotmats[rotation]

"""
Return the `HexAxis` whose vertex direction is closest to the given axial direction vector.
Falls back to `Q_POS` for zero-length vectors. Iterates `instances(HexAxis)` for deterministic
tie-breaking when the direction lies exactly on a sector boundary.
"""
function nearest_hex_axis(direction::AxialCoord)::HexAxis
    cart = to_cartesian(direction)
    best_axis = Q_POS
    best_dot = -Inf
    for ax in instances(HexAxis)
        ax_cart = to_cartesian(hex_vert_vecs[ax])
        d = cart.x * ax_cart.x + cart.y * ax_cart.y
        if d > best_dot
            best_dot = d
            best_axis = ax
        end
    end
    return best_axis
end

# ===============================================================
# Nodes
# ===============================================================

"""
All possible node positions on a hex tile, including three internal nodes and ground.
Order must match HexAxis.
"""
@enum NodePos::UInt8 begin
    NODE_Q_POS
    NODE_R_NEG
    NODE_S_POS
    NODE_Q_NEG
    NODE_R_POS
    NODE_S_NEG
    NODE_INTERNAL_1
    NODE_INTERNAL_2
    NODE_INTERNAL_3
    GROUND
end

"""
Coordinate of a node including a node position and the tile it is in.
In proper form if pos is NODE_Q_POS or NODE_Q_NEG, or a non-axis position.
"""
struct NodeCoord
    tile::TileCoord
    dir::NodePos
end
@struct_hash_equal NodeCoord

"Returns bool indicating if NodePos is in proper form, where its pos is NODE_Q_POS or NODE_Q_NEG, or a non-axis position."
function is_proper(pos::NodePos)::Bool
    prop_list = (
        NODE_Q_POS,
        NODE_Q_NEG,
        GROUND,
        NODE_INTERNAL_1,
        NODE_INTERNAL_2,
        NODE_INTERNAL_3,
    )
    return pos in prop_list
end

"Returns bool indicating if NodePos is an axis position, where its pos is one of the HexAxis."
function is_axis(pos::NodePos)::Bool
    axis_list = (
        NODE_Q_POS,
        NODE_R_NEG,
        NODE_S_POS,
        NODE_Q_NEG,
        NODE_R_POS,
        NODE_S_NEG,
    )
    return pos in axis_list
end
is_grounded(pos::NodePos)::Bool = (pos === GROUND)
is_grounded(node::NodeCoord)::Bool = is_grounded(node.dir)

"Converts a NodePos to a HexAxis, errors for non axis position."
function to_hexaxis(pos::NodePos)::HexAxis
    if pos === NODE_Q_POS
        return Q_POS
    elseif pos === NODE_R_NEG
        return R_NEG
    elseif pos === NODE_S_POS
        return S_POS
    elseif pos === NODE_Q_NEG
        return Q_NEG
    elseif pos === NODE_R_POS
        return R_POS
    elseif pos === NODE_S_NEG
        return S_NEG
    else
        error("Cannot convert non-axis NodePos to HexAxis")
    end
end
to_hexaxis(pos::HexAxis)::HexAxis = pos

"Converts a HexAxis to a NodePos."
function to_nodepos(axis::HexAxis)::NodePos
    if axis === Q_POS
        return NODE_Q_POS
    elseif axis === R_NEG
        return NODE_R_NEG
    elseif axis === S_POS
        return NODE_S_POS
    elseif axis === Q_NEG
        return NODE_Q_NEG
    elseif axis === R_POS
        return NODE_R_POS
    elseif axis === S_NEG
        return NODE_S_NEG
    else
        error("invalid hexaxis")
    end
end
to_nodepos(pos::NodePos)::NodePos = pos

"Converts a NodeCoord to a VertexCoord, error for non-axis handled in to_hexaxis call."
function to_vertex(node::NodeCoord)::VertexCoord
    return VertexCoord(node.tile, to_hexaxis(node.dir))
end
"Converts from a VertexCoord to a NodeCoord, also implicitly converts to proper form"
function to_nodecoord(vertex::VertexCoord)::NodeCoord
    proper_vertex = to_proper(vertex)
    if proper_vertex.dir == Q_POS
        return NodeCoord(proper_vertex.tile, NODE_Q_POS)
    elseif proper_vertex.dir == Q_NEG
        return NodeCoord(proper_vertex.tile, NODE_Q_NEG)
    else
        error("to_proper returned an improper vertex in to_nodecoord")
    end
end

"""
Converts a NodeCoord to its proper form, using the existing logic for vertex coords.
"""
function to_proper(node::NodeCoord)
    if is_proper(node.dir)
        return node
    end

    vert = to_vertex(node)
    return to_nodecoord(vert)
end

"""
Returns the tiles adjacent to a node and their corresponding HexAxis directions, as a tuple.
For edge nodes (NODE_Q_POS/NODE_Q_NEG): 3-tuple of `(TileCoord, HexAxis)`.
For internal nodes: 1-tuple of `(TileCoord, NodePos)`.
For grounded nodes: empty tuple.
"""
function get_adjacent_tiles_for_node(node::NodeCoord)
    # Internal nodes don't have neighbours, they belong only to their tile
    if node.dir === NODE_INTERNAL_1 || node.dir === NODE_INTERNAL_2 || node.dir === NODE_INTERNAL_3
        return ((node.tile, node.dir),)
    end

    # Ground nodes don't belong to any tile
    if is_grounded(node)
        return ()
    end

    proper_node = to_proper(node)
    vertex = to_vertex(proper_node)
    tiles = get_tiles(vertex)

    if proper_node.dir === NODE_Q_POS
        return (
            (tiles[1], R_POS),  # tile at (1, -1) uses R_POS to point to this node
            (tiles[2], Q_POS),  # base tile uses Q_POS
            (tiles[3], S_POS),  # tile at (1, 0) uses S_POS
        )
    elseif proper_node.dir === NODE_Q_NEG
        return (
            (tiles[1], Q_NEG),  # base tile uses Q_NEG
            (tiles[2], S_NEG),  # tile at (-1, 0) uses S_NEG
            (tiles[3], R_NEG),  # tile at (-1, 1) uses R_NEG
        )
    else
        error("to_proper returned improper node in get_adjacent_tiles_for_node")
    end
end

glvec(coord::NodeCoord)::SVector{2, Float32} = to_cartesian(to_vertex(coord))

# ===============================================================
# Type Preservation and Promotion
# ===============================================================

#= ---------- Base Conversion Methods ----------- =#

"Identity conversion for TileCoord."
Base.convert(::Type{TileCoord}, coord::TileCoord) = coord

"Identity conversion for AxialCoord."
Base.convert(::Type{AxialCoord}, coord::AxialCoord) = coord

"Identity conversion for CartesianCoord."
Base.convert(::Type{CartesianCoord}, coord::CartesianCoord) = coord

"Convert TileCoord to AxialCoord by promoting integers to floats."
Base.convert(::Type{AxialCoord}, coord::TileCoord) = AxialCoord(Float64(coord.q), Float64(coord.r))

"Convert AxialCoord to TileCoord by rounding floats to integers."
Base.convert(::Type{TileCoord}, coord::AxialCoord) = TileCoord(Int16(round(coord.q)), Int16(round(coord.r)))

"Convert axial coordinate system to CartesianCoord using transformation matrix."
Base.convert(::Type{CartesianCoord}, coord::AbstractAxialCoordSystem) = to_cartesian(coord)

"Convert CartesianCoord to AxialCoord using inverse transformation matrix."
Base.convert(::Type{AxialCoord}, coord::CartesianCoord) = to_axial(coord)

#= ---------- Promotion Rules ----------- =#

"Promote TileCoord and AxialCoord to AxialCoord (float takes precedence)."
Base.promote_rule(::Type{TileCoord}, ::Type{AxialCoord}) = AxialCoord
Base.promote_rule(::Type{AxialCoord}, ::Type{TileCoord}) = AxialCoord

"Promote AxialCoord and CartesianCoord to CartesianCoord (Cartesian takes precedence)."
Base.promote_rule(::Type{AxialCoord}, ::Type{CartesianCoord}) = CartesianCoord
Base.promote_rule(::Type{CartesianCoord}, ::Type{AxialCoord}) = CartesianCoord

"Promote TileCoord and CartesianCoord to CartesianCoord (Cartesian takes precedence)."
Base.promote_rule(::Type{TileCoord}, ::Type{CartesianCoord}) = CartesianCoord
Base.promote_rule(::Type{CartesianCoord}, ::Type{TileCoord}) = CartesianCoord

#= ---------- Arithmetic Operators ----------- =#

"Addition for same-type axial coordinates, preserving the specific type."
function Base.:+(a::T, b::T) where {T <: AbstractAxialCoordSystem}
    return T(a.q + b.q, a.r + b.r)
end

"Addition for same-type Cartesian coordinates, preserving the specific type."
function Base.:+(a::T, b::T) where {T <: AbstractCartesianCoordSystem}
    return T(a.x + b.x, a.y + b.y)
end

"Addition for mixed-type coordinates, using promotion rules."
function Base.:+(a::AbstractBasicCoordSystem, b::AbstractBasicCoordSystem)
    promoted_a, promoted_b = promote(a, b)
    return promoted_a + promoted_b
end

"Subtraction for same-type axial coordinates, preserving the specific type."
function Base.:-(a::T, b::T) where {T <: AbstractAxialCoordSystem}
    return T(a.q - b.q, a.r - b.r)
end

"Subtraction for same-type Cartesian coordinates, preserving the specific type."
function Base.:-(a::T, b::T) where {T <: AbstractCartesianCoordSystem}
    return T(a.x - b.x, a.y - b.y)
end

"Subtraction for mixed-type coordinates, using promotion rules."
function Base.:-(a::AbstractBasicCoordSystem, b::AbstractBasicCoordSystem)
    promoted_a, promoted_b = promote(a, b)
    return promoted_a - promoted_b
end

#= ---------- Equality Methods ----------- =#

"Equality comparison between TileCoord and AxialCoord."
function Base.:(==)(a::TileCoord, b::AxialCoord)
    return a.q == b.q && a.r == b.r
end

"Equality comparison between AxialCoord and TileCoord."
function Base.:(==)(a::AxialCoord, b::TileCoord)
    return a.q == b.q && a.r == b.r
end

# Componentwise approximate comparison for coordinate types
function Base.isapprox(a::CartesianCoord, b::CartesianCoord; kwargs...)
    return isapprox(a.x, b.x; kwargs...) && isapprox(a.y, b.y; kwargs...)
end

function Base.isapprox(a::AxialCoord, b::AxialCoord; kwargs...)
    return isapprox(a.q, b.q; kwargs...) && isapprox(a.r, b.r; kwargs...)
end


end # module HexFrame
