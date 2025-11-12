module RenderEngine

using ModernGL
using StaticArrays, CSyntax.CRef
using FixedPointNumbers, ColorTypes, JSON3
using TimerOutputs
using HexFlowTelemetry

export GLshadID, GLprogID, GLvaoID, GLvboID, GLtexID, GLuboID, GLspriteData
export create_renderprog, create_tex, upload_tex, VboAttribFormat, create_static_vao, create_dynamic_vao
export create_ubo, bind_ubo, set_ubo, update_dynamic_vao!
export AbstractRenderProgram, AbstractRenderUniforms, RenderCommand, uniforms_type
export GLObjectMap, getid_glprog, getid_gltex, getid_glubo, getid_glvao, getdata_glsprite
export getdata_glprog, getdata_gltex, getdata_glubo, getdata_glvao, set_gluniform
export getdata_dynamic_glvao, getid_dynamic_glvao, set_dynamic_vao_draw_count!
export setup_glprog!, setup_gltex!, setup_glubo!, set_ubo, setup_static_glvao!, setup_dynamic_glvao!, setup_glsprite!
export destroy_globj, teardown_glprog!, teardown_gltex!, teardown_glubo!, teardown_static_glvao!, teardown_dynamic_glvao!, teardown_glmap
export glrender

# ===============================================================
# OpenGL Object Type System
# ===============================================================

"Singletons for different OpenGL object types"
abstract type GLObjectKind end
struct Shader <: GLObjectKind end
struct Program <: GLObjectKind end
struct VAO <: GLObjectKind end
struct VBO <: GLObjectKind end
struct Texture <: GLObjectKind end
struct UBO <: GLObjectKind end

"one wrapper phantom typed by a GLObjectKind"
struct GLId{K <: GLObjectKind}
    id::GLuint
end

"Wrapper for the ID of an OpenGL Shader"
const GLshadID = GLId{Shader}
"Wrapper for the ID of an OpenGL Program"
const GLprogID = GLId{Program}
"Wrapper for the ID of an OpenGL Vertex Array Object"
const GLvaoID = GLId{VAO}
"Wrapper for the ID of an OpenGL Vertex Buffer Object"
const GLvboID = GLId{VBO}
"Wrapper for the ID of an OpenGL Texture"
const GLtexID = GLId{Texture}
"Wrapper for the ID of an OpenGL Uniform Buffer Object"
const GLuboID = GLId{UBO}

#= ---------- Base Function Extensions for GLId ----------- =#

"Convert GLId wrapper to raw GLuint"
Base.convert(::Type{GLuint}, x::GLId) = x.id

"Convert GLId wrapper to raw GLint"
Base.convert(::Type{GLint}, x::GLId) = GLint(x.id)
Base.unsafe_convert(::Type{GLuint}, x::GLId) = convert(GLuint, x)
Base.unsafe_convert(::Type{GLint}, x::GLId) = convert(GLint, x)

"Allow ModernGL functions to accept GLId wrappers directly"
ModernGL.GLuint(x::GLId) = convert(GLuint, x)

"Allow ModernGL functions to accept GLId wrappers directly"
ModernGL.GLint(x::GLId) = convert(GLint, x)

"Convert raw OpenGL ID to GLId wrapper"
Base.convert(::Type{GLId{K}}, x::Union{GLint, GLuint}) where {K <: GLObjectKind} = GLId{K}(GLuint(x))

"Enable pointer conversions for GLId references (needed for @cref macro)"
Base.cconvert(::Type{Ptr{GLuint}}, r::Base.RefValue{GLId{K}}) where {K} = r

"Enable pointer conversions for GLId references (needed for @cref macro)"
Base.cconvert(::Type{Ptr{GLint}}, r::Base.RefValue{GLId{K}}) where {K} = r

Base.unsafe_convert(::Type{Ptr{GLuint}}, r::Base.RefValue{GLId{K}}) where {K} =
    Ptr{GLuint}(Base.unsafe_convert(Ptr{GLId{K}}, r))
Base.unsafe_convert(::Type{Ptr{GLint}}, r::Base.RefValue{GLId{K}}) where {K} =
    Ptr{GLint}(Base.unsafe_convert(Ptr{GLId{K}}, r))

"Promote raw OpenGL IDs to GLId when mixed in expressions"
Base.promote_rule(::Type{GLId{K}}, ::Type{<:Union{GLint, GLuint}}) where {K} = GLId{K}

"Promote raw OpenGL IDs to GLId when mixed in expressions"
Base.promote_rule(::Type{<:Union{GLint, GLuint}}, ::Type{GLId{K}}) where {K} = GLId{K}

Base.zero(::Type{GLId{K}}) where {K} = GLId{K}(0)
Base.iszero(x::GLId) = x.id == 0

"Check equality between GLId wrappers of the same kind"
Base.:(==)(a::GLId{K}, b::GLId{K}) where {K} = a.id == b.id

"Hash GLId considering both kind and ID for safe use in dictionaries"
Base.hash(x::GLId{K}, h::UInt) where {K} = hash((K, x.id), h)

