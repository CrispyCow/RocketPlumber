#=
Scope: Deterministic SquirrelNoise hashing, sampling helpers, and counter-mode RNG
Formatter: Runic
=#
module SquirrelNoise

import Random
import Random: rand

# SquirrelNoise - Julia port of Squirrel Eiserloh's SquirrelNoise5 utilities
#
# Ported from: SquirrelNoise5 (C++), Squirrel Eiserloh
# Original license: Creative Commons Attribution 3.0 US (CC-BY-3.0 US)
# See: https://creativecommons.org/licenses/by/3.0/us/

export get_noise, get_noise_zero_to_one, get_noise_neg_one_to_one, pick_element_from_noise, pick_element_from_rng
export PRIME1, PRIME2, PRIME3
export SquirrelRNG

# ===============================================================
# Direct SquirrelNoise port
# ===============================================================

#= ---------- Bit-pattern conversion ----------- =#

# Convert numeric inputs to `Int32` values suitable for hashing.
#
# - `Int32` inputs pass through unchanged.
# - `UInt32` inputs preserve their bit pattern via `reinterpret(::Int32, x)`.
# - Other integer types are numerically downcast with `Int32(x)` and may throw
#   `InexactError` if out of range.
# - `Float32` values preserve their bit pattern via `reinterpret(::Int32, x)`.
# - Other floating-point values are cast to `Float32` first, then reinterpreted.
to_int32(x::Int32) = x
to_int32(x::UInt32) = reinterpret(Int32, x)
to_int32(x::Integer) = Int32(x)
to_int32(x::Float32) = reinterpret(Int32, x)
to_int32(x::AbstractFloat) = reinterpret(Int32, Float32(x))

#= ---------- Low-level hash port ----------- =#

const SQ5_BIT_NOISE1::UInt32 = UInt32(0xd2a80a3f)
const SQ5_BIT_NOISE2::UInt32 = UInt32(0xa884f197)
const SQ5_BIT_NOISE3::UInt32 = UInt32(0x6C736F4B)
const SQ5_BIT_NOISE4::UInt32 = UInt32(0xB79F3ABB)
const SQ5_BIT_NOISE5::UInt32 = UInt32(0x1b56c4f5)

const PRIME1::Int32 = Int32(198491317)
const PRIME2::Int32 = Int32(6542989)
const PRIME3::Int32 = Int32(357239)

"""
SquirrelNoise5 hash function as a direct port.

The signature is kept close to the original API.
"""
function SquirrelNoise5(position::Int32, seed::UInt32 = 0x00000000)
    # Preserve the signed `Int32` bit pattern as an unsigned 32-bit value.
    mangledBits = reinterpret(UInt32, position)
    mangledBits *= SQ5_BIT_NOISE1
    mangledBits += seed
    mangledBits = xor(mangledBits, (mangledBits >> 9))
    mangledBits += SQ5_BIT_NOISE2
    mangledBits = xor(mangledBits, (mangledBits >> 11))
    mangledBits *= SQ5_BIT_NOISE3
    mangledBits = xor(mangledBits, (mangledBits >> 13))
    mangledBits += SQ5_BIT_NOISE4
    mangledBits = xor(mangledBits, (mangledBits >> 15))
    mangledBits *= SQ5_BIT_NOISE5
    mangledBits = xor(mangledBits, (mangledBits >> 17))
    return mangledBits
end

# Alias so the underlying hash can be swapped without touching the wrappers.
noise_function(position::Int32, seed::UInt32 = 0x00000000) = SquirrelNoise5(position, seed)

"Direct-port 1D raw noise function."
Get1dNoiseUint(index::Int32, seed::UInt32 = 0x00000000) = noise_function(index, seed)

"Direct-port 2D raw noise function."
function Get2dNoiseUint(indexX::Int32, indexY::Int32, seed::UInt32 = 0x00000000)
    return noise_function(Int32(indexX + PRIME1 * indexY), seed)
end

"Direct-port 3D raw noise function."
function Get3dNoiseUint(indexX::Int32, indexY::Int32, indexZ::Int32, seed::UInt32 = 0x00000000)
    return noise_function(Int32(indexX + PRIME1 * indexY + PRIME2 * indexZ), seed)
end

"Direct-port 4D raw noise function."
function Get4dNoiseUint(indexX::Int32, indexY::Int32, indexZ::Int32, indexT::Int32, seed::UInt32 = 0x00000000)
    return noise_function(Int32(indexX + PRIME1 * indexY + PRIME2 * indexZ + PRIME3 * indexT), seed)
