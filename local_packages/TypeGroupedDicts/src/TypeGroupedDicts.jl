#=
Scope: Standalone keyed storage with concrete-type grouped bulk traversal
Formatter: Runic
=#

module TypeGroupedDicts

export TypeGroupedDict, foreachvalue, foreachpair, mapreducevalues, mapreducepairs, mapvalues!, mapvalueswithkeys!

# ===============================================================
# Core representation
# ===============================================================

struct Location
    bucket::Int
    slot::Int
end

abstract type AbstractBucket{K} end

"Aligned keys and values of one exact concrete value type `T`"
struct Bucket{K, T} <: AbstractBucket{K}
    keys::Vector{K}
    values::Vector{T}
end

"""
    TypeGroupedDict{K,V}()
    TypeGroupedDict{K,V}(entries)

Create a keyed collection with key type `K` and logical value domain `V`.
Keys and values are converted on insertion; values are grouped by their exact
stored concrete type. Optional `entries` are inserted in iteration order using
normal assignment semantics, including conversion and replacement of duplicate keys.
Empty buckets are retained, including across `empty!`.

This dictionary-like collection deliberately does not subtype `AbstractDict`;
methods requiring `AbstractDict` do not automatically accept it. Use `Dict(collection)`
when an ordinary dictionary is required.

Iteration yields `Pair{K,V}` entries in unspecified order. `keys`, `values`, and `pairs` share
that order while the collection is unchanged. Ordinary iteration is read-only
and offers no specialisation guarantee; use the grouped bulk functions for
concrete-type traversal. Mutation of the same collection from traversal,
reduction, or replacement callbacks is unsupported; read-only nested traversal
is allowed.
"""
struct TypeGroupedDict{K, V}
    lookup::Dict{K, Location}
    buckets::Vector{AbstractBucket{K}}
    type_to_bucket::Dict{DataType, Int}
end

TypeGroupedDict{K, V}() where {K, V} = TypeGroupedDict{K, V}(Dict{K, Location}(), AbstractBucket{K}[], Dict{DataType, Int}())

"Build from logical key/value entries using normal insertion semantics"
function TypeGroupedDict{K, V}(entries) where {K, V}
    collection = TypeGroupedDict{K, V}()
    for (key, value) in entries
        collection[key] = value
    end
    return collection
end

# ===============================================================
# Storage helpers
# ===============================================================

"Establish a stored key without silently changing its dictionary identity"
function _stored_key(::Type{K}, key) where {K}
    key isa K && return key
    stored = convert(K, key)::K
    isequal(stored, key) || throw(Base.KeyTypeError(K, key))
    return stored
end

_stored_value(::Type{V}, value) where {V} = value isa V ? value : convert(V, value)::V

"Create storage specialised on the runtime value type"
_make_bucket(::Type{K}, ::Type{T}) where {K, T} = Bucket{K, T}(K[], T[])

"Append an accepted entry, registering its concrete type only once"
function _append!(collection::TypeGroupedDict{K}, key::K, value::T) where {K, T}
    bucket_id = get!(collection.type_to_bucket, T) do
        push!(collection.buckets, _make_bucket(K, T))
        return length(collection.buckets)
    end
    bucket = collection.buckets[bucket_id]::Bucket{K, T}
    push!(bucket.keys, key)
    push!(bucket.values, value)
    collection.lookup[key] = Location(bucket_id, length(bucket.keys))
    return nothing
end

"Remove a slot and repair the location of the final entry moved into its place"
function _drop!(collection::TypeGroupedDict, bucket::Bucket, location::Location)
    key = bucket.keys[location.slot]
    last_slot = length(bucket.keys)
    if location.slot != last_slot
        moved_key = bucket.keys[last_slot]
        bucket.keys[location.slot] = moved_key
        bucket.values[location.slot] = bucket.values[last_slot]
        collection.lookup[moved_key] = Location(location.bucket, location.slot)
    end
    pop!(bucket.keys)
    pop!(bucket.values)
    delete!(collection.lookup, key)
    return nothing
end