"Pretty printing for GLId wrappers"
Base.show(io::IO, x::GLId{K}) where {K} = print(io, string(nameof(K), "ID("), x.id, ")")

# ===============================================================
# Custom ModernGL Wrappers
# ===============================================================

function wglShaderSource(shader::GLshadID, src::String)
    glShaderSource(shader, 1, Ptr{GLchar}[pointer(src)], C_NULL)
    return nothing
end

"Wraps the various glUniform functions with a single multiple dispatched function"
wglUniform(loc::GLint, in) = throw(ArgumentError("wglUniform not yet defined for this type"))

wglUniform(loc::GLint, in::T) where {T <: Integer} = glUniform1i(loc, GLint(in))
wglUniform(loc::GLint, in::T) where {T <: Unsigned} = glUniform1i(loc, GLint(in))
wglUniform(loc::GLint, in::T) where {T <: AbstractFloat} = glUniform1f(loc, GLfloat(in))

function wglUniform(loc::GLint, in::SVector{2, T}) where {T <: AbstractFloat}
    return glUniform2f(loc, GLfloat(in[1]), GLfloat(in[2]))
end
function wglUniform(loc::GLint, in::SVector{3, T}) where {T <: AbstractFloat}
    return glUniform3f(loc, GLfloat(in[1]), GLfloat(in[2]), GLfloat(in[3]))
end
function wglUniform(loc::GLint, in::SVector{4, T}) where {T <: AbstractFloat}
    return glUniform4f(loc, GLfloat(in[1]), GLfloat(in[2]), GLfloat(in[3]), GLfloat(in[4]))
end
function wglUniform(loc::GLint, in::SMatrix{2, 2, T, 4}) where {T <: AbstractFloat}
    convin = convert(SMatrix{2, 2, GLfloat, 4}, in)
    return glUniformMatrix2fv(loc, 1, GL_FALSE, convin)
end
function wglUniform(loc::GLint, in::SMatrix{3, 3, T, 9}) where {T <: AbstractFloat}
    convin = convert(SMatrix{3, 3, GLfloat, 9}, in)
    return glUniformMatrix3fv(loc, 1, GL_FALSE, convin)
end
function wglUniform(loc::GLint, in::SMatrix{4, 4, T, 16}) where {T <: AbstractFloat}
    convin = convert(SMatrix{4, 4, GLfloat, 16}, in)
    return glUniformMatrix4fv(loc, 1, GL_FALSE, convin)
end

# ===============================================================
# OpenGL Helper Functions
# ===============================================================

"Checks the compile status of a shader and throws an error with the log if compilation fails"
function check_shader_compile_status(shader::GLshadID)
    success = GLint(0)
    @cref glGetShaderiv(shader, GL_COMPILE_STATUS, &success)
    if success == GL_FALSE
        maxLength = GLint(0)
        @cref glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &maxLength)

        log = Vector{UInt8}(undef, maxLength)
        @cref glGetShaderInfoLog(shader, maxLength, C_NULL, pointer(log))

        error("Shader compilation failed: $(String(log))")
    end
    return nothing
end

"Checks the link status of a program and throws an error with the log if linking fails"
function check_program_link_status(program::GLprogID)
    success = GLint(0)
    @cref glGetProgramiv(program, GL_LINK_STATUS, &success)
    if success == GL_FALSE
        maxLength = GLint(0)
        @cref glGetProgramiv(program, GL_INFO_LOG_LENGTH, &maxLength)

        log = Vector{UInt8}(undef, maxLength)
        @cref glGetProgramInfoLog(program, maxLength, C_NULL, pointer(log))

        error("Program linking failed: $(String(log))")
    end
    return nothing
end

"Creates and links an OpenGL shader program from vertex and fragment shader source code"
function create_renderprog(vert_shader_code::String, frag_shader_code::String)::GLprogID
    vertex_shader::GLshadID = glCreateShader(GL_VERTEX_SHADER)
    wglShaderSource(vertex_shader, vert_shader_code)
    glCompileShader(vertex_shader)
    check_shader_compile_status(vertex_shader)

    fragment_shader::GLshadID = glCreateShader(GL_FRAGMENT_SHADER)
    wglShaderSource(fragment_shader, frag_shader_code)
    glCompileShader(fragment_shader)
    check_shader_compile_status(fragment_shader)

    program::GLprogID = glCreateProgram()
    glAttachShader(program, vertex_shader)
    glAttachShader(program, fragment_shader)
    glLinkProgram(program)
    check_program_link_status(program)

    glDeleteShader(vertex_shader)
    glDeleteShader(fragment_shader)

    return program
end