end

# Scale raw hashes into the exported floating-point ranges.
const ONE_OVER_MAX_UINT = 1.0 / float(0xFFFFFFFF)
const ONE_OVER_MAX_INT = 1.0 / float(0x7FFFFFFF)

"Direct-port 1D noise mapped to [0, 1]."
Get1dNoiseZeroToOne(index::Int32, seed::UInt32 = 0x00000000) = Float32(ONE_OVER_MAX_UINT * float(noise_function(index, seed)))

"Direct-port 2D noise mapped to [0, 1]."
Get2dNoiseZeroToOne(indexX::Int32, indexY::Int32, seed::UInt32 = 0x00000000) = Float32(ONE_OVER_MAX_UINT * float(Get2dNoiseUint(indexX, indexY, seed)))

"Direct-port 3D noise mapped to [0, 1]."
Get3dNoiseZeroToOne(indexX::Int32, indexY::Int32, indexZ::Int32, seed::UInt32 = 0x00000000) = Float32(ONE_OVER_MAX_UINT * float(Get3dNoiseUint(indexX, indexY, indexZ, seed)))

"Direct-port 4D noise mapped to [0, 1]."
Get4dNoiseZeroToOne(indexX::Int32, indexY::Int32, indexZ::Int32, indexT::Int32, seed::UInt32 = 0x00000000) = Float32(ONE_OVER_MAX_UINT * float(Get4dNoiseUint(indexX, indexY, indexZ, indexT, seed)))

"Direct-port 1D noise mapped to [-1, 1]."
Get1dNoiseNegOneToOne(index::Int32, seed::UInt32 = 0x00000000) = Float32(ONE_OVER_MAX_INT * float(reinterpret(Int32, noise_function(index, seed))))

"Direct-port 2D noise mapped to [-1, 1]."
Get2dNoiseNegOneToOne(indexX::Int32, indexY::Int32, seed::UInt32 = 0x00000000) = Float32(ONE_OVER_MAX_INT * float(reinterpret(Int32, Get2dNoiseUint(indexX, indexY, seed))))

"Direct-port 3D noise mapped to [-1, 1]."
Get3dNoiseNegOneToOne(indexX::Int32, indexY::Int32, indexZ::Int32, seed::UInt32 = 0x00000000) = Float32(ONE_OVER_MAX_INT * float(reinterpret(Int32, Get3dNoiseUint(indexX, indexY, indexZ, seed))))

"Direct-port 4D noise mapped to [-1, 1]."
Get4dNoiseNegOneToOne(indexX::Int32, indexY::Int32, indexZ::Int32, indexT::Int32, seed::UInt32 = 0x00000000) = Float32(ONE_OVER_MAX_INT * float(reinterpret(Int32, Get4dNoiseUint(indexX, indexY, indexZ, indexT, seed))))

# ===============================================================
# Higher-level Julia helpers
# ===============================================================

#= ---------- Public noise helpers ----------- =#

# Raw 32-bit noise wrappers accept integers via `Int32` conversion and floating-
# point values via bit-pattern reinterpretation after `Float32` conversion.
function get_noise(point::NTuple{1, Any}, seed::UInt32 = 0x00000000)
    i1 = to_int32(point[1])
    return Get1dNoiseUint(i1, seed)
end

function get_noise(point::NTuple{2, Any}, seed::UInt32 = 0x00000000)
    i1 = to_int32(point[1])
    i2 = to_int32(point[2])
    return Get2dNoiseUint(i1, i2, seed)
end

function get_noise(point::NTuple{3, Any}, seed::UInt32 = 0x00000000)
    i1 = to_int32(point[1])
    i2 = to_int32(point[2])
    i3 = to_int32(point[3])
    return Get3dNoiseUint(i1, i2, i3, seed)
end

function get_noise(point::NTuple{4, Any}, seed::UInt32 = 0x00000000)
    i1 = to_int32(point[1])
    i2 = to_int32(point[2])
    i3 = to_int32(point[3])
    i4 = to_int32(point[4])
    return Get4dNoiseUint(i1, i2, i3, i4, seed)
end

# Scalar convenience overload.
get_noise(x::T, seed::UInt32 = 0x00000000) where {T} = get_noise((x,), seed)

