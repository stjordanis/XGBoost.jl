
"""
    Booster

Data structure containing xgboost decision trees or other model objects.  `Booster` is used in all methods
for training and predition.

`Booster` can only consume data from [`DMatrix`](@ref) objects but most methods can convert provided
data implicitly.  Note that `Booster` does *not* store any of its input or output data.

See [`xgboost`](@ref) which is shorthand for a `Booster` constructor followed by training.

The `Booster` object records all non-default model hyper-parameters set either at construction
or with [`setparam!`](@ref).  The xgboost library does not support retrieval of such parameters
so these should be considered for UI purposes only, they are reported in the deafult `show` methods
of the `Booster`.

## Constructors
```julia
Booster(train; kw...)
Booster(trains::AbstractVector; kw...)
```

## Arguments
- `train`: Training data.  If not a `DMatrix` this will be passed to the `DMatrix` constructor.
    For example it can be a training matrix or a training matrix, target pair.
- `trains`: An array of objects used as training data, each of which will be passed to a `DMatrix`
    constructor.

### Keyword Arguments
All keyword arguments excepting only those listed below will be interpreted as model parameters,
see [here](https://xgboost.readthedocs.io/en/stable/parameter.html) for a comprehensive list.
Both parameter names and their values must be provided exactly as they appear in the linked
documentation.  Model parameters can also be set after construction, see [`setparam!`](@ref) and
[`setparams!`](@ref).
- `tree_method`: This parameter gets special handling.  By default it is `nothing` which uses the default
    from `libxgboost` as per the documentation unless GPU arrays are used in which case it defaults to
    `"gpu_hist"`.  If an explicit option is set, it will always be used.
- `feature_names`: Sets the feature names of training data.  This will use the feature names set in the
    input data if available (e.g. if tabular data was passed this will use column names).
- `model_buffer`: A buffer (`AbstractVector{UInt8}` or `IO`) from which to load an existing booster
    model object.
- `model_file`: Name of a file from which to load an existing booster model object, see [`save`](@ref).
"""
mutable struct Booster
    handle::BoosterHandle
    feature_names::Vector{String}  # sadly the C booster doesn't store this

    # xgboost doesn't let us retrieve params, this dict is purely for the user to be able to figure
    # out what the hell is happening, it's never used for program logic
    params::Dict{Symbol,Any}

    function Booster(h::BoosterHandle, fsn::AbstractVector{<:AbstractString}=String[], params::AbstractDict=Dict())
        finalizer(x -> xgbcall(XGBoosterFree, x.handle), new(h, fsn, params))
    end
end

"""
    setparam!(b::Booster, name, val)

Set a model parameter in the booster.  The complete list of model parameters can be found
[here](https://xgboost.readthedocs.io/en/stable/parameter.html).  Any non-default parameters
set via this method will be stored so they can be seen in REPL text output, however
the xgboost library does not support parameter retrieval.
`name` can be either a string or a `Symbol`.
"""
function setparam!(b::Booster, name::AbstractString, val::AbstractString)
    name = if name == "η"
        "eta"
    elseif name == "α"
        "alpha"
    elseif name == "γ"
        "gamma"
    else
        name
    end
    xgbcall(XGBoosterSetParam, b.handle, name, val)
    b.params[Symbol(name)] = val
    val
end
setparam!(b::Booster, name::AbstractString, val) = setparam!(b, name, string(val))
setparam!(b::Booster, name::Symbol, val) = setparam!(b, string(name), val)

setmultiparams!(b::Booster, name::Union{Symbol,AbstractString}, vals) = foreach(v -> setparam!(b, name, v), vals)

# the API for some parameters involves multiple separate calls to XGBoosterSetParam
# multi methods for resolving ambiguities
setparam!(b::Booster, name::Symbol, vals::AbstractVector) = setmultiparams!(b, name, vals)
setparam!(b::Booster, name::AbstractString, vals::AbstractVector) = setmultiparams!(b, name, vals)
setparam!(b::Booster, name::Symbol, vals::Tuple) = setmultiparams!(b, name, vals)
setparam!(b::Booster, name::AbstractString, vals::Tuple) = setmultiparams!(b, name, vals)

"""
    setparams!(b::Booster; kw...)

Set arbitrarily many model parameters via keyword arguments, see [`setparam!`](@ref).
"""
setparams!(b::Booster; kw...) = foreach(kv -> setparam!(b, kv[1], kv[2]), kw)

