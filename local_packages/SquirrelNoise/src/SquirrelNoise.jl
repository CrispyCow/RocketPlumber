module SquirrelNoise

import Random

# SquirrelNoise - Julia port of Squirrel Eiserloh's SquirrelNoise5 utilities
#
# Ported from: SquirrelNoise5 (C++), Squirrel Eiserloh
# Original license: Creative Commons Attribution 3.0 US (CC-BY-3.0 US)
# See: https://creativecommons.org/licenses/by/3.0/us/

export get_noise, get_noise_zero_to_one, get_noise_neg_one_to_one, pick_element_from_noise, pick_element_from_rng
export PRIME1, PRIME2, PRIME3
export SquirrelRNG

"Convert numeric inputs to `Int32` for hashing.

Behaviour:
- `Int32` inputs are passed through unchanged.
- `UInt32` inputs preserve their bit-pattern via `reinterpret(::Int32, x)`.
- Other integer types are numerically downcast with `Int32(x)` (this will throw `InexactError` if out of range).
- `Float32` values preserve bit-pattern via `reinterpret(::Int32, x)`.
- `Float64` and other floats are first cast to `Float32` then reinterpreted as `Int32`.
"
to_int32(x::Int32) = x
to_int32(x::UInt32) = reinterpret(Int32, x)
to_int32(x::Integer) = Int32(x)
to_int32(x::Float32) = reinterpret(Int32, x)
to_int32(x::AbstractFloat) = reinterpret(Int32, Float32(x))

# ----------------------
# Low-level hashing (direct ports)
# ----------------------

# Constants (module scope)
const SQ5_BIT_NOISE1::UInt32 = UInt32(0xd2a80a3f)
const SQ5_BIT_NOISE2::UInt32 = UInt32(0xa884f197)
const SQ5_BIT_NOISE3::UInt32 = UInt32(0x6C736F4B)
const SQ5_BIT_NOISE4::UInt32 = UInt32(0xB79F3ABB)
const SQ5_BIT_NOISE5::UInt32 = UInt32(0x1b56c4f5)

const PRIME_NUMBER::Int32 = Int32(198491317)
const PRIME1::Int32 = Int32(198491317)
const PRIME2::Int32 = Int32(6542989)
const PRIME3::Int32 = Int32(357239)

"SquirrelNoise5 hash function (direct port).
Signature kept like the original: `SquirrelNoise5(position::Int32, seed::UInt32=0) -> UInt32`."
function SquirrelNoise5(position::Int32, seed::UInt32=0x00000000)
	# Preserve bit-pattern of signed Int32 as unsigned 32-bit value
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

# Alias so the underlying hash can be swapped easily
noise_function(position::Int32, seed::UInt32=0x00000000) = SquirrelNoise5(position, seed)

"Get1dNoiseUint(index::Int32, seed::UInt32=0) -> UInt32 (direct port)."
Get1dNoiseUint(index::Int32, seed::UInt32=0x00000000) = noise_function(index, seed)

"Get2dNoiseUint(indexX::Int32, indexY::Int32, seed::UInt32=0) -> UInt32 (direct port)."
function Get2dNoiseUint(indexX::Int32, indexY::Int32, seed::UInt32=0x00000000)
	return noise_function(Int32(indexX + PRIME_NUMBER * indexY), seed)
end

"Get3dNoiseUint(indexX::Int32, indexY::Int32, indexZ::Int32, seed::UInt32=0) -> UInt32 (direct port)."
function Get3dNoiseUint(indexX::Int32, indexY::Int32, indexZ::Int32, seed::UInt32=0x00000000)
	return noise_function(Int32(indexX + PRIME1 * indexY + PRIME2 * indexZ), seed)
end

"Get4dNoiseUint(indexX::Int32, indexY::Int32, indexZ::Int32, indexT::Int32, seed::UInt32=0) -> UInt32 (direct port)."
function Get4dNoiseUint(indexX::Int32, indexY::Int32, indexZ::Int32, indexT::Int32, seed::UInt32=0x00000000)
	return noise_function(Int32(indexX + PRIME1 * indexY + PRIME2 * indexZ + PRIME3 * indexT), seed)
end

# Scaling helpers
const ONE_OVER_MAX_UINT = 1.0 / float(0xFFFFFFFF)
const ONE_OVER_MAX_INT = 1.0 / float(0x7FFFFFFF)