"Replace an accepted value, migrating buckets when needed and retaining the slot's current key"
function _replace_value!(collection::TypeGroupedDict, bucket::Bucket{K, T}, location::Location, value) where {K, T}
    if typeof(value) === T
        bucket.values[location.slot] = value
    else
        key = bucket.keys[location.slot]
        _drop!(collection, bucket, location)
        _append!(collection, key, value)
    end
    return nothing
end

"Clear aligned storage while retaining the bucket for reuse"
function _empty!(bucket::Bucket)
    empty!(bucket.keys)
    empty!(bucket.values)
    return nothing
end

_value(bucket::Bucket, slot::Int) = bucket.values[slot]
_value(collection::TypeGroupedDict, location::Location) = _value(collection.buckets[location.bucket], location.slot)

# ===============================================================
# Dictionary interface
# ===============================================================

#= ---------- Keyed operations ----------- =#

Base.length(collection::TypeGroupedDict) = length(collection.lookup)
Base.isempty(collection::TypeGroupedDict) = isempty(collection.lookup)
Base.haskey(collection::TypeGroupedDict, key) = haskey(collection.lookup, key)
Base.getindex(collection::TypeGroupedDict, key) = _value(collection, collection.lookup[key])

"Insert or replace an entry, replacing an equivalent stored key as `Dict` does"
function Base.setindex!(collection::TypeGroupedDict{K, V}, value, key) where {K, V}
    stored_key = _stored_key(K, key)
    stored_value = _stored_value(V, value)
    location = get(collection.lookup, stored_key, nothing)
    if isnothing(location)
        _append!(collection, stored_key, stored_value)
    else
        bucket = collection.buckets[location.bucket]
        bucket.keys[location.slot] = stored_key
        collection.lookup[stored_key] = location
        _replace_value!(collection, bucket, location, stored_value)
    end
    return collection
end

function Base.get(collection::TypeGroupedDict, key, default)
    location = get(collection.lookup, key, nothing)
    return isnothing(location) ? default : _value(collection, location)
end

function Base.get(default::Union{Function, Type}, collection::TypeGroupedDict, key)
    location = get(collection.lookup, key, nothing)
    return isnothing(location) ? default() : _value(collection, location)
end

Base.get!(collection::TypeGroupedDict, key, default) = get!(() -> default, collection, key)

"Return a stored value, or evaluate and insert the default if the key is absent"
function Base.get!(default::Union{Function, Type}, collection::TypeGroupedDict{K, V}, key) where {K, V}
    stored_key = _stored_key(K, key)
    location = get(collection.lookup, stored_key, nothing)
    !isnothing(location) && return _value(collection, location)

    value = _stored_value(V, default())
    # Normal assignment handles any entries inserted or removed by the default callback
    collection[stored_key] = value
    return value
end

function Base.delete!(collection::TypeGroupedDict, key)
    location = get(collection.lookup, key, nothing)
    if !isnothing(location)
        _drop!(collection, collection.buckets[location.bucket], location)
    end
    return collection
end

function Base.pop!(collection::TypeGroupedDict, key)
    location = collection.lookup[key]
    value = _value(collection, location)
    _drop!(collection, collection.buckets[location.bucket], location)
    return value
end

function Base.pop!(collection::TypeGroupedDict, key, default)
    location = get(collection.lookup, key, nothing)
    isnothing(location) && return default
    value = _value(collection, location)
    _drop!(collection, collection.buckets[location.bucket], location)
    return value
end

function Base.pop!(collection::TypeGroupedDict)
    isempty(collection) && throw(ArgumentError("collection must be non-empty"))
    key = first(keys(collection.lookup))
    return key => pop!(collection, key)
end

"Remove all entries while retaining registered buckets for reuse"
function Base.empty!(collection::TypeGroupedDict)
    empty!(collection.lookup)
    for bucket in collection.buckets
        _empty!(bucket)
    end
    return collection
end