"""
Return raw 32-bit noise for a 1D to 4D numeric vector.

Vectors must contain between one and four elements.
"""
function get_noise(v::AbstractVector{<:Number}, seed::UInt32 = 0x00000000)
    len = length(v)
    if len == 1
        return get_noise((v[1],), seed)
    elseif len == 2
        return get_noise((v[1], v[2]), seed)
    elseif len == 3
        return get_noise((v[1], v[2], v[3]), seed)
    elseif len == 4
        return get_noise((v[1], v[2], v[3], v[4]), seed)
    else
        throw(ArgumentError("get_noise: only 1..4 element vectors are supported"))
    end
end

"""
Return noise mapped to `[0, 1]`.

Supports 1D to 4D tuples.
"""
function get_noise_zero_to_one(point::NTuple{N, Any}, seed::UInt32 = 0x00000000) where {N}
    if N == 1
        return Get1dNoiseZeroToOne(to_int32(point[1]), seed)
    elseif N == 2
        return Get2dNoiseZeroToOne(to_int32(point[1]), to_int32(point[2]), seed)
    elseif N == 3
        return Get3dNoiseZeroToOne(to_int32(point[1]), to_int32(point[2]), to_int32(point[3]), seed)
    elseif N == 4
        return Get4dNoiseZeroToOne(to_int32(point[1]), to_int32(point[2]), to_int32(point[3]), to_int32(point[4]), seed)
    else
        throw(ArgumentError("get_noise_zero_to_one: only 1..4 dimensional tuples are supported"))
    end
end

"""
Return noise mapped to `[-1, 1]`.

Supports 1D to 4D tuples.
"""
function get_noise_neg_one_to_one(point::NTuple{N, Any}, seed::UInt32 = 0x00000000) where {N}
    if N == 1
        return Get1dNoiseNegOneToOne(to_int32(point[1]), seed)
    elseif N == 2
        return Get2dNoiseNegOneToOne(to_int32(point[1]), to_int32(point[2]), seed)
    elseif N == 3
        return Get3dNoiseNegOneToOne(to_int32(point[1]), to_int32(point[2]), to_int32(point[3]), seed)
    elseif N == 4
        return Get4dNoiseNegOneToOne(to_int32(point[1]), to_int32(point[2]), to_int32(point[3]), to_int32(point[4]), seed)
    else
        throw(ArgumentError("get_noise_neg_one_to_one: only 1..4 dimensional tuples are supported"))
    end
end

# Scalar convenience overloads.
get_noise_zero_to_one(x::T, seed::UInt32 = 0x00000000) where {T} = get_noise_zero_to_one((x,), seed)
get_noise_neg_one_to_one(x::T, seed::UInt32 = 0x00000000) where {T} = get_noise_neg_one_to_one((x,), seed)

"""
Return `[0, 1]` noise for a 1D to 4D numeric vector.

Vectors must contain between one and four elements.
"""
function get_noise_zero_to_one(v::AbstractVector{<:Number}, seed::UInt32 = 0x00000000)
    len = length(v)
    if len == 1
        return get_noise_zero_to_one((v[1],), seed)
    elseif len == 2
        return get_noise_zero_to_one((v[1], v[2]), seed)
    elseif len == 3
        return get_noise_zero_to_one((v[1], v[2], v[3]), seed)
    elseif len == 4
        return get_noise_zero_to_one((v[1], v[2], v[3], v[4]), seed)
    else
        throw(ArgumentError("get_noise_zero_to_one: only 1..4 element vectors are supported"))
    end
end

"""
Return `[-1, 1]` noise for a 1D to 4D numeric vector.

Vectors must contain between one and four elements.
"""
function get_noise_neg_one_to_one(v::AbstractVector{<:Number}, seed::UInt32 = 0x00000000)
    len = length(v)
    if len == 1
        return get_noise_neg_one_to_one((v[1],), seed)
    elseif len == 2
        return get_noise_neg_one_to_one((v[1], v[2]), seed)
    elseif len == 3
        return get_noise_neg_one_to_one((v[1], v[2], v[3]), seed)
    elseif len == 4
        return get_noise_neg_one_to_one((v[1], v[2], v[3], v[4]), seed)
    else
        throw(ArgumentError("get_noise_neg_one_to_one: only 1..4 element vectors are supported"))
    end
end

#= ---------- Collection selection helpers ----------- =#