function Booster(cache::AbstractVector{<:DMatrix};
                 feature_names::AbstractVector{<:AbstractString}=getfeaturenames(cache),
                 model_buffer=UInt8[],
                 model_file::AbstractString="",
                 tree_method::Union{Nothing,AbstractString}=nothing,
                 validate_parameters::Bool=true,
                 kw...
                )
    o = Ref{BoosterHandle}()
    xgbcall(XGBoosterCreate, map(x -> x.handle, cache), length(cache), o)
    b = Booster(o[], feature_names)
    if model_buffer isa IO || !isempty(model_buffer)
        load!(b, model_buffer)
    elseif !isempty(model_file)
        load!(b, model_file)
    end
    # automatically use gpu_hist if CuArrays used and we didn't pass an explicit argument
    tm = if isnothing(tree_method)
        (!isempty(cache) && all(isgpu, cache)) ? (tree_method="gpu_hist",) : (;)
    else
        (tree_method=tree_method,)
    end
    setparams!(b; validate_parameters, tm..., kw...)
    b
end
Booster(dm::DMatrix; kw...) = Booster([dm]; kw...)

Booster(data::AbstractVector; kw...) = Booster(map(DMatrix, data); kw...)

Booster(data; kw...) = Booster(DMatrix(data); kw...)

"""
    getnrounds(b::Booster)

Get the number of rounds run by the `Booster` object.  Normally this will correspond to the total number
of trees stored in the `Booster`.
"""
function getnrounds(b::Booster)
    o = Ref{Cint}()
    err = XGBoosterBoostedRounds(b.handle, o)
    # xgboost will error in some circumstances when this really ought to be zero
    err == 0 ? Int(o[]) : 0
end

"""
    load!(b::Booster, file_or_buffer)

Load a serialized `Booster` object from a file or buffer into an existing model object.
`file_or_buffer` can be a string giving the name of the file to load from, a
`AbstractVector{UInt8}` buffer, or an `IO`.

This should load models stored via [`save`](@ref) (*not* `serialize` which may give
incompatible buffers).
"""
load!(b::Booster, file::AbstractString) = (xgbcall(XGBoosterLoadModel, b.handle, file); b)
function load!(b::Booster, buf::AbstractVector{UInt8})
    buf = convert(Vector{UInt8}, buf)
    xgbcall(XGBoosterLoadModelFromBuffer, b.handle, buf, length(buf))
    b
end
load!(b::Booster, io::IO) = load!(b, read(io))

"""
    load(Booster, file_or_buffer)

Load a saved [`Booster`](@ref) model object from a file or buffer.
`file_or_buffer` can be a string giving the name of the file to load from, an
`AbstractVector{UInt8}` buffer or an `IO`.

This should load models stored via [`save`](@ref) (*not* `serialize` which may give
incompatible buffers).
"""
load(::Type{Booster}, fname::AbstractString) = Booster(DMatrix[], model_file=fname)
load(::Type{Booster}, io) = Booster(DMatrix[], model_buffer=io)

"""
    save(b::Booster, fname)
    save(b::Booster, Vector{UInt8}; format="json")
    save(b::Booster, io::IO; format="json")

Save the [`Booster`](@ref) object.  This saves to formats which are intended to be stored
on disk but the formats used are a lot zanier than those used by `deserialize`.
A model saved with this function can be retrieved with [`load`](@ref) or [`load!`](@ref).
"""
function save(b::Booster, fname::AbstractString)
    xgbcall(XGBoosterSaveModel, b.handle, fname)
    fname
end
function save(b::Booster, ::Type{Vector{UInt8}}; format::AbstractString="json")
    cfg = JSON3.write(Dict("format"=>format))
    olen = Ref{Lib.bst_ulong}()
    o = Ref{Ptr{Int8}}()
    xgbcall(XGBoosterSaveModelToBuffer, b.handle, cfg, olen, o)
    unsafe_wrap(Array, convert(Ptr{UInt8}, o[]), olen[])
end
save(b::Booster, io::IO; kw...) = write(io, save(b, Vector{UInt8}; kw...))

"""
    dumpraw(b::Booster; format="json", with_stats=false)

Dump the models stored by `b` to a string format.  Valid options for `format` are `"json"` or
`"text"`.  See also [`dump`](@ref) which returns the same thing as parsed JSON.
"""
function dumpraw(b::Booster;
                 format::AbstractString="json",  # known formats are json and text
                 fmap::AbstractString="",
                 with_stats::Bool=false
                )
    olen = Ref{Lib.bst_ulong}()
    o = Ref{Ptr{Ptr{Cchar}}}()
    xgbcall(XGBoosterDumpModelEx, b.handle, fmap, convert(Cint, with_stats), format, olen, o)
    strs = unsafe_wrap(Array, o[], olen[])
    map(unsafe_string, strs)
end

"""
    dump(b::Booster; with_stats=false)

Return the model stored by `Booster` as a set of hierararchical objects (i.e. from parsed JSON).
This can be used to inspect the state of the model.  See [`trees`](@ref) and [`Node`](@ref) which
parse the output from this into a more useful format which satisfies the AbstractTrees interface.
"""
function dump(b::Booster;
              fmap::AbstractString="",
              with_stats::Bool=false,
             )
    strs = dumpraw(b; fmap, with_stats)
    JSON3.read.(strs)