"""
    copy!(dest::TypeGroupedDict{K,V}, src::TypeGroupedDict{K,V})

Replace all entries in `dest` with a shallow copy of `src` and return `dest`.
Stored keys and values are shared, but collection storage remains independent.
Destination buckets and their capacity are retained for reuse, including empty
buckets; source types are registered as needed. Self-copy is a no-op.
"""
function Base.copy!(dest::TypeGroupedDict{K, V}, src::TypeGroupedDict{K, V}) where {K, V}
    dest === src && return dest
    empty!(dest)
    sizehint!(dest.lookup, length(src); shrink = false)
    for bucket in src.buckets
        _copy_bucket!(dest, bucket)
    end
    return dest
end

"Bulk-copy concrete storage and rebuild locations using the destination bucket ID"
function _copy_bucket!(dest::TypeGroupedDict{K}, src::Bucket{K, T}) where {K, T}
    bucket_id = get!(dest.type_to_bucket, T) do
        push!(dest.buckets, _make_bucket(K, T))
        return length(dest.buckets)
    end
    bucket = dest.buckets[bucket_id]::Bucket{K, T}
    copy!(bucket.keys, src.keys)
    copy!(bucket.values, src.values)
    for slot in eachindex(bucket.keys)
        dest.lookup[bucket.keys[slot]] = Location(bucket_id, slot)
    end
    return nothing
end

#= ---------- Ordinary read-only iteration ----------- =#

Base.eltype(::Type{TypeGroupedDict{K, V}}) where {K, V} = Pair{K, V}
Base.IteratorSize(::Type{<:TypeGroupedDict}) = Base.HasLength()

function Base.iterate(collection::TypeGroupedDict{K, V}, state::Tuple{Int, Int} = (1, 1)) where {K, V}
    bucket_id, slot = state
    while bucket_id <= length(collection.buckets)
        entry = _iterate(collection.buckets[bucket_id], slot)
        !isnothing(entry) && return Pair{K, V}(entry.first, entry.second), (bucket_id, slot + 1)
        bucket_id += 1
        slot = 1
    end
    return nothing
end

"Read one concrete bucket slot, returning `nothing` when the bucket is exhausted"
function _iterate(bucket::Bucket, slot::Int)
    slot > length(bucket.keys) && return nothing
    return bucket.keys[slot] => bucket.values[slot]
end

struct KeyIterator{K, V}
    collection::TypeGroupedDict{K, V}
end

struct ValueIterator{K, V}
    collection::TypeGroupedDict{K, V}
end

Base.keys(collection::TypeGroupedDict) = KeyIterator(collection)
Base.values(collection::TypeGroupedDict) = ValueIterator(collection)
Base.pairs(collection::TypeGroupedDict) = collection
Base.length(iterator::Union{KeyIterator, ValueIterator}) = length(iterator.collection)
Base.eltype(::Type{KeyIterator{K, V}}) where {K, V} = K
Base.eltype(::Type{ValueIterator{K, V}}) where {K, V} = V
Base.in(key, iterator::KeyIterator) = haskey(iterator.collection, key)

function Base.iterate(iterator::Union{KeyIterator, ValueIterator}, state::Tuple{Int, Int} = (1, 1))
    result = iterate(iterator.collection, state)
    isnothing(result) && return nothing
    entry, next_state = result
    return _project(iterator, entry), next_state
end

_project(::KeyIterator, entry::Pair) = entry.first
_project(::ValueIterator, entry::Pair) = entry.second

# ===============================================================
# Specialised grouped operations
# ===============================================================

#= ---------- Read-only traversal ----------- =#

"""
    foreachvalue(f, collection::TypeGroupedDict)

Call `f(value)` once per entry in unspecified order, ignoring its return value.
Traversal specialises on each concrete bucket type and returns `nothing`.
The callback must not mutate the collection; read-only nested traversal is allowed.
"""
function foreachvalue(f::F, collection::TypeGroupedDict) where {F}
    for bucket in collection.buckets
        _foreachvalue(f, bucket)
    end
    return nothing
end