"""
Return an element selected from `collection` using a fractional index in `[0, 1]`.

Maps `frac` to `min(n, floor(Int, frac * n) + 1)` to preserve the original
behaviour. Indexable collections use direct lookup; other iterables fall back to
iteration.
"""
function pick_element_helper(collection::T, frac::Float64) where {T}
    n = length(collection)
    if n == 0
        throw(ArgumentError("Can't pick element, collection is empty"))
    end

    # Clamp into the supported fractional range before mapping to 1-based indexing.
    f = frac < 0.0 ? 0.0 : (frac > 1.0 ? 1.0 : frac)
    index = min(n, floor(Int, f * n) + 1)

    if T <: AbstractArray || T <: Tuple
        return collection[index]
    else
        i = 1
        for elem in collection
            i == index && return elem
            i += 1
        end
    end
end

"Forward a scalar point to the tuple-based noise picker."
function pick_element_from_noise(collection, x::T, seed::UInt32 = 0x00000000) where {T}
    return pick_element_from_noise(collection, (x,), seed)
end

"Forward a 1D to 4D numeric vector to the tuple-based noise picker."
function pick_element_from_noise(collection, v::AbstractVector{<:Number}, seed::UInt32 = 0x00000000)
    len = length(v)
    if len == 1
        return pick_element_from_noise(collection, (v[1],), seed)
    elseif len == 2
        return pick_element_from_noise(collection, (v[1], v[2]), seed)
    elseif len == 3
        return pick_element_from_noise(collection, (v[1], v[2], v[3]), seed)
    elseif len == 4
        return pick_element_from_noise(collection, (v[1], v[2], v[3], v[4]), seed)
    else
        throw(ArgumentError("pick_element_from_noise: only 1..4 element vectors are supported"))
    end
end

"""
Pick an element from `collection` based on the noise value at `point`.
"""
function pick_element_from_noise(collection::T, point::NTuple{N, Any}, seed::UInt32 = 0x00000000) where {T, N}
    n = length(collection)
    if n == 0
        throw(ArgumentError("Can't pick element, collection is empty"))
    end

    noise = Float64(get_noise_zero_to_one(point, seed))
    return pick_element_helper(collection, noise)
end

"""
Pick an element from `collection` using `rng`.

This mirrors the noise-based API but derives the fractional pick from the RNG
instead of a point and seed.
"""
function pick_element_from_rng(collection::T, rng::Random.AbstractRNG) where {T}
    n = length(collection)
    if n == 0
        throw(ArgumentError("Can't pick element, collection is empty"))
    end

    frac = rand(rng)
    return pick_element_helper(collection, Float64(frac))
end

#= ---------- Squirrel AbstractRNG ----------- =#

"""
Counter-mode SquirrelNoise RNG.

`position` is the `Int32` counter fed to the hash, and `seed` is the `UInt32`
seed mixed into each sample.
"""
mutable struct SquirrelRNG <: Random.AbstractRNG
    position::Int32  # Counter fed to the underlying hash
    seed::UInt32  # Seed mixed into each generated sample
end

"""
Create a new `SquirrelRNG` with its counter reset to zero.

`seed` is converted to `UInt32`, truncating any high bits.
"""
SquirrelRNG(seed::Integer = 0) = SquirrelRNG(Int32(0), UInt32(seed))

function Random.seed!(rng::SquirrelRNG, seed::Integer)
    rng.position = Int32(0)
    rng.seed = UInt32(seed)
    return rng
end

Base.copy(rng::SquirrelRNG) = SquirrelRNG(rng.position, rng.seed)

function Random.rand(rng::SquirrelRNG, ::Type{UInt32})
    v = noise_function(rng.position, rng.seed)
    rng.position = rng.position + Int32(1)
    return v
end

function Random.rand(rng::SquirrelRNG, ::Type{UInt64})
    lo = rand(rng, UInt32)
    hi = rand(rng, UInt32)
    return (UInt64(hi) << 32) | UInt64(lo)
end

function Random.rand(rng::SquirrelRNG, ::Random.SamplerTrivial{Random.CloseOpen01{Float32}})
    u = rand(rng, UInt32)
    return Float32(float(u) * (1.0f0 / 4294967296.0f0))
end

function Random.rand(rng::SquirrelRNG, ::Random.SamplerTrivial{Random.CloseOpen01{Float64}})
    u = rand(rng, UInt64)
    return float(u) * (1.0 / 18446744073709551616.0)
end

end  # module SquirrelNoise