"Creates and links an OpenGL shader program with a geometry shader"
function create_renderprog(vert_shader_code::String, frag_shader_code::String, geom_shader_code::String)::GLprogID
    vertex_shader::GLshadID = glCreateShader(GL_VERTEX_SHADER)
    wglShaderSource(vertex_shader, vert_shader_code)
    glCompileShader(vertex_shader)
    check_shader_compile_status(vertex_shader)

    geometry_shader::GLshadID = glCreateShader(GL_GEOMETRY_SHADER)
    wglShaderSource(geometry_shader, geom_shader_code)
    glCompileShader(geometry_shader)
    check_shader_compile_status(geometry_shader)

    fragment_shader::GLshadID = glCreateShader(GL_FRAGMENT_SHADER)
    wglShaderSource(fragment_shader, frag_shader_code)
    glCompileShader(fragment_shader)
    check_shader_compile_status(fragment_shader)

    program::GLprogID = glCreateProgram()
    glAttachShader(program, vertex_shader)
    glAttachShader(program, geometry_shader)
    glAttachShader(program, fragment_shader)
    glLinkProgram(program)
    check_program_link_status(program)

    glDeleteShader(vertex_shader)
    glDeleteShader(geometry_shader)
    glDeleteShader(fragment_shader)

    return program
end

"Creates an OpenGL texture with standard parameters but no image data uploaded yet"
function create_tex()::GLtexID
    tex = GLtexID(0)
    @cref glGenTextures(1, &tex)

    glActiveTexture(GL_TEXTURE15) # use scratchpad texture unit
    glBindTexture(GL_TEXTURE_2D, tex)

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)

    glBindTexture(GL_TEXTURE_2D, 0)
    return tex
end

"Uploads image data to an OpenGL texture. Transposes and flips to match OpenGL coordinate conventions by default"
function upload_tex(tex::GLtexID, img::AbstractMatrix{RGBA{N0f8}}; do_transpose::Bool = true, flip_y::Bool = true)
    # Transpose to match GL's left-to-right row order
    buf = do_transpose ? permutedims(img, (2, 1)) : img

    # Flip vertically to match GL's bottom-left origin
    buf = flip_y ? buf[:, end:-1:1] : buf

    w = GLsizei(size(buf, 1))
    h = GLsizei(size(buf, 2))

    glActiveTexture(GL_TEXTURE15) # use a scratchpad texture unit so we dont overwrite anything in use
    glBindTexture(GL_TEXTURE_2D, tex)

    glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, buf)

    glBindTexture(GL_TEXTURE_2D, 0)
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4)

    return nothing
end

"Allocate a UBO of given byte size and bind it to a binding point"
function create_ubo(size::Integer, binding_point::GLuint; usage::GLenum = GL_DYNAMIC_DRAW)::GLuboID
    ubo = GLuboID(0)
    @cref glGenBuffers(1, &ubo)
    glBindBuffer(GL_UNIFORM_BUFFER, ubo)
    glBufferData(GL_UNIFORM_BUFFER, size, C_NULL, usage)
    glBindBufferBase(GL_UNIFORM_BUFFER, binding_point, ubo)
    glBindBuffer(GL_UNIFORM_BUFFER, 0)
    return ubo
end

"Link a named uniform block in a program to a binding point"
function bind_ubo(program::GLprogID, block_name::String, binding_point::GLuint)
    idx = glGetUniformBlockIndex(program, block_name)
    @assert idx != GL_INVALID_INDEX "Uniform block not found in program"
    return glUniformBlockBinding(program, idx, binding_point)
end

"Update a UBO's contents from arbitrary isbits data"
function set_ubo(ubo::GLuboID, data)
    glBindBuffer(GL_UNIFORM_BUFFER, ubo)
    glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(data), data)
    return glBindBuffer(GL_UNIFORM_BUFFER, 0)
end

"Describes the format of a single tightly-packed vertex attribute in a VBO"
struct VboAttribFormat
    name::Symbol
    components::Int
    type::GLenum
    normalized::GLboolean
end

"""
Create a static VAO and configure its vertex attribute pointers from `formats`.
Uploads `vertices` and `indices` into ephemeral buffers which are then deleted.
"""
function create_static_vao(
        vertices::AbstractVector{<:Real},
        indices::AbstractVector{<:Integer},
        formats::AbstractVector{VboAttribFormat}
    )::GLvaoID

    vao = GLvaoID(0)
    @cref glGenVertexArrays(1, &vao)
    glBindVertexArray(vao)

    vbo = GLuint(0)
    @cref glGenBuffers(1, &vbo)
    glBindBuffer(GL_ARRAY_BUFFER, vbo)
    glBufferData(
        GL_ARRAY_BUFFER,
        sizeof(eltype(vertices)) * length(vertices),
        vertices, GL_STATIC_DRAW
    )

    ebo = GLuint(0)
    @cref glGenBuffers(1, &ebo)
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo)
    glBufferData(
        GL_ELEMENT_ARRAY_BUFFER,
        sizeof(eltype(indices)) * length(indices),
        indices, GL_STATIC_DRAW
    )

    # Sets up vertex attribute pointers based on formats
    stride = sum(f.components * sizeof(GLfloat) for f in formats)
    offset = 0
    for (loc, f) in enumerate(formats)
        glVertexAttribPointer(
            loc - 1, f.components, f.type, f.normalized,
            stride, Ptr{Cvoid}(offset)
        )
        glEnableVertexAttribArray(loc - 1)
        offset += f.components * sizeof(GLfloat)
    end

    glBindVertexArray(0)
    @cref glDeleteBuffers(1, &vbo)
    @cref glDeleteBuffers(1, &ebo)
    return vao