"Traverse a concrete value vector with a specialised callback"
function _foreachvalue(f::F, bucket::Bucket{K, T}) where {F, K, T}
    for value in bucket.values
        f(value)
    end
    return nothing
end

"""
    foreachpair(f, collection::TypeGroupedDict)

Call `f(key, value)` once per entry in unspecified order, ignoring its return
value. Traversal specialises on each concrete bucket type and returns `nothing`.
The callback must not mutate the collection; read-only nested traversal is allowed.
"""
function foreachpair(f::F, collection::TypeGroupedDict) where {F}
    for bucket in collection.buckets
        _foreachpair(f, bucket)
    end
    return nothing
end

"Traverse aligned concrete key and value vectors with a specialised callback"
function _foreachpair(f::F, bucket::Bucket{K, T}) where {F, K, T}
    for slot in eachindex(bucket.values)
        f(bucket.keys[slot], bucket.values[slot])
    end
    return nothing
end

#= ---------- Reductions ----------- =#

"""
    mapreducevalues(f, op, collection::TypeGroupedDict; init)

Reduce `f(value)` for every entry, starting with the required `init` accumulator.
Return `init` unchanged for an empty collection without calling `f` or `op`.
Each step calls `op(accumulator, mapped_value)`; `init` is used exactly once,
not once per bucket. The accumulator may change type; it is not converted to
its initial type or the collection's declared value domain.

Traversal specialises on each concrete bucket type. Entry order is unspecified;
do not rely on a particular result for order-sensitive operations. Neither
callback may mutate the collection; read-only nested traversal is allowed.
"""
function mapreducevalues(f::F, op::O, collection::TypeGroupedDict; init) where {F, O}
    accumulator = init
    for bucket in collection.buckets
        accumulator = _mapreducevalues(f, op, bucket, accumulator)
    end
    return accumulator
end

"Reduce a concrete value vector with specialised mapping and combining callbacks"
function _mapreducevalues(f::F, op::O, bucket::Bucket{K, T}, accumulator::A) where {F, O, K, T, A}
    for value in bucket.values
        accumulator = op(accumulator, f(value))
    end
    return accumulator
end

"""
    mapreducepairs(f, op, collection::TypeGroupedDict; init)

Reduce `f(key, value)` for every entry using concrete bucket specialisation.
Uses the same required initial accumulator, empty-collection, unspecified-order,
and read-only callback semantics as [`mapreducevalues`](@ref).
"""
function mapreducepairs(f::F, op::O, collection::TypeGroupedDict; init) where {F, O}
    accumulator = init
    for bucket in collection.buckets
        accumulator = _mapreducepairs(f, op, bucket, accumulator)
    end
    return accumulator
end

"Reduce aligned concrete key and value vectors with specialised callbacks"
function _mapreducepairs(f::F, op::O, bucket::Bucket{K, T}, accumulator::A) where {F, O, K, T, A}
    for slot in eachindex(bucket.values)
        accumulator = op(accumulator, f(bucket.keys[slot], bucket.values[slot]))
    end
    return accumulator
end

#= ---------- Value replacement ----------- =#

"""
    mapvalues!(f, collection::TypeGroupedDict)

Replace each value with `f(value)`, accepting or converting the result to the
declared value domain. Return the collection. Every entry present at the start
is visited exactly once in unspecified order, with concrete bucket specialisation.
Stored keys are preserved, including during cross-type migrations.

Same-type replacements are written immediately; cross-type migrations are
deferred until traversal finishes. The callback must return replacements without
mutating the collection; read-only nested traversal is allowed. If a callback or
conversion throws, earlier same-type writes remain; queued migrations have not
been applied.
"""
function mapvalues!(f::F, collection::TypeGroupedDict) where {F}
    return _mapvalues!((bucket, slot) -> f(bucket.values[slot]), collection)
end

"""
    mapvalueswithkeys!(f, collection::TypeGroupedDict)

Replace each value with `f(key, value)` and return the collection. Uses the same
conversion, key preservation, exact-once traversal, deferred migration, exception,
and callback semantics as [`mapvalues!`](@ref).
"""
function mapvalueswithkeys!(f::F, collection::TypeGroupedDict) where {F}
    return _mapvalues!((bucket, slot) -> f(bucket.keys[slot], bucket.values[slot]), collection)