end

"""
    serialize(b::Booster)

Serialize the model `b` into an opaque binary format.  Returns a `Vector{UInt8}`.
The output of this function can be loaded with [`deserialize`](@ref).
"""
function serialize(b::Booster)
    olen = Ref{Lib.bst_ulong}()
    o = Ref{Ptr{Int8}}()  # don't know why it insists on Int8
    xgbcall(XGBoosterSerializeToBuffer, b.handle, olen, o)
    unsafe_wrap(Array, convert(Ptr{UInt8}, o[]), olen[])
end

"""
    nfeatures(b::Booster)

Get the number of features on which `b` is being trained.  Note that this can return `nothing` if
the `Booster` object is uninitialized (was created with no data arguments).
"""
function nfeatures(b::Booster)
    o = Ref{Lib.bst_ulong}()
    err = XGBoosterGetNumFeature(b.handle, o)
    iszero(err) ? Int(o[]) : nothing
end

"""
    deserialize!(b::Booster, buf)

Deserialize a buffer created with [`serialize`](@ref) to the provided [`Booster`](@ref) object.
"""
function deserialize!(b::Booster, buf::AbstractVector{UInt8})
    buf = convert(Vector{UInt8}, buf)
    xgbcall(XGBoosterUnserializeFromBuffer, b.handle, buf, length(buf))
    b
end

"""
    deserialize(Booster, buf, data=[]; kw...)

Deserialize the data in buffer `buf` to a new `Booster` object.  The data in `buf` should have
been created with [`serialize`](@ref).  `data` and keyword arguments are sent to a `Booster`
constructor.
"""
function deserialize(::Type{Booster}, buf::AbstractVector{UInt8}, data=DMatrix[]; kw...)
    b = Booster(data...; kw...)
    deserialize!(b, buf)
end

# sadly this is type unstable because we might return a transpose
"""
    predict(b::Booster, data; margin=false, training=false, ntree_limit=0)

Use the model `b` to run predictions on `data`.  This will return a `Vector{Float32}` which can be compared
to training or test target data.

If `ntree_limit > 0` only the first `ntree_limit` trees will be used in prediction.

## Examples
```julia
(X, y) = (randn(100,3), randn(100))
b = xgboost((X, y), 10)

ŷ = predict(b, X)
```
"""
function predict(b::Booster, Xy::DMatrix;
                 margin::Bool=false,  # whether to output margin
                 training::Bool=false,
                 ntree_lower_limit::Integer=0,
                 ntree_limit::Integer=0,  # 0 corresponds to no limit
                )
    opts = Dict("type"=>(margin ? 1 : 0),
                "iteration_begin"=>ntree_lower_limit,
                "iteration_end"=>ntree_limit,
                "strict_shape"=>false,
                "training"=>training,
               ) |> JSON3.write
    oshape = Ref{Ptr{Lib.bst_ulong}}()
    odim = Ref{Lib.bst_ulong}()
    o = Ref{Ptr{Cfloat}}()
    xgbcall(XGBoosterPredictFromDMatrix, b.handle, Xy.handle, opts, oshape, odim, o)
    dims = reverse(unsafe_wrap(Array, oshape[], odim[]))
    o = unsafe_wrap(Array, o[], tuple(dims...))
    length(dims) > 1 ? transpose(o) : o
end
predict(b::Booster, Xy; kw...) = predict(b, DMatrix(Xy); kw...)

function evaliter(b::Booster, watch, n::Integer=1)
    o = Ref{Ptr{Int8}}()
    names = collect(Iterators.map(string, keys(watch)))
    watch = collect(Iterators.map(x -> x.handle, values(watch)))
    xgbcall(XGBoosterEvalOneIter, b.handle, n, watch, names, length(watch), o)
    unsafe_string(o[])
end

printeval(io::IO, b::Booster, watch, n::Integer=1) = print(io, evaliter(b, watch, n))
printeval(b::Booster, watch, n::Integer=1) = printeval(stderr, b, watch, n)

logeval(b::Booster, watch, n::Integer=1) = @info(evaliter(b, watch, n))

function _maybe_update_feature_names!(b::Booster, Xy::DMatrix, up::Bool)
    if up
        b.feature_names = getfeaturenames(Xy)
    else
        isempty(b.feature_names) && (b.feature_names = getfeaturenames(Xy))
    end
end