end

"""
Create a dynamic VAO with persistent VBO for runtime updates.
Does NOT delete the VBO after setup, unlike static VAOs.
Returns VAO ID and VBO ID separately for later updates.
"""
function create_dynamic_vao(
        capacity::Int,
        formats::AbstractVector{VboAttribFormat},
        usage::GLenum = GL_DYNAMIC_DRAW
    )::Tuple{GLvaoID, GLvboID}

    vao = GLvaoID(0)
    @cref glGenVertexArrays(1, &vao)
    glBindVertexArray(vao)

    vbo = GLvboID(0) # VBO is persistent and not deleted after setup
    @cref glGenBuffers(1, &vbo)
    glBindBuffer(GL_ARRAY_BUFFER, vbo)

    stride = sum(f.components * sizeof(GLfloat) for f in formats)
    buffer_size = capacity * stride
    glBufferData(GL_ARRAY_BUFFER, buffer_size, C_NULL, usage) # initialize with NULL data

    # Sets up vertex attribute pointers based on formats
    offset = 0
    for (loc, f) in enumerate(formats)
        glVertexAttribPointer(
            loc - 1, f.components, f.type, f.normalized,
            stride, Ptr{Cvoid}(offset)
        )
        glEnableVertexAttribArray(loc - 1)
        offset += f.components * sizeof(GLfloat)
    end

    glBindVertexArray(0)
    return vao, vbo
end

"Update the contents of a dynamic VAO's VBO with new vertex data."
function update_dynamic_vao!(vbo_id::GLvboID, data::AbstractVector{<:Real})
    glBindBuffer(GL_ARRAY_BUFFER, vbo_id)
    byte_count = sizeof(eltype(data)) * length(data)
    glBufferSubData(GL_ARRAY_BUFFER, 0, byte_count, data)
    glBindBuffer(GL_ARRAY_BUFFER, 0)
    return nothing
end

# ===============================================================
# OpenGL Object Destruction
# ===============================================================

"Destroys an OpenGL program object"
destroy_globj(prog::GLprogID) = glDeleteProgram(prog)

"Destroys an OpenGL texture object"
function destroy_globj(tex::GLtexID)
    @cref glDeleteTextures(1, &tex)
    return nothing
end

"Destroys an OpenGL VAO object"
function destroy_globj(vao::GLvaoID)
    @cref glDeleteVertexArrays(1, &vao)
    return nothing
end

"Destroys an OpenGL VBO object"
function destroy_globj(vbo::GLvboID)
    @cref glDeleteBuffers(1, &vbo)
    return nothing
end

"Destroys an OpenGL UBO (buffer) object"
function destroy_globj(ubo::GLuboID)
    @cref glDeleteBuffers(1, &ubo)
    return nothing
end

# ===============================================================
# Rendering Programs and Commands
# ===============================================================

"AbstractRenderPrograms are empty singletons representing an OpenGL render program"
abstract type AbstractRenderProgram end

"""
For each concrete AbstractRenderProgram P, a struct type must be created to hold its uniforms.
The uniform struct should subtype AbstractRenderUniforms{P}, and field names should match uniform names exactly.
"""
abstract type AbstractRenderUniforms{P <: AbstractRenderProgram} end

"""
A RenderCommand includes all information required to queue a render.
Includes a program (AbstractRenderProgram), a VAO name Symbol, uniforms struct, and draw height.
The inner constructor infers the program type from the uniform struct automatically.
"""
struct RenderCommand{P <: AbstractRenderProgram, U <: AbstractRenderUniforms{P}}
    program::P
    uniforms::U
    VAO::Symbol
    draw_height::Int32

    # Preferred constructor: infer program type from uniforms
    function RenderCommand(uniforms::U, VAO::Symbol, draw_height::Int32) where {P, U <: AbstractRenderUniforms{P}}
        return new{P, U}(P(), uniforms, VAO, draw_height)
    end

    # Explicit program constructor for compatibility (e.g., with Accessors.@set)
    function RenderCommand(program::P, uniforms::U, VAO::Symbol, draw_height::Int32) where {P <: AbstractRenderProgram, U <: AbstractRenderUniforms{P}}
        return new{P, U}(program, uniforms, VAO, draw_height)
    end
end

"""
Convenience constructor accepting Int64 draw heights.
Validates that the value fits within Int32 range to prevent silent clipping.
"""
function RenderCommand(uniforms::U, VAO::Symbol, draw_height::Int64) where {P, U <: AbstractRenderUniforms{P}}
    if draw_height < typemin(Int32) || draw_height > typemax(Int32)
        throw(ArgumentError("draw_height $draw_height out of Int32 range; cannot create RenderCommand"))
    end
    return RenderCommand(uniforms, VAO, Int32(draw_height))
end

"""
Trait function returning the AbstractRenderUniforms subtype associated with an AbstractRenderProgram.
Must be defined for all concrete render programs.
"""
function uniforms_type(::Type{P}) where {P <: AbstractRenderProgram}
    throw(ArgumentError("No uniforms registered for $(P). Define uniforms_type(::Type{$(P)}) = YourUniforms"))
