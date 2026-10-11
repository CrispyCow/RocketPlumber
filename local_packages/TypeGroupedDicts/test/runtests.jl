#=
Scope: Behavioural, invariant, and differential tests for TypeGroupedDicts
Formatter: Runic
=#

using Test
using Random
using TypeGroupedDicts

const TGD = TypeGroupedDicts

"Build a collection with convenient test defaults"
grouped(entries; key_type = Int, value_type = Any) = TypeGroupedDict{key_type, value_type}(entries)

"Check logical contents and internal consistency together"
function check_contents(collection::TypeGroupedDict, reference::Dict)
    @test TGD._check_invariants(collection) === nothing
    @test length(collection) == length(reference)
    @test isempty(collection) == isempty(reference)
    @test isequal(Dict(collection), reference)
    return nothing
end

struct LabelledKey
    id::Int
    label::String
end
Base.isequal(left::LabelledKey, right::LabelledKey) = isequal(left.id, right.id)
Base.hash(key::LabelledKey, seed::UInt) = hash(key.id, seed)

struct LossyKey
    value::Int
end
Base.convert(::Type{Int}, key::LossyKey) = key.value

struct Increment end
(::Increment)(value) = value + one(value)

struct AddKey end
(::AddKey)(key, value) = value + key

@testset "TypeGroupedDicts" begin
    @testset "Construction and empty state" begin
        collection = TypeGroupedDict{Int, Any}()
        @test !(collection isa AbstractDict)
        @test isimmutable(collection)
        @test isempty(collection)
        @test length(collection) == 0
        @test iterate(collection) === nothing
        @test isempty(collect(collection))
        @test isempty(collect(keys(collection)))
        @test isempty(collect(values(collection)))
        @test isempty(collect(pairs(collection)))
        @test eltype(collection) === Pair{Int, Any}
        @test eltype(keys(collection)) === Int
        @test eltype(values(collection)) === Any
        @test foreachvalue(error, collection) === nothing
        @test foreachpair(error, collection) === nothing
        @test mapvalues!(error, collection) === collection
        @test mapvalueswithkeys!(error, collection) === collection
        @test empty!(collection) === collection
        @test_throws KeyError collection[1]
        @test_throws KeyError pop!(collection, 1)
        @test_throws ArgumentError pop!(collection)
        @test delete!(collection, 1) === collection
        check_contents(collection, Dict{Int, Any}())
    end

    @testset "Construction from logical entries" begin
        for entries in (Dict(1 => 2, 3 => 4), [1 => 2, 3 => 4], (key => 2key for key in 1:3), (1 => 2, 1.0 => 3, 2 => 4))
            collection = TypeGroupedDict{Int, Float64}(entries)
            check_contents(collection, Dict{Int, Float64}(entries))
            rebuilt = TypeGroupedDict{Real, Real}(collection)
            check_contents(rebuilt, Dict{Real, Real}(entries))
        end
        check_contents(TypeGroupedDict{Int, Real}(Pair{Int, Real}[]), Dict{Int, Real}())
        entries = [LabelledKey(1, "first") => 1, LabelledKey(1, "last") => 2.0]
        collection = TypeGroupedDict{LabelledKey, Real}(entries)
        reference = Dict{LabelledKey, Real}(entries)
        @test only(keys(collection)) === only(keys(reference))
        check_contents(collection, reference)
        @test_throws InexactError TypeGroupedDict{Int, Int}([1.5 => 1])
        @test_throws InexactError TypeGroupedDict{Int, Int}([1 => 1.5])
        @test_throws MethodError TypeGroupedDict{Int, Int}([1 => "bad"])
        @test_throws TypeError TypeGroupedDict{Int, Int}([LossyKey(1) => 1])
    end

    @testset "Insertion, exact types, and conversion" begin
        collection = TypeGroupedDict{Int, Any}()
        entries = [
            1 => 2, 2 => 2.0, 3 => Int8(2), 4 => "two", 5 => nothing,
            6 => missing, 7 => [1, 2], 8 => (1, "two"), 9 => Int, 10 => Vector,
        ]
        reference = Dict{Int, Any}()
        for (key, value) in entries
            @test setindex!(collection, value, key) === collection
            reference[key] = value
            @test collection[key] === value
            @test haskey(collection, key)
            bucket = collection.buckets[collection.lookup[key].bucket]
            @test bucket isa TGD.Bucket{Int, typeof(value)}
            @test eltype(bucket.values) === typeof(value)
            check_contents(collection, reference)
        end
        @test length(collection.buckets) == length(unique(typeof.(last.(entries))))
        @test collection[1.0] === 2
        @test !haskey(collection, "1")
        @test_throws KeyError collection["1"]

        converted = TypeGroupedDict{Int, Float64}()
        @test setindex!(converted, 3, 1.0) === converted
        @test converted[1] === 3.0
        @test only(keys(converted.type_to_bucket)) === Float64
        @test_throws InexactError setindex!(converted, 5, 1.5)
        @test_throws MethodError setindex!(converted, "bad", 2)
        @test_throws TypeError setindex!(converted, 5, LossyKey(2))
        check_contents(converted, Dict(1 => 3.0))

        abstract_values = TypeGroupedDict{Int, Real}()
        abstract_values[1] = Int8(1)
        abstract_values[2] = 2.0
        @test Set(keys(abstract_values.type_to_bucket)) == Set([Int8, Float64])
        @test_throws MethodError setindex!(abstract_values, "bad", 1)
        check_contents(abstract_values, Dict{Int, Real}(1 => Int8(1), 2 => 2.0))

        union_values = TypeGroupedDict{Int, Union{Int, String}}()
        union_values[1] = 2
        union_values[2] = "two"
        check_contents(union_values, Dict{Int, Union{Int, String}}(1 => 2, 2 => "two"))
    end

    @testset "Replacement and equivalent keys" begin
        collection = grouped([1 => 10, 2 => 20, 3 => 30])
        location = collection.lookup[2]
        bucket = collection.buckets[location.bucket]
        old_keys = copy(bucket.keys)
        old_lookup = copy(collection.lookup)
        old_types = copy(collection.type_to_bucket)
        collection[2] = 25
        @test collection.lookup == old_lookup
        @test collection.type_to_bucket == old_types
        @test bucket.keys == old_keys
        @test collection.buckets[location.bucket] === bucket
        check_contents(collection, Dict(1 => 10, 2 => 25, 3 => 30))

        collection[2] = "twenty-five"
        @test bucket.keys == [1, 3]
        @test collection.lookup[3] === TGD.Location(location.bucket, 2)
        check_contents(collection, Dict{Int, Any}(1 => 10, 2 => "twenty-five", 3 => 30))
        for value in (2.0, nothing, 2, "two", 2.0, 2)
            collection[2] = value
            check_contents(collection, Dict{Int, Any}(1 => 10, 2 => value, 3 => 30))
        end
        @test length(collection.buckets) == 4

        original = LabelledKey(1, "original")
        equivalent = LabelledKey(1, "replacement")
        labelled = TypeGroupedDict{LabelledKey, Any}()
        reference = Dict{LabelledKey, Any}()
        for (key, value) in (original => 1, equivalent => 2, original => "two", equivalent => 2.0)
            labelled[key] = value
            reference[key] = value
            @test only(keys(labelled)) === only(keys(reference))
            @test only(keys(labelled.lookup)) === only(keys(reference))
            check_contents(labelled, reference)
        end
        @test get!(labelled, original, 99) === get!(reference, original, 99)
        @test only(keys(labelled)) === only(keys(reference))
        for mapper in (identity, _ -> "changed", _ -> 3)
            mapvalues!(mapper, labelled)
            @test only(keys(labelled)) === equivalent
            mapvalueswithkeys!((key, value) -> (key === equivalent || error("key changed"); value), labelled)
            @test only(keys(labelled.lookup)) === equivalent
            @test TGD._check_invariants(labelled) === nothing
        end

        # Equal numeric keys with distinct types follow Dict's replacement too
        numeric = TypeGroupedDict{Real, Any}()
        numeric_reference = Dict{Real, Any}()
        for (key, value) in (1 => 2, 1.0 => 3, Int8(1) => "four")
            numeric[key] = value
            numeric_reference[key] = value
            @test only(keys(numeric)) === only(keys(numeric_reference))
            check_contents(numeric, numeric_reference)
        end
    end

    @testset "Deletion, pop!, and swap-and-drop repair" begin
        collection = grouped([key => key * 10 for key in 1:5])
        bucket = only(collection.buckets)
        @test delete!(collection, 2) === collection
        @test bucket.keys == [1, 5, 3, 4]
        @test collection.lookup[5] === TGD.Location(1, 2)
        @test pop!(collection, 5) == 50
        @test bucket.keys == [1, 4, 3]
        @test collection.lookup[4] === TGD.Location(1, 2)
        @test pop!(collection, 3, :absent) == 30
        @test bucket.keys == [1, 4]
        @test delete!(collection, "absent") === collection
        @test pop!(collection, "absent", :default) === :default
        @test_throws KeyError pop!(collection, "absent")
        check_contents(collection, Dict(1 => 10, 4 => 40))

        reference = Dict(collection)
        while !isempty(collection)
            entry = pop!(collection)
            @test entry isa Pair
            @test pop!(reference, entry.first) == entry.second
            check_contents(collection, reference)
        end
        @test only(collection.buckets) === bucket
        @test isempty(bucket.keys) && isempty(bucket.values)
        @test collection.type_to_bucket[Int] == 1
        collection[10] = 100
        @test only(collection.buckets) === bucket
        check_contents(collection, Dict(10 => 100))
    end

    @testset "get and get! defaults" begin
        collection = TypeGroupedDict{Int, Float64}()
        calls = Ref(0)
        factory = () -> (calls[] += 1; 7)
        @test get(collection, 1, :absent) === :absent
        @test get(factory, collection, 1) === 7
        @test calls[] == 1
        @test isempty(collection)
        @test get!(factory, collection, 1.0) === 7.0
        @test calls[] == 2
        @test get!(factory, collection, 1) === 7.0
        @test get(factory, collection, 1) === 7.0
        @test calls[] == 2
        @test get!(collection, 1, "invalid unused default") === 7.0
        @test get!(collection, 2, 8) === 8.0
        @test get(collection, 2.0, nothing) === 8.0
        @test_throws InexactError get!(factory, collection, 1.5)
        @test_throws TypeError get!(factory, collection, LossyKey(3))
        @test calls[] == 2
        @test_throws MethodError get!(collection, 3, "invalid")
        @test_throws ErrorException get!(() -> error("factory failed"), collection, 3)
        @test !haskey(collection, 3)
        @test get(() -> 0, collection, 3) === 0
        @test !haskey(collection, 3)
        @test get!(() -> 0, collection, 3) === 0.0
        check_contents(collection, Dict(1 => 7.0, 2 => 8.0, 3 => 0.0))

        type_defaults = TypeGroupedDict{Int, Any}()
        @test get(Vector{Int}, type_defaults, 1) == Int[]
        @test isempty(type_defaults)
        @test get!(Vector{Int}, type_defaults, 1) == Int[]
        @test get!(Vector{Int}, type_defaults, 1) === type_defaults[1]
        check_contents(type_defaults, Dict(1 => Int[]))

        # Dict permits default factories to mutate storage, including their own key
        for target in (TypeGroupedDict{Int, Any}(), Dict{Int, Any}())
            @test get!(target, 4) do
                target[4] = "temporary"
                target[5] = 5
                return 4
            end === 4
            @test target[4] === 4
            @test target[5] === 5
        end
        nullable = grouped([1 => nothing, 2 => missing])
        @test get(nullable, 1, :absent) === nothing
        @test get!(error, nullable, 2) === missing
        @test pop!(nullable, 2, :absent) === missing
        @test pop!(nullable, 1) === nothing
        check_contents(nullable, Dict{Int, Any}())
    end

    @testset "Retained buckets and iterator correspondence" begin
        collection = grouped([1 => 1, 2 => "two", 3 => 3.0, 4 => nothing, 5 => 5])
        delete!(collection, 2)
        delete!(collection, 4)
        bucket_refs = copy(collection.buckets)
        registrations = copy(collection.type_to_bucket)
        key_view, value_view, pair_view = keys(collection), values(collection), pairs(collection)
        collected = collect(collection)
        @test all(entry -> entry isa eltype(collection), collection)
        @test collect(pair_view) == collected
        @test collect(key_view) == first.(collected)
        @test collect(value_view) == last.(collected)
        @test length(key_view) == length(value_view) == length(pair_view) == 3
        @test 1.0 in key_view
        @test !(99 in key_view)
        check_contents(collection, Dict{Int, Any}(1 => 1, 3 => 3.0, 5 => 5))

        @test empty!(collection) === collection
        @test collection.type_to_bucket == registrations
        @test all(collection.buckets .=== bucket_refs)
        @test all(bucket -> isempty(bucket.keys) && isempty(bucket.values), bucket_refs)
        @test isempty(collect(key_view))
        @test isempty(collect(value_view))
        @test iterate(collection) === nothing
        @test empty!(collection) === collection
        collection[7] = "seven"
        collection[8] = 8.0
        collection[9] = 9
        @test collection.type_to_bucket == registrations
        @test all(collection.buckets .=== bucket_refs)
        @test collect(key_view) == first.(collect(pair_view))
        @test collect(value_view) == last.(collect(pair_view))
        check_contents(collection, Dict{Int, Any}(7 => "seven", 8 => 8.0, 9 => 9))

        unusual = TypeGroupedDict{Any, Any}()
        for (key, value) in [NaN => 1, missing => 2, nothing => 3, -0.0 => 4, 0.0 => 5]
            unusual[key] = value
        end
        @test NaN in keys(unusual)
        @test missing in keys(unusual)
        @test unusual[-0.0] == 4
        @test unusual[0.0] == 5
        check_contents(unusual, Dict{Any, Any}(NaN => 1, missing => 2, nothing => 3, -0.0 => 4, 0.0 => 5))
    end

    @testset "copy! replacement and storage reuse" begin
        src = grouped([1 => 10, 2 => "two", 3 => 30, 4 => 4.0, 5 => nothing])
        delete!(src, 1)  # Repaired slot order must remain aligned
        delete!(src, 5)  # Retained empty source bucket
        dest = grouped([99 => :old, 2 => 2.0, 98 => "old", 97 => true])
        delete!(dest, 97)  # Retained empty destination bucket
        bucket_refs = copy(dest.buckets)
        registrations = copy(dest.type_to_bucket)
        lookup, buckets, types = dest.lookup, dest.buckets, dest.type_to_bucket
        original = Dict(src)

        @test copy!(dest, src) === dest
        check_contents(dest, original)
        check_contents(src, original)
        @test dest.lookup === lookup
        @test dest.buckets === buckets
        @test dest.type_to_bucket === types
        for (value_type, bucket_id) in registrations
            @test dest.type_to_bucket[value_type] == bucket_id
            @test dest.buckets[bucket_id] === bucket_refs[bucket_id]
        end
        @test isempty(dest.buckets[registrations[Symbol]].values)
        @test isempty(dest.buckets[registrations[Bool]].values)
        @test dest.type_to_bucket[Float64] != src.type_to_bucket[Float64]
        for (value_type, bucket_id) in src.type_to_bucket
            source_bucket = src.buckets[bucket_id]
            target_bucket = dest.buckets[dest.type_to_bucket[value_type]]
            @test target_bucket.keys !== source_bucket.keys
            @test target_bucket.values !== source_bucket.values
        end

        bucket_refs = copy(dest.buckets)
        registrations = copy(dest.type_to_bucket)
        # Shrink, empty, and regrow without replacing existing storage
        for source in (grouped([7 => "seven"]), TypeGroupedDict{Int, Any}(), src)
            @test copy!(dest, source) === dest
            check_contents(dest, Dict(source))
            @test dest.type_to_bucket == registrations
            @test all(dest.buckets .=== bucket_refs)
            @test dest.lookup === lookup
        end
        locations = copy(dest.lookup)
        @test copy!(dest, dest) === dest
        check_contents(dest, original)
        @test dest.lookup == locations
        @test dest.type_to_bucket == registrations
        @test all(dest.buckets .=== bucket_refs)
        empty!(dest)
        @test copy!(dest, dest) === dest
        check_contents(dest, Dict{Int, Any}())
        @test dest.type_to_bucket == registrations
    end

    @testset "copy! stored keys and shallow values" begin
        key = LabelledKey(1, "source")
        value = [1, 2]
        src = TypeGroupedDict{LabelledKey, Any}([key => value])
        dest = TypeGroupedDict{LabelledKey, Any}([LabelledKey(1, "destination") => 0])
        @test copy!(dest, src) === dest
        @test only(keys(dest)) === key
        @test dest[key] === value
        push!(dest[key], 3)
        @test src[key] == [1, 2, 3]
        dest[key] = "replacement"
        dest[LabelledKey(2, "new")] = 2
        check_contents(src, Dict(key => value))
        delete!(src, key)
        check_contents(dest, Dict{LabelledKey, Any}(key => "replacement", LabelledKey(2, "new") => 2))

        # Abstract keys retain their actual types rather than equivalent old keys
        numeric_src = TypeGroupedDict{Real, Real}((1.0 => 2, Int8(3) => 4.0))
        numeric_dest = TypeGroupedDict{Real, Real}((1 => 9, 3.0 => 8))
        copy!(numeric_dest, numeric_src)
        @test Set(typeof.(collect(keys(numeric_dest)))) == Set([Float64, Int8])
        check_contents(numeric_dest, Dict(numeric_src))
    end

    @testset "Grouped read-only traversal" begin
        reference = Dict{Int, Any}(1 => 1, 2 => 2.0, 3 => "three", 4 => nothing, 5 => 5)
        collection = grouped(reference)
        collection[6] = :retained
        delete!(collection, 6)
        visited_values = Any[]
        @test foreachvalue(collection) do value
            push!(visited_values, value)
            return :ignored
        end === nothing
        @test length(visited_values) == length(reference)
        @test Set(visited_values) == Set(values(reference))
        visited_pairs = Pair{Int, Any}[]
        @test foreachpair(collection) do key, value
            push!(visited_pairs, key => value)
            return :ignored
        end === nothing
        @test length(visited_pairs) == length(reference)
        @test Dict(visited_pairs) == reference
        check_contents(collection, reference)
    end

    @testset "Grouped reductions" begin
        for with_keys in (false, true)
            reduce_entries = with_keys ? mapreducepairs : mapreducevalues
            collection = TypeGroupedDict{Int, Real}()
            sentinel = Ref(:untouched)
            @test reduce_entries(error, error, collection; init = sentinel) === sentinel
            collection[1] = 1
            empty!(collection)
            @test reduce_entries(error, error, collection; init = sentinel) === sentinel
            @test_throws UndefKeywordError reduce_entries(identity, +, collection)

            for (key, value) in (1 => 2, 2 => 3.0, 3 => Int8(4), 4 => 5)
                collection[key] = value
            end
            collection[99] = 1 // 2
            delete!(collection, 99)  # Retained empty bucket between reduction calls
            original = Dict(collection)
            visited = Any[]
            mapper = if with_keys
                (key, value) -> (push!(visited, key); key * value)
            else
                value -> (push!(visited, value); value)
            end
            expected = with_keys ? 2 + 6 + 12 + 20 : 2 + 3 + 4 + 5
            # Non-identity init is applied once across all concrete buckets
            @test reduce_entries(mapper, +, collection; init = 100.0) == 100 + expected
            @test length(visited) == length(collection)
            @test Set(visited) == Set(with_keys ? keys(collection) : values(collection))

            # Type-changing accumulators and structured results need no conversion
            mapper = with_keys ? ((key, value) -> value) : identity
            @test reduce_entries(mapper, +, collection; init = 0) === 14.0
            result = reduce_entries(mapper, (acc, value) -> (sum = acc.sum + value, count = acc.count + 1), collection; init = (sum = 0.0, count = 0))
            @test result == (sum = 14.0, count = 4)
            @test reduce_entries(mapper, (acc, value) -> isnothing(acc) ? value : acc + value, collection; init = nothing) == 14
            # Accumulator stays on the left without asserting entry order
            @test reduce_entries(mapper, -, collection; init = 100.0) == 86.0
            @test_throws ErrorException reduce_entries((args...) -> error("mapping failed"), +, collection; init = 0)
            @test_throws ErrorException reduce_entries(mapper, (args...) -> error("combining failed"), collection; init = 0)
            check_contents(collection, original)
        end
        singleton = TypeGroupedDict{Int, Real}([2 => 3])
        @test mapreducevalues(Increment(), *, singleton; init = 2) == 8
        @test mapreducepairs(AddKey(), *, singleton; init = 2) == 10
    end

    @testset "Same-type mapping and conversion" begin
        collection = grouped([1 => 10, 2 => 20, 3 => 3.0, 4 => 4.0])
        locations = copy(collection.lookup)
        registrations = copy(collection.type_to_bucket)
        @test mapvalues!(Increment(), collection) === collection
        @test mapvalueswithkeys!(AddKey(), collection) === collection
        @test collection.lookup == locations
        @test collection.type_to_bucket == registrations
        check_contents(collection, Dict{Int, Any}(1 => 12, 2 => 23, 3 => 7.0, 4 => 9.0))
        @test mapvalues!(identity, collection) === collection
        check_contents(collection, Dict{Int, Any}(1 => 12, 2 => 23, 3 => 7.0, 4 => 9.0))

        converted = grouped([1 => 1, 2 => 2]; value_type = Float64)
        @test mapvalues!(_ -> 3, converted) === converted
        @test mapvalueswithkeys!((key, _) -> key, converted) === converted
        @test length(converted.buckets) == 1
        @test all(value -> value isa Float64, values(converted))
        check_contents(converted, Dict(1 => 1.0, 2 => 2.0))
    end

    @testset "Concrete bucket kernel inference" begin
        for value_type in (Int, Float64)
            bucket = TGD._make_bucket(Int, value_type)
            append!(bucket.keys, 1:8)
            append!(bucket.values, 1:8)
            @test (@inferred TGD._foreachvalue(Increment(), bucket)) === nothing
            @test (@inferred TGD._foreachpair(AddKey(), bucket)) === nothing
            @test (@inferred TGD._mapreducevalues(Increment(), +, bucket, zero(value_type))) == 44
            @test (@inferred TGD._mapreducepairs(AddKey(), +, bucket, zero(value_type))) == 72
            increment_value = (bucket, slot) -> Increment()(bucket.values[slot])
            add_key = (bucket, slot) -> AddKey()(bucket.keys[slot], bucket.values[slot])
            @test (@inferred TGD._mapvalues!(increment_value, bucket, Real, nothing)) === nothing
            @test (@inferred TGD._mapvalues!(add_key, bucket, Real, nothing)) === nothing
            @test bucket.values == [2 * key + 1 for key in 1:8]
        end
    end

    @testset "Deferred interacting migrations and exact-once traversal" begin
        # Multiple removals repair slots; destinations include earlier/later/new buckets
        for with_keys in (false, true)
            original = Dict{Int, Any}(
                1 => 11, 2 => 12, 3 => 13, 4 => 14,
                5 => 15.0, 6 => 16.0, 7 => "seventeen", 8 => "eighteen", 9 => nothing
            )
            replacements = Dict{Int, Any}(
                1 => 11.0, 2 => 12.0, 3 => "thirteen", 4 => 14,
                5 => 15, 6 => :sixteen, 7 => 17, 8 => nothing, 9 => "nineteen"
            )
            collection = grouped([key => original[key] for key in 1:9])
            original_locations = copy(collection.lookup)
            original_types = copy(collection.type_to_bucket)
            visited = Int[]
            value_to_key = Dict(value => key for (key, value) in original)
            callback = function (key, value)
                push!(visited, key)
                @test isequal(value, original[key])
                @test collection.lookup == original_locations
                @test collection.type_to_bucket == original_types
                @test TGD._check_invariants(collection) === nothing
                return replacements[key]
            end
            if with_keys
                @test mapvalueswithkeys!(callback, collection) === collection
            else
                @test mapvalues!(value -> callback(value_to_key[value], value), collection) === collection
            end
            @test sort(visited) == collect(1:9)
            check_contents(collection, replacements)
        end

        # Entire source empties, then receives every entry back on the next pass
        collection = grouped([key => key for key in 1:20])
        source = only(collection.buckets)
        mapvalues!(Float64, collection)
        @test isempty(source.values)
        @test length(collection.buckets) == 2
        mapvalueswithkeys!((_, value) -> Int(value), collection)
        @test length(source.values) == 20
        @test length(collection.buckets) == 2
        check_contents(collection, Dict(key => key for key in 1:20))
    end

    @testset "Mapping failures retain valid storage" begin
        for with_keys in (false, true), failure in (:callback, :conversion)
            collection = grouped([1 => 1, 2 => 2, 3 => 3]; value_type = Real)
            callback = function (value)
                value == 1 && return 10
                value == 2 && return 2.0
                failure === :callback && error("callback failed")
                return "invalid"
            end
            if with_keys
                @test_throws Exception mapvalueswithkeys!((_, value) -> callback(value), collection)
            else
                @test_throws Exception mapvalues!(callback, collection)
            end
            check_contents(collection, Dict{Int, Real}(1 => 10, 2 => 2, 3 => 3))
            @test length(collection.buckets) == 1
        end
    end

    @testset "Logical equality, isequal, and hashing" begin
        left = grouped([1 => 10, 2 => "two", 3 => 3.0, 4 => 40])
        right = grouped([99 => nothing, 3 => 3.0, 2 => "two", 98 => 98, 4 => 40, 1 => 10])
        delete!(right, 99)
        delete!(right, 98)
        @test left.type_to_bucket != right.type_to_bucket
        @test left == right
        @test right == left
        @test isequal(left, right)
        for seed in (UInt(0), UInt(1), typemax(UInt))
            @test hash(left, seed) == hash(right, seed) == hash(Dict(left), seed)
        end
        widened = grouped(collect(right); key_type = Any, value_type = Any)
        @test left == widened
        @test isequal(left, widened)
        @test hash(left) == hash(widened)
        @test left == Dict(right)
        @test Dict(right) == left
        @test isequal(left, Dict(right))
        @test isequal(Dict(right), left)
        @test !(left == IdDict(Dict(left)))
        @test !isequal(IdDict(Dict(left)), left)
        right[1] = 11
        @test !(left == right)
        @test !isequal(left, right)
        right[1] = 10
        delete!(right, 4)
        @test !(left == right)
        right[5] = 40
        @test !(left == right)
        @test !isequal(left, right)

        for (a, b) in (
                (NaN, NaN), (missing, missing), (missing, 1),
                (-0.0, 0.0), (1, 1.0), (nothing, nothing),
            )
            first_collection = grouped([1 => a])
            second_collection = grouped([1 => b])
            first_dict, second_dict = Dict(1 => a), Dict(1 => b)
            @test isequal(first_collection == second_collection, first_dict == second_dict)
            @test isequal(first_collection, second_collection) == isequal(first_dict, second_dict)
            @test isequal(first_collection == first_collection, first_dict == first_dict)
            @test isequal(first_collection, first_collection)
            @test hash(first_collection) == hash(first_dict)
            first_collection[2] = 1
            second_collection[2] = 2
            @test (first_collection == second_collection) === false
        end
        empty_retained = grouped([1 => 1, 2 => "two"])
        empty!(empty_retained)
        check_contents(empty_retained, Dict{Int, Any}())
        @test empty_retained == TypeGroupedDict{String, Real}()
        @test hash(empty_retained) == hash(TypeGroupedDict{String, Real}()) == hash(Dict{Int, Any}())
    end

    @testset "Invariant checker detects corruption" begin
        collection = grouped([1 => 1, 2 => 2, 3 => "three"])
        collection.lookup[1] = TGD.Location(1, 2)
        @test_throws AssertionError TGD._check_invariants(collection)
        collection.lookup[1] = TGD.Location(1, 1)
        push!(collection.buckets[1].keys, 9)
        @test_throws AssertionError TGD._check_invariants(collection)
        pop!(collection.buckets[1].keys)
        collection.buckets[1].keys[2] = 1
        @test_throws AssertionError TGD._check_invariants(collection)
        collection.buckets[1].keys[2] = 2
        collection.type_to_bucket[Int] = 2
        @test_throws AssertionError TGD._check_invariants(collection)
        collection.type_to_bucket[Int] = 1
        collection.lookup[99] = TGD.Location(99, 99)
        @test_throws AssertionError TGD._check_invariants(collection)
        delete!(collection.lookup, 99)
        @test TGD._check_invariants(collection) === nothing
    end

    @testset "Seeded differential sequences" begin
        for seed in (0x15a7, 0xace2, 0xdeadbeef)
            rng = Xoshiro(seed)
            collection = TypeGroupedDict{Int, Any}()
            reference = Dict{Int, Any}()
            candidates = Any[-3, 0, 7, Int8(2), 1.5, -0.0, NaN, "one", "two", :three, nothing, missing]
            for step in 1:1000
                operation = rand(rng, 1:16)
                key = rand(rng, 1:24)
                value = rand(rng, candidates)
                @testset "seed=$seed step=$step operation=$operation key=$key" begin
                    if operation <= 4
                        collection[key] = value
                        reference[key] = value
                    elseif operation == 5
                        delete!(collection, key)
                        delete!(reference, key)
                    elseif operation == 6
                        @test isequal(pop!(collection, key, :absent), pop!(reference, key, :absent))
                    elseif operation == 7
                        if haskey(reference, key)
                            @test isequal(collection[key], reference[key])
                        else
                            @test_throws KeyError collection[key]
                        end
                    elseif operation == 8
                        @test isequal(get(collection, key, value), get(reference, key, value))
                    elseif operation == 9
                        @test isequal(get!(collection, key, value), get!(reference, key, value))
                    elseif operation == 10
                        @test haskey(collection, key) == haskey(reference, key)
                    elseif operation == 11 && step % 17 == 0
                        empty!(collection)
                        empty!(reference)
                    elseif operation == 12 && !isempty(reference)
                        # Explicit same-type replacement, independent of the candidate draw
                        chosen = rand(rng, collect(keys(reference)))
                        collection[chosen] = reference[chosen]
                    elseif operation == 13 && !isempty(reference)
                        chosen = rand(rng, collect(keys(reference)))
                        replacement = reference[chosen] isa String ? 42 : "migrated"
                        collection[chosen] = replacement
                        reference[chosen] = replacement
                    elseif operation == 14
                        replacements = Dict(k => rand(rng, candidates) for k in keys(reference))
                        visits = Int[]
                        mapvalueswithkeys!(collection) do k, _
                            push!(visits, k)
                            return replacements[k]
                        end
                        @test sort(visits) == sort(collect(keys(reference)))
                        merge!(reference, replacements)
                    elseif operation == 15
                        transform = x -> x isa Int ? Float64(x) : x isa Float64 ? "float" : x
                        mapvalues!(transform, collection)
                        for k in keys(reference)
                            reference[k] = transform(reference[k])
                        end
                    elseif operation == 16
                        if haskey(reference, key)
                            @test isequal(pop!(collection, key), pop!(reference, key))
                        else
                            @test_throws KeyError pop!(collection, key)
                        end
                    end
                    check_contents(collection, reference)
                end
            end
        end
    end
end