"Get1dNoiseZeroToOne(index::Int32, seed::UInt32=0) -> Float32 (direct port)."
Get1dNoiseZeroToOne(index::Int32, seed::UInt32=0x00000000) = Float32(ONE_OVER_MAX_UINT * float(noise_function(index, seed)))

"Get2dNoiseZeroToOne(indexX::Int32, indexY::Int32, seed::UInt32=0) -> Float32 (direct port)."
Get2dNoiseZeroToOne(indexX::Int32, indexY::Int32, seed::UInt32=0x00000000) = Float32(ONE_OVER_MAX_UINT * float(Get2dNoiseUint(indexX, indexY, seed)))

"Get3dNoiseZeroToOne(indexX::Int32, indexY::Int32, indexZ::Int32, seed::UInt32=0) -> Float32 (direct port)."
Get3dNoiseZeroToOne(indexX::Int32, indexY::Int32, indexZ::Int32, seed::UInt32=0x00000000) = Float32(ONE_OVER_MAX_UINT * float(Get3dNoiseUint(indexX, indexY, indexZ, seed)))

"Get4dNoiseZeroToOne(indexX::Int32, indexY::Int32, indexZ::Int32, indexT::Int32, seed::UInt32=0) -> Float32 (direct port)."
Get4dNoiseZeroToOne(indexX::Int32, indexY::Int32, indexZ::Int32, indexT::Int32, seed::UInt32=0x00000000) = Float32(ONE_OVER_MAX_UINT * float(Get4dNoiseUint(indexX, indexY, indexZ, indexT, seed)))

"Get1dNoiseNegOneToOne(index::Int32, seed::UInt32=0) -> Float32 (direct port)."
Get1dNoiseNegOneToOne(index::Int32, seed::UInt32=0x00000000) = Float32(ONE_OVER_MAX_INT * float(reinterpret(Int32, noise_function(index, seed))))

"Get2dNoiseNegOneToOne(indexX::Int32, indexY::Int32, seed::UInt32=0) -> Float32 (direct port)."
Get2dNoiseNegOneToOne(indexX::Int32, indexY::Int32, seed::UInt32=0x00000000) = Float32(ONE_OVER_MAX_INT * float(reinterpret(Int32, Get2dNoiseUint(indexX, indexY, seed))))

"Get3dNoiseNegOneToOne(indexX::Int32, indexY::Int32, indexZ::Int32, seed::UInt32=0) -> Float32 (direct port)."
Get3dNoiseNegOneToOne(indexX::Int32, indexY::Int32, indexZ::Int32, seed::UInt32=0x00000000) = Float32(ONE_OVER_MAX_INT * float(reinterpret(Int32, Get3dNoiseUint(indexX, indexY, indexZ, seed))))

"Get4dNoiseNegOneToOne(indexX::Int32, indexY::Int32, indexZ::Int32, indexT::Int32, seed::UInt32=0) -> Float32 (direct port)."
Get4dNoiseNegOneToOne(indexX::Int32, indexY::Int32, indexZ::Int32, indexT::Int32, seed::UInt32=0x00000000) = Float32(ONE_OVER_MAX_INT * float(reinterpret(Int32, Get4dNoiseUint(indexX, indexY, indexZ, indexT, seed))))

# ----------------------
# High-level, julia-friendly wrappers (exported)
# ----------------------

"get_noise(point::NTuple{1,T} where T, seed::UInt32=0) -> UInt32
Returns raw 32-bit noise for a 1D point.
Accepts any integer type (downcast to Int32) or float (Float64 cast to Float32 then reinterpreted)."
function get_noise(point::NTuple{1,Any}, seed::UInt32=0x00000000)
	i1 = to_int32(point[1])
	return Get1dNoiseUint(i1, seed)
end

function get_noise(point::NTuple{2,Any}, seed::UInt32=0x00000000)
	i1 = to_int32(point[1]); i2 = to_int32(point[2])
	return Get2dNoiseUint(i1, i2, seed)
end

function get_noise(point::NTuple{3,Any}, seed::UInt32=0x00000000)
	i1 = to_int32(point[1]); i2 = to_int32(point[2]); i3 = to_int32(point[3])
	return Get3dNoiseUint(i1, i2, i3, seed)
end

function get_noise(point::NTuple{4,Any}, seed::UInt32=0x00000000)
	i1 = to_int32(point[1]); i2 = to_int32(point[2]); i3 = to_int32(point[3]); i4 = to_int32(point[4])
	return Get4dNoiseUint(i1, i2, i3, i4, seed)
end

# Convenience scalar overloads: allow passing a single point value directly
get_noise(x::T, seed::UInt32=0x00000000) where {T} = get_noise((x,), seed)