end

# ===============================================================
# OpenGL Object Map and Data Structures
# ===============================================================

"Stores the ID of a VAO along with the number of elements it will draw"
struct GLvaoData
    id::GLvaoID
    draw_count::GLsizei
end

"Stores the ID of a dynamic VAO along with its persistent VBO for runtime updates"
struct GLdynamicVaoData
    vao_id::GLvaoID
    vbo_id::GLvboID     # Keep VBO alive (not deleted after setup)
    capacity::Int       # Maximum number of vertices this buffer can hold
    draw_count::Int     # Current number of active vertices to draw
    usage::GLenum       # GL_DYNAMIC_DRAW or GL_STREAM_DRAW
end

"Stores ID of a program along with associated VAOs, attributes, and uniform locations"
struct GLprogData
    id::GLprogID
    vaos::Dict{Symbol, GLvaoData}
    dynamic_vaos::Dict{Symbol, GLdynamicVaoData}
    vbo_attribs::Vector{VboAttribFormat}
    uniform_locs::Dict{Symbol, GLint}
end

"Stores the ID of a texture along with its size and texture unit"
struct GLtexData
    id::GLtexID
    tex_unit::GLuint
    width::UInt
    height::UInt
end

"Stores ID of a uniform buffer object along with its configuration"
struct GLuboData
    id::GLuboID
    size::Csize_t
    binding_point::GLuint
    block_name::String
end

"""
Stores all information to refer to a sprite (a logical sub-region of a texture atlas).
Sprites are not OpenGL objects directly, but metadata for rendering textured quads.
"""
struct GLspriteData
    texname::Symbol
    uv_scale::SVector{2, GLfloat} # normalized UV scale in atlas
    uv_offset::SVector{2, GLfloat} # normalized UV offset in atlas (top-origin)
    original_size_px::SVector{2, GLfloat}
    cropped_size_px::SVector{2, GLfloat}
    crop_offset_px::SVector{2, GLfloat} # pixels removed from left, top
end

"""
Stores the lookup dicts for all OpenGL objects.
Programs are looked up by AbstractRenderProgram types.
Textures, UBOs, and sprites are looked up by Symbol.
VAOs are stored within their respective program data.
"""
@kwdef struct GLObjectMap
    programs::Dict{AbstractRenderProgram, GLprogData} = Dict{AbstractRenderProgram, GLprogData}()
    textures::Dict{Symbol, GLtexData} = Dict{Symbol, GLtexData}()
    ubos::Dict{Symbol, GLuboData} = Dict{Symbol, GLuboData}()
    sprites::Dict{Symbol, GLspriteData} = Dict{Symbol, GLspriteData}()
end

#= ---------- GLObjectMap Getters ----------- =#

"Gets an OpenGL program's data from the object map"
function getdata_glprog(map::GLObjectMap, prog::AbstractRenderProgram)::GLprogData
    if !haskey(map.programs, prog)
        error("Tried to use unimplemented/unbound OpenGL program: $prog")
    end
    return map.programs[prog]
end

"Gets an OpenGL program's ID from the object map"
getid_glprog(map::GLObjectMap, prog::AbstractRenderProgram)::GLprogID = getdata_glprog(map, prog).id

"Gets an OpenGL texture's data from the object map"
function getdata_gltex(map::GLObjectMap, tex::Symbol)::GLtexData
    if !haskey(map.textures, tex)
        error("Tried to use unimplemented/unbound OpenGL texture: $tex")
    end
    return map.textures[tex]
end

"Gets an OpenGL texture's ID from the object map"
getid_gltex(map::GLObjectMap, tex::Symbol)::GLtexID = getdata_gltex(map, tex).id

"Gets a sprite's data from the object map"
function getdata_glsprite(map::GLObjectMap, sprite::Symbol)::GLspriteData
    if !haskey(map.sprites, sprite)
        error("Tried to use unimplemented/unbound sprite: $sprite")
    end
    return map.sprites[sprite]
end

"Gets an OpenGL UBO's data from the object map"
function getdata_glubo(map::GLObjectMap, ubo::Symbol)::GLuboData
    if !haskey(map.ubos, ubo)
        error("Tried to use unimplemented/unbound OpenGL UBO: $ubo")
    end
    return map.ubos[ubo]
end

"Gets an OpenGL UBO's ID from the object map"
getid_glubo(map::GLObjectMap, ubo::Symbol)::GLuboID = getdata_glubo(map, ubo).id

"Gets an OpenGL VAO's data from the object map"
function getdata_glvao(map::GLObjectMap, prog::AbstractRenderProgram, vao::Symbol)
    if !haskey(map.programs, prog)
        error("Tried to use unimplemented/unbound OpenGL program: $prog")
    end

    vaodict = map.programs[prog].vaos
    if !haskey(vaodict, vao)
        error("Tried to use VAO $vao unimplemented/unbound for OpenGL program $prog")
    end

    return vaodict[vao]
end