end

"Map bucket slots through a specialised callback, then apply queued migrations"
function _mapvalues!(f::F, collection::TypeGroupedDict{K, V}) where {F, K, V}
    pending = nothing
    for bucket in collection.buckets
        pending = _mapvalues!(f, bucket, V, pending)
    end
    _migrate!(collection, pending)
    return collection
end

"Write same-type results directly, allocating a migration queue only when needed"
function _mapvalues!(f::F, bucket::Bucket{K, T}, ::Type{V}, pending::Union{Nothing, Vector{Pair{K, Any}}}) where {F, K, T, V}
    for slot in eachindex(bucket.values)
        value = _stored_value(V, f(bucket, slot))
        if typeof(value) === T
            bucket.values[slot] = value
        else
            if isnothing(pending)
                pending = Pair{K, Any}[]
            end
            push!(pending, Pair{K, Any}(bucket.keys[slot], value))
        end
    end
    return pending
end

_migrate!(::TypeGroupedDict, ::Nothing) = nothing

"Resolve queued migrations by key because earlier swap-and-drops can move slots"
function _migrate!(collection::TypeGroupedDict{K}, pending::Vector{Pair{K, Any}}) where {K}
    for (key, value) in pending
        location = collection.lookup[key]
        _replace_value!(collection, collection.buckets[location.bucket], location, value)
    end
    return nothing
end

# ===============================================================
# Logical equality and hashing
# ===============================================================

"Compare logical mappings, preserving missing propagation for =="
function _equal(compare::F, left::TypeGroupedDict, right::Union{TypeGroupedDict, AbstractDict}) where {F}
    right isa IdDict && return false
    length(left) != length(right) && return false
    any_missing = false
    for (key, location) in left.lookup
        haskey(right, key) || return false
        result = compare(_value(left, location), right[key])
        if ismissing(result)
            any_missing = true
        elseif !result
            return false
        end
    end
    return any_missing ? missing : true
end

Base.:(==)(left::TypeGroupedDict, right::TypeGroupedDict) = _equal(==, left, right)
Base.:(==)(left::TypeGroupedDict, right::AbstractDict) = _equal(==, left, right)
Base.:(==)(left::AbstractDict, right::TypeGroupedDict) = _equal(==, right, left)
Base.isequal(left::TypeGroupedDict, right::TypeGroupedDict) = left === right || _equal(isequal, left, right)
Base.isequal(left::TypeGroupedDict, right::AbstractDict) = _equal(isequal, left, right)
Base.isequal(left::AbstractDict, right::TypeGroupedDict) = _equal(isequal, right, left)

"Hash logical contents through the public dictionary interface (a cold, allocating path)"
Base.hash(collection::TypeGroupedDict, seed::UInt) = hash(Dict(collection), seed)

# ===============================================================
# Internal invariant checking
# ===============================================================

"Assert bidirectional locations, unique keys, and retained concrete bucket registrations"
function _check_invariants(collection::TypeGroupedDict{K, V}) where {K, V}
    @assert length(collection.buckets) == length(collection.type_to_bucket)
    seen = Set{K}()
    for (bucket_id, bucket) in enumerate(collection.buckets)
        value_type = eltype(bucket.values)
        @assert isconcretetype(value_type)
        @assert bucket isa Bucket{K, value_type}
        @assert get(collection.type_to_bucket, value_type, nothing) == bucket_id
        @assert length(bucket.keys) == length(bucket.values)
        for slot in eachindex(bucket.keys)
            key = bucket.keys[slot]
            @assert !(key in seen)
            push!(seen, key)
            @assert typeof(bucket.values[slot]) === value_type
            @assert bucket.values[slot] isa V
            @assert get(collection.lookup, key, nothing) === Location(bucket_id, slot)
        end
    end
    @assert length(seen) == length(collection.lookup) == length(collection)
    return nothing
end

end