# Accept 1..4 element numeric vectors (duck-typed) and forward to tuple-based methods.
function get_noise(v::AbstractVector{<:Number}, seed::UInt32=0x00000000)
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

"get_noise_zero_to_one(point::NTuple{N,Any}, seed::UInt32=0) -> Float32
Returns noise mapped to [0,1]. Supports 1-4 dimensional tuples." 
function get_noise_zero_to_one(point::NTuple{N,Any}, seed::UInt32=0x00000000) where {N}
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

"get_noise_neg_one_to_one(point::NTuple{N,Any}, seed::UInt32=0) -> Float32
Returns noise mapped to [-1,1]. Supports 1-4 dimensional tuples." 
function get_noise_neg_one_to_one(point::NTuple{N,Any}, seed::UInt32=0x00000000) where {N}
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

# Convenience scalar overloads for zero-to-one and neg-one-to-one
get_noise_zero_to_one(x::T, seed::UInt32=0x00000000) where {T} = get_noise_zero_to_one((x,), seed)
get_noise_neg_one_to_one(x::T, seed::UInt32=0x00000000) where {T} = get_noise_neg_one_to_one((x,), seed)

# Duck-typed vector overloads for 1..4 element numeric vectors
function get_noise_zero_to_one(v::AbstractVector{<:Number}, seed::UInt32=0x00000000)
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

function get_noise_neg_one_to_one(v::AbstractVector{<:Number}, seed::UInt32=0x00000000)
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

"""
pick_element_helper(collection, frac::Float64) -> element
Return an element selected from `collection` using a fractional index `frac ∈ [0,1]`.
Maps `frac` to index `min(n, floor(Int, frac*n) + 1)` to preserve original behavior.
Fast-paths for indexable containers; fallback to iteration for sets/dicts.
"""
function pick_element_helper(collection::T, frac::Float64) where {T}
	n = length(collection)
	if n == 0
		throw(ArgumentError("Cant pick element, collection is empty"))
	end

	# Clamp frac to [0,1]
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

"pick_element_from_noise(collection, x::T, seed::UInt32=0) -> element
Scalar convenience overload: forwards to tuple-based implementation." 
function pick_element_from_noise(collection, x::T, seed::UInt32=0x00000000) where {T}
	return pick_element_from_noise(collection, (x,), seed)
end

"pick_element_from_noise(collection, v::AbstractVector{<:Number}, seed::UInt32=0) -> element
Duck-typed vector overload for 1..4 element numeric vectors." 
function pick_element_from_noise(collection, v::AbstractVector{<:Number}, seed::UInt32=0x00000000)
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

"pick_element_from_noise(collection, point::NTuple{N,Any}, seed::UInt32=0) -> element from collection
Returns an element from `collection` selected based on the noise value at `point`."
function pick_element_from_noise(collection::T, point::NTuple{N,Any}, seed::UInt32=0x00000000) where {T,N}
	n = length(collection)
	if n == 0
		throw(ArgumentError("Cant pick element, collection is empty"))
	end
	noise = Float64(get_noise_zero_to_one(point, seed))
	return pick_element_helper(collection, noise)
end

"pick_element_from_rng(collection, rng::AbstractRNG) -> element
Select an element from `collection` using `rng`. This mirrors the noise-based API
but derives the fractional pick from `rng` instead of a point/seed." 
function pick_element_from_rng(collection::T, rng::Random.AbstractRNG) where {T}
	n = length(collection)
	if n == 0
		throw(ArgumentError("Cant pick element, collection is empty"))
	end

	frac = rand(rng)
	return pick_element_helper(collection, Float64(frac))
end

# -------------------------------------------------
# SquirrelNoise based implimentation of AbstractRNG
# -------------------------------------------------

import Random
import Random: seed!, rand, AbstractRNG
"""
Counter-mode SquirrelNoise RNG.
- `position` is an Int32 counter fed to the underlying noise hash
- `seed` is a UInt32 seed added into the hash (matches noise API)
"""
mutable struct SquirrelRNG <: Random.AbstractRNG
	position::Int32
	seed::UInt32
end

"SquirrelRNG(seed::Integer=0) -> SquirrelRNG
Create a new counter-mode SquirrelNoise RNG. The internal counter
starts at zero. `seed` is converted to `UInt32` (truncating high bits).
"
SquirrelRNG(seed::Integer=0) = SquirrelRNG(Int32(0), UInt32(seed))

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

end # module SquirrelNoise