"Gets an OpenGL VAO's ID from the object map"
getid_glvao(map::GLObjectMap, prog::AbstractRenderProgram, vao::Symbol) = getdata_glvao(map, prog, vao).id

"Gets the location of an OpenGL uniform within a program"
function getloc_gluniform(map::GLObjectMap, prog::AbstractRenderProgram, uniform::Symbol)::GLint
    lookup = getdata_glprog(map, prog).uniform_locs
    @assert haskey(lookup, uniform) "Uniform $(uniform) not found in program $(prog)"
    return lookup[uniform]
end

"Sets the value of an OpenGL uniform using predetermined locations. Program should already be active"
function set_gluniform(map::GLObjectMap, prog::AbstractRenderProgram, uniform::Symbol, value)
    location = getloc_gluniform(map, prog, uniform)
    return wglUniform(location, value)
end

# ===============================================================
# OpenGL Object Map Setup Functions
# ===============================================================

"Finds the locations for all uniforms defined in the uniform struct for a program"
function find_uniform_locs(::Type{U}, program_id::GLprogID) where {P <: AbstractRenderProgram, U <: AbstractRenderUniforms{P}}
    fnames = fieldnames(U)
    locs = Dict{Symbol, GLint}()
    sizehint!(locs, length(fnames))
    for fname in fnames
        cname = String(fname)
        location = glGetUniformLocation(program_id, cname)
        @assert location != GLint(-1) "Uniform $(cname) not found/active in program $(program_id)"
        locs[fname] = location
    end
    return locs
end

"Creates an OpenGL program and stores its configuration in the Object Map, indexed by AbstractRenderProgram type"
function setup_glprog!(
        map::GLObjectMap,
        progname::AbstractRenderProgram,
        vert_shadercode::String,
        frag_shadercode::String,
        formats::AbstractVector{VboAttribFormat}
    )
    progid = create_renderprog(vert_shadercode, frag_shadercode)
    utype = uniforms_type(typeof(progname))
    uniformlocs = find_uniform_locs(utype, progid)
    return map.programs[progname] = GLprogData(progid, Dict{Symbol, GLvaoData}(), Dict{Symbol, GLdynamicVaoData}(), formats, uniformlocs)
end

"Creates an OpenGL program with geometry shader and stores its configuration in the Object Map"
function setup_glprog!(
        map::GLObjectMap,
        progname::AbstractRenderProgram,
        vert_shadercode::String,
        frag_shadercode::String,
        geom_shadercode::String,
        formats::AbstractVector{VboAttribFormat}
    )
    progid = create_renderprog(vert_shadercode, frag_shadercode, geom_shadercode)
    utype = uniforms_type(typeof(progname))
    uniformlocs = find_uniform_locs(utype, progid)
    return map.programs[progname] = GLprogData(progid, Dict{Symbol, GLvaoData}(), Dict{Symbol, GLdynamicVaoData}(), formats, uniformlocs)
end

"Removes an OpenGL program from the Object Map and destroys it and all its VAOs"
function teardown_glprog!(map::GLObjectMap, progname::AbstractRenderProgram)
    if !haskey(map.programs, progname)
        @warn "Attempted to teardown non-existent program: $progname"
        return nothing
    end

    progdata = map.programs[progname]

    # Destroy all associated VAOs
    for (vaoname, vaodata) in progdata.vaos
        destroy_globj(vaodata.id)
    end
    for (vaoname, dynvaodata) in progdata.dynamic_vaos
        destroy_globj(dynvaodata.vao_id)
        destroy_globj(dynvaodata.vbo_id)
    end

    # Destroy the program itself
    destroy_globj(progdata.id)
    delete!(map.programs, progname)

    return nothing
end

"Creates an OpenGL texture, loads an image into it, and stores its data in the Object Map indexed by Symbol"
function setup_gltex!(map::GLObjectMap, texname::Symbol, img::AbstractMatrix{RGBA{N0f8}})
    texid = create_tex()
    upload_tex(texid, img)

    # Allocates to next available texture unit
    max_units = 16 - 1  # Spec minimum for OpenGL 3.x+, unit 15 used as scratchpad
    texunit_index = length(map.textures) # assumes slots are filled in order, safe cause there is no deletion possible
    @assert texunit_index < max_units "Texture unit overflow for $texname"
    glActiveTexture(GL_TEXTURE0 + texunit_index)
    glBindTexture(GL_TEXTURE_2D, texid)
    glActiveTexture(GL_TEXTURE15) # restore scratchpad

    return map.textures[texname] = GLtexData(texid, texunit_index, size(img, 2), size(img, 1))
end

"Removes an OpenGL texture from the Object Map and destroys it"
function teardown_gltex!(map::GLObjectMap, texname::Symbol)
    if !haskey(map.textures, texname)
        @warn "Attempted to teardown non-existent texture: $texname"
        return nothing
    end

    texdata = map.textures[texname]

    glActiveTexture(GL_TEXTURE0 + texdata.tex_unit)
    glBindTexture(GL_TEXTURE_2D, 0)
    destroy_globj(texdata.id)
    delete!(map.textures, texname)

    return nothing
end