"""
    updateone!(b::Booster, data; round_number=getnrounds(b)+1,
               watchlist=Dict("train"=>data), update_feature_names=false
              )

Run one round of gradient boosting with booster `b` on data `data`.  `data` can be any object that
is accepted by a [`DMatrix`](@ref) constructor.  `round_number` is the number of the current round
and is used for logs only.  Info logs will be printed for training sets in `watchlist`; keys give
the name of that dataset for logging purposes only.
"""
function updateone!(b::Booster, Xy::DMatrix;
                    round_number::Integer=getnrounds(b)+1,
                    watchlist=Dict("train"=>Xy),
                    update_feature_names::Bool=false,
                   )
    xgbcall(XGBoosterUpdateOneIter, b.handle, round_number, Xy.handle)
    isempty(watchlist) || logeval(b, watchlist, round_number)
    _maybe_update_feature_names!(b, Xy, update_feature_names)
    b
end

function updateone!(b::Booster, Xy::DMatrix, g::AbstractVector{<:Real}, h::AbstractVector{<:Real};
                    round_number::Integer=1,
                    watchlist=Dict("train"=>Xy),
                    update_feature_names::Bool=false,
                   )
    if size(g) ≠ size(h)
        throw(ArgumentError("booster got gradient and hessian of incompatible sizes"))
    end
    g = convert(Vector{Cfloat}, g)
    h = convert(Vector{Cfloat}, h)
    xgbcall(XGBoosterBoostOneIter, b.handle, Xy.handle, g, h, length(g))
    isempty(watchlist) || logeval(b, watchlist, round_number)
    _maybe_update_feature_names!(b, Xy, update_feature_names)
    b
end

"""
    updateone!(b::Booster, data, ℓ′, ℓ″; kw...)

Run one of gradient boosting with a loss function `ℓ`.  `ℓ′` and `ℓ″` are the first and second *scalar*
derivatives of the loss function.  For example
```julia
ℓ(ŷ, y) = (ŷ - y)^2
ℓ′(ŷ, y) = 2(ŷ - y)
ℓ″(ŷ, y) = 2
```
where the derivatives are with respect to the first argument (the prediction).

Other arguments are the same as they would be provided to other methods of `updateone!`.
"""
function updateone!(b::Booster, Xy::DMatrix, ℓ′, ℓ″; kw...)
    y = getlabel(Xy)
    ŷ = predict(b, Xy)
    updateone!(b, Xy, ℓ′.(ŷ, y), ℓ″.(ŷ, y); kw...)
end

updateone!(b::Booster, data; kw...) = updateone!(b, DMatrix(data); kw...)
updateone!(b::Booster, data, ℓ′, ℓ″; kw...) = updateone!(b, DMatrix(data), ℓ′, ℓ″; kw...)

# this method should be reserved for if we add an autodiff dependency
#updateone!(::Booster, ::DMatrix, ℓ; kw...)

"""
    update!(b::Booster, data; num_round=1, kw...)
    update!(b::Booster, data, ℓ′, ℓ″; kw...)

Run `num_round` rounds of gradient boosting on [`Booster`](@ref) `b`.

The first and second derivatives of the loss function (`ℓ′` and `ℓ″` respectively) can be provided
for custom loss.
"""
function update!(b::Booster, data, a...; num_round::Integer=1, kw...)
    for j ∈ 1:num_round
        round_number = getnrounds(b) + 1
        updateone!(b, data, a...; round_number, kw...)
    end
    b
end

"""
    xgboost(data; num_round=10, watchlist=Dict(), kw...)
    xgboost(data, ℓ′, ℓ″; kw...)

Creates an xgboost gradient booster object on training data `data` and runs `nrounds` of training.
This is essentially an alias for constructing a [`Booster`](@ref) with `data` and keyword arguments
followed by [`update!`](@ref) for `nrounds`.

`watchlist` is a dict the keys of which are strings giving the name of the data to watch
and the values of which are [`DMatrix`](@ref) objects containing the data.

All other keyword arguments are passed to [`Booster`](@ref).  With few exceptions these are model
training hyper-parameters, see [here](https://xgboost.readthedocs.io/en/stable/parameter.html) for
a comprehensive list.

A custom loss function can be privded via its first and second derivatives (`ℓ′` and `ℓ″` respectively).
See [`updateone!`](@ref) for more details.

## Examples
```julia
(X, y) = (randn(100,3), randn(100))

b = xgboost((X, y), 10, max_depth=10, η=0.1)

ŷ = predict(b, X)
```
"""
function xgboost(dm::DMatrix, a...;
                 num_round::Integer=10,
                 watchlist=Dict("train"=>dm),
                 kw...
                )
    Xy = DMatrix(dm)
    b = Booster(Xy; kw...)
    isempty(watchlist) || @info("XGBoost: starting training.")
    update!(b, Xy, a...; num_round, watchlist)
    isempty(watchlist) || @info("Training rounds complete.")
    b
end
xgboost(data, a...; kw...) = xgboost(DMatrix(data), a...; kw...)