"Creates an OpenGL Uniform Buffer Object and stores its configuration in the Object Map indexed by Symbol"
function setup_glubo!(map::GLObjectMap, uboname::Symbol, size::Integer, binding_point::Integer, block_name::AbstractString)
    uboid = create_ubo(size, GLuint(binding_point))
    return map.ubos[uboname] = GLuboData(uboid, Csize_t(size), GLuint(binding_point), String(block_name))
end

"Removes an OpenGL UBO from the Object Map and destroys it"
function teardown_glubo!(map::GLObjectMap, uboname::Symbol)
    if !haskey(map.ubos, uboname)
        @warn "Attempted to teardown non-existent UBO: $uboname"
        return nothing
    end

    ubodata = map.ubos[uboname]

    glBindBufferBase(GL_UNIFORM_BUFFER, ubodata.binding_point, 0)
    destroy_globj(ubodata.id)
    delete!(map.ubos, uboname)

    return nothing
end

"Sets the value of a UBO already setup in the Object Map by its Symbol name"
function set_ubo(map::GLObjectMap, uboname::Symbol, data)
    # check sizes match, to at least somewhat validate data is compatible
    expectedsize = getdata_glubo(map, uboname).size
    actualsize = sizeof(data)
    @assert (expectedsize == actualsize) "Tried to set size $expectedsize UBO $uboname with data size $actualsize"

    uboid = getid_glubo(map, uboname)
    return set_ubo(uboid, data)
end

"Binds a UBO already setup in the Object Map to a program by its Symbol name"
function bind_ubo(map::GLObjectMap, program::AbstractRenderProgram, uboname::Symbol)
    progid = getid_glprog(map, program)
    ubodata = getdata_glubo(map, uboname)
    binding_point = ubodata.binding_point
    block_name = ubodata.block_name
    return bind_ubo(progid, block_name, binding_point)
end

"Creates an OpenGL Vertex Array Object and stores it with an associated program"
function setup_static_glvao!(
        map::GLObjectMap,
        progname::AbstractRenderProgram,
        vaoname::Symbol,
        vertices::AbstractVector{<:Real},
        indices::AbstractVector{<:Integer}
    )
    data = getdata_glprog(map, progname)
    formats = data.vbo_attribs
    vaoid = create_static_vao(vertices, indices, formats)
    draw_count = GLsizei(length(indices))
    return data.vaos[vaoname] = GLvaoData(vaoid, draw_count)
end

"""
Creates a dynamic VAO and stores its configuration in the Object Map.
Unlike static VAOs, the VBO persists for runtime updates.
"""
function setup_dynamic_glvao!(
        map::GLObjectMap,
        progname::AbstractRenderProgram,
        vaoname::Symbol,
        capacity::Int,
        usage::GLenum = GL_DYNAMIC_DRAW
    )
    progdata = getdata_glprog(map, progname)
    formats = progdata.vbo_attribs
    vao_id, vbo_id = create_dynamic_vao(capacity, formats, usage)

    progdata.dynamic_vaos[vaoname] = GLdynamicVaoData(vao_id, vbo_id, capacity, 0, usage)

    return nothing
end

"Gets a dynamic VAO's data from the object map"
function getdata_dynamic_glvao(map::GLObjectMap, prog::AbstractRenderProgram, vao::Symbol)
    if !haskey(map.programs, prog)
        error("Tried to use unimplemented/unbound OpenGL program: $prog")
    end
    dynamic_vao_dict = map.programs[prog].dynamic_vaos
    if !haskey(dynamic_vao_dict, vao)
        error("Tried to use dynamic VAO $vao unimplemented/unbound for OpenGL program $prog")
    end
    return dynamic_vao_dict[vao]
end

"Gets a dynamic VAO's ID from the object map"
getid_dynamic_glvao(map::GLObjectMap, prog::AbstractRenderProgram, vao::Symbol) =
    getdata_dynamic_glvao(map, prog, vao).vao_id

"""
Updates the draw count for a dynamic VAO without changing the buffer data.
This allows the renderer to know how many vertices are currently active.
"""
function set_dynamic_vao_draw_count!(map::GLObjectMap, prog::AbstractRenderProgram, vao::Symbol, count::Int)
    progdata = getdata_glprog(map, prog)
    old_data = progdata.dynamic_vaos[vao]

    @assert count <= old_data.capacity "Draw count $count exceeds capacity $(old_data.capacity)"

    progdata.dynamic_vaos[vao] = GLdynamicVaoData(
        old_data.vao_id,
        old_data.vbo_id,
        old_data.capacity,
        count,
        old_data.usage
    )

    return nothing
end

"Removes an OpenGL VAO from a program in the Object Map and destroys it"
function teardown_static_glvao!(map::GLObjectMap, progname::AbstractRenderProgram, vaoname::Symbol)
    if !haskey(map.programs, progname)
        @warn "Attempted to teardown VAO from non-existent program: $progname"
        return nothing
    end

    progdata = map.programs[progname]

    if !haskey(progdata.vaos, vaoname)
        @warn "Attempted to teardown non-existent VAO: $vaoname from program: $progname"
        return nothing
    end

    vaodata = progdata.vaos[vaoname]

    destroy_globj(vaodata.id)
    delete!(progdata.vaos, vaoname)

    return nothing
end

"Removes a dynamic OpenGL VAO from a program in the Object Map and destroys it and its VBO"
function teardown_dynamic_glvao!(map::GLObjectMap, progname::AbstractRenderProgram, vaoname::Symbol)
    if !haskey(map.programs, progname)
        @warn "Attempted to teardown dynamic VAO from non-existent program: $progname"
        return nothing
    end

    progdata = map.programs[progname]

    if !haskey(progdata.dynamic_vaos, vaoname)
        @warn "Attempted to teardown non-existent dynamic VAO: $vaoname from program: $progname"
        return nothing
    end

    dynvaodata = progdata.dynamic_vaos[vaoname]

    destroy_globj(dynvaodata.vao_id)
    destroy_globj(dynvaodata.vbo_id)
    delete!(progdata.dynamic_vaos, vaoname)

    return nothing
end

"Loads sprite data for an atlas texture into the Object Map for lookup by Symbol name"
function setup_glsprite!(map::GLObjectMap, texname::Symbol, folder::String)
    parsed_atlas = JSON3.read(read(joinpath(@__DIR__, folder, "$texname.json")))

    for (spritename, values) in parsed_atlas
        # Prefer new keys, otherwise fallback to legacy names
        if haskey(values, "uv_scale") && haskey(values, "uv_offset")
            scale_vals = values["uv_scale"]
            offset_vals = values["uv_offset"]
        else
            scale_vals = values["scale"]
            offset_vals = values["offset"]
        end
        uv_scale = SVector{2, GLfloat}(scale_vals...)
        uv_offset = SVector{2, GLfloat}(offset_vals...)

        # Read cropping metadata if present
        orig_sz = haskey(values, "original_size") ? SVector{2, GLfloat}(values["original_size"]...) : SVector{2, GLfloat}(0.0f0, 0.0f0)
        crop_sz = haskey(values, "cropped_size") ? SVector{2, GLfloat}(values["cropped_size"]...) : SVector{2, GLfloat}(0.0f0, 0.0f0)
        crop_off = haskey(values, "crop_offset") ? SVector{2, GLfloat}(values["crop_offset"]...) : SVector{2, GLfloat}(0.0f0, 0.0f0)

        # JSON crop_offset is stored with top-origin. Convert Y to renderer's bottom-origin sign
        crop_off = SVector{2, GLfloat}(crop_off[1], -crop_off[2])

        # Flip atlas PNG vertically to match GL's bottom-left origin
        uv_offset = SVector(uv_offset[1], 1.0f0 - uv_offset[2] - uv_scale[2])

        map.sprites[Symbol(spritename)] = GLspriteData(texname, uv_scale, uv_offset, orig_sz, crop_sz, crop_off)
    end
    return nothing
end

"Tears down all OpenGL objects in the GLObjectMap and clears all dictionaries"
function teardown_glmap(map::GLObjectMap)
    # Collect keys to avoid modification during iteration
    prog_keys = collect(keys(map.programs))
    for progname in prog_keys
        teardown_glprog!(map, progname)
    end

    tex_keys = collect(keys(map.textures))
    for texname in tex_keys
        teardown_gltex!(map, texname)
    end

    ubo_keys = collect(keys(map.ubos))
    for uboname in ubo_keys
        teardown_glubo!(map, uboname)
    end

    empty!(map.sprites) # Sprites have no GL objects to destroy, just clear the dict

    return nothing
end

# ===============================================================
# Rendering Functions
# ===============================================================

"""
Renders a single render command. Does not unbind its program or VAO.

NOTE: This code will be less performant with unstable types and runtime symbol field access.
There are optimization opportunities with @generated functions or compile-time Val-indexed approaches.
Left simple for now, if performance issues arise in the render loop this has room for optimization.
"""
function glrender(map::GLObjectMap, command::RenderCommand{P, U}) where {P, U}
    prog = command.program
    vao = command.VAO
    uniforms = command.uniforms

    glUseProgram(getid_glprog(map, prog))
    glBindVertexArray(getid_glvao(map, prog, vao))

    for name in fieldnames(U)
        value = getfield(uniforms, name)
        set_gluniform(map, prog, name, value)
    end

    draw_count = getdata_glvao(map, prog, vao).draw_count
    return glDrawElements(GL_TRIANGLES, draw_count, GL_UNSIGNED_INT, C_NULL)
end

"Renders the full render command queue. Includes a sorting step by draw height, then program and VAO"
function glrender(map::GLObjectMap, commands::AbstractVector{RenderCommand})
    # Sort by draw_height first (ascending), then by program type and VAO to provide stable grouping
    @timeit render_loop_timer "Sort Queue" begin
        sort!(commands; by = c -> (c.draw_height, objectid(typeof(c.program)), objectid(c.VAO)))
    end

    @timeit render_loop_timer "Draw Calls" begin
        for command in commands
            glrender(map, command)
        end
    end

    glBindVertexArray(0)
    return glUseProgram(0)
end

end # module RenderEngine
