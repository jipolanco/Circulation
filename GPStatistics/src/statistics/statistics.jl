module VelocityLikeFields
# Different velocity-like vector fields from which a circulation can be computed.
@enum VelocityLikeField Velocity RegVelocity Momentum
end

using .VelocityLikeFields

export NoConditioning, ConditionOnDissipation
abstract type AbstractConditioning end
struct NoConditioning <: AbstractConditioning end
struct ConditionOnDissipation{Edges <: AbstractVector} <: AbstractConditioning
    bin_edges :: Edges  # defines the binning of dissipation
end

abstract type AbstractSamplingMethod end
struct ConvolutionMethod <: AbstractSamplingMethod end
struct PhysicalMethod <: AbstractSamplingMethod end

abstract type AbstractBaseStats end
include("disabled_stats.jl")
include("moments.jl")
include("histogram.jl")

abstract type AbstractFlowStats end
include("circulation.jl")
include("velocity_increments.jl")

conditioning(s::AbstractFlowStats) = s.conditioning

# Dictionary of statistics.
# Useful for defining flow statistics related to quantities such as velocity,
# regularised velocity and momentum.
const StatsDict{S} =
    Dict{VelocityLikeFields.VelocityLikeField, S} where {S <: AbstractFlowStats}

Broadcast.broadcastable(s::AbstractBaseStats) = Ref(s)

Base.zero(s::SD) where {SD <: StatsDict} = SD(k => zero(v) for (k, v) in s)

Base.zero(s::Tuple{Vararg{S}}) where {S <: AbstractBaseStats} = zero.(s)

"""
    update!(conditioning, stats::AbstractFlowStats, Γ, r_ind; to=TimerOutput())

Update circulation data associated to a given loop size (with index `r_ind`)
using circulation data.

For threaded computation, `stats` should be a vector of `AbstractFlowStats`,
with length equal to the number of threads.
"""
function update!(cond, stats::AbstractFlowStats, Γ, r_ind; to=TimerOutput())
    @assert r_ind ∈ 1:stats.Nr
    for name in statistics(stats)
        @timeit to string(name) update!(cond, getfield(stats, name), Γ, r_ind)
    end
    stats
end

function update!(cond::NoConditioning,
                 stats::AbstractVector{<:AbstractFlowStats},
                 Γ, r_ind; to=TimerOutput())
    Nth = nthreads()
    @assert length(stats) == Nth
    N = length(Γ)
    # Split Γ field among threads.
    Γ_v = vec(Γ)
    Γ_inds = collect(Iterators.partition(1:N, div(N, Nth, RoundUp)))
    @assert length(Γ_inds) == Nth
    @threads for t = 1:Nth
        timer = t == 1 ? to : TimerOutput()
        s = stats[t]
        Γ_t = view(Γ_v, Γ_inds[t])
        update!(cond, s, Γ_t, r_ind; to=timer)
    end
    stats
end

function update!(cond::ConditionOnDissipation,
                 stats::AbstractVector{<:AbstractFlowStats},
                 fields, r_ind; to=TimerOutput())
    Nth = nthreads()
    @assert length(stats) == Nth
    N = length(first(fields))
    @assert all(length.(values(fields)) .== N)
    # Split fields among threads.
    fields_v = map(vec, fields)
    Γ_inds = collect(Iterators.partition(1:N, div(N, Nth, RoundUp)))
    @assert length(Γ_inds) == Nth
    @threads for t = 1:Nth
        timer = t == 1 ? to : TimerOutput()
        s = stats[t]
        fields_t = map(fields_v) do u
            view(u, Γ_inds[t])
        end
        update!(cond, s, fields_t, r_ind; to=timer)
    end
    stats
end

update!(cond, s::Tuple, Γ::Tuple, args...) =
    map((a, b) -> update!(cond, a, b, args...), s, Γ)

"""
    reduce!(stats::AbstractFlowStats, v::AbstractVector{<:AbstractFlowStats})

Reduce values from list of statistics.
"""
function reduce!(stats::S, v::AbstractVector{<:S}) where {S <: AbstractFlowStats}
    @assert all(stats.Nr .== getfield.(v, :Nr))
    for name in statistics(stats)
        reduce!(getfield(stats, name), getfield.(v, name))
    end
    stats
end

function reduce!(s::NTuple{N,S},
                 inputs::AbstractVector{NTuple{N,S}}) where {N, S <: AbstractBaseStats}
    for n in eachindex(s)
        reduce!(s[n], (v[n] for v in inputs))
    end
    s
end

was_finalised(stats::AbstractBaseStats) = stats.finalised[]

"""
    finalise!(stats::AbstractFlowStats)

Compute final statistics from collected data.

For instance, moment data is divided by the number of samples to obtain the
actual moments.
"""
function finalise!(stats::AbstractFlowStats)
    for name in statistics(stats)
        finalise!.(getfield(stats, name))
    end
    stats
end

"""
    reset!(stats::AbstractFlowStats)

Reset all statistics to zero.
"""
function reset!(stats::AbstractFlowStats)
    for name in statistics(stats)
        reset!.(getfield(stats, name))
    end
    stats
end

finalise!(stats::StatsDict) = finalise!.(values(stats))
reset!(s::StatsDict) = reset!.(values(s))

function reduce!(dest::StatsDict, src::AbstractVector{<:StatsDict})
    @assert all(Ref(keys(dest)) .== keys.(src))
    for k in keys(dest)
        src_stats = getindex.(src, k) :: Vector{<:AbstractFlowStats}
        reduce!(dest[k], src_stats)
    end
    dest
end

"""
    write(filename::AbstractString, stats::StatsDict)
    write(ff::Union{HDF5.File,HDF5.Group}, stats::StatsDict)

Save statistics to HDF5 file.
"""
Base.write(h5filename::AbstractString, stats::StatsDict) =
    h5open(ff -> write(ff, stats), h5filename, "w")

function Base.write(ff::Union{HDF5.File,HDF5.Group}, stats::StatsDict)
    for (k, v) in stats
        g = create_group(ff, string(k))
        write(g, v)
        close(g)
    end
    ff
end

"""
    init_statistics(S, args...; which, stats_args...)

Initialise statistics that can be passed to `analyse!`.

`S` must be the type of statistics (for now, only `CirculationStats` is
supported).

## Optional parameters

- `which`: list of quantities of type `VelocityLikeFields.VelocityLikeField` to
  consider. The default is to consider all of them.

- `stats_args`: arguments passed to `CirculationStats`.
"""
function init_statistics(
        ::Type{S},
        args...;
        which=(VelocityLikeFields.Velocity,
               VelocityLikeFields.RegVelocity,
               VelocityLikeFields.Momentum),
        stats_args...
    ) where {S <: AbstractFlowStats}
    if length(unique(which)) != length(which)
        throw(ArgumentError("quantities may not be repeated: $which"))
    end
    Dict(w => S(args...; stats_args...) for w in which)
end

"""
    analyse!(stats::Dict, gp::ParamsGP, data_params;
             eps_vel = 0, max_slices = nothing, to = TimerOutput())

Compute circulation statistics from all possible slices of a GP field.

The `stats` dictionary must contain one object of type `AbstractFlowStats` per
quantity of interest.
The keys of the dictionary are values of type `VelocityLikeFields.VelocityLikeField`.
This dictionary may be generated by calling `init_statistics`.

## Input data

The input file parameters must be provided via the `data_params` argument.
This is typically a `NamedTuple` that may contain parameters such as data
directory, timestep and fields to load. The actual required parameters depend on
the kind of analysis performed.

Some possible fields of `data_params`:

- `directory` (`AbstractString`): directory where data is located.

- `timestep` (`Integer`): timestep of data file.

- `load_velocity` (`Bool`): load velocity field instead of wave function field.
  In this case, the density `ρ` will be taken as constant and equal to 1.

## Optional parameters

- `eps_vel`: optional correction applied to `ρ` before computing velocity.

- `max_slices`: maximum number of slices to consider along each direction.
  By default, all available slices are considered.
  This can be useful for testing, to make things faster.

- `to`: a TimerOutput object, useful for measuring performance.
"""
function analyse!(stats::StatsDict, gp::ParamsGP,
                  data_params; to=TimerOutput(), kwargs...)
    orientations = slice_orientations(gp)
    for or in orientations
        @timeit to "analyse!" analyse!(stats, or, gp, data_params;
                                       to=to, kwargs...)
    end
    finalise!(stats)
end

# Analyse for a single slice orientation.
function analyse!(stats::StatsDict, orientation::Orientation, gp::ParamsGP{D},
                  data_params;
                  max_slices = nothing,
                  eps_vel = 0, to = TimerOutput()) where {D}
    Nslices = num_slices(gp.dims, orientation, max_slices) :: Int
    @assert Nslices >= 1
    @assert !isempty(stats)

    resampling_factor, resampled_grid = let vals = values(stats)
        r = first(vals).resampling_factor
        grid = first(vals).resampled_grid
        @assert(all(getfield.(vals, :resampling_factor) .=== r),
                "all stats must have the same resampling factor")
        @assert r >= 1 "only upscaling is allowed"
        @assert(all(getfield.(vals, :resampled_grid) .=== grid),
                "all stats must have the same `compute_in_resampled_grid` value")
        r, grid
    end

    # Slice dimensions.
    # Example: in 3D, if orientation = 2, this is (1, 3).
    i, j = included_dimensions(Val(D), orientation)
    Lij = gp.L[i], gp.L[j]

    Nij_input = gp.dims[i], gp.dims[j]
    Nij_compute = Nij_input .* resampling_factor

    # Determine which statistics to compute.
    stats_keys = keys(stats)
    with_v = VelocityLikeFields.Velocity in stats_keys
    with_vreg = VelocityLikeFields.RegVelocity in stats_keys
    with_p = VelocityLikeFields.Momentum in stats_keys

    # Allocate arrays.
    load_velocity = get(data_params, :load_velocity, false) :: Bool
    fields = allocate_fields(
        first(values(stats)), Nij_input, Nij_compute, with_v || with_vreg;
        L = Lij, load_velocity = load_velocity,
        compute_in_resampled_grid = resampled_grid,
    )

    Nth = nthreads()
    stats_t = [zero(stats) for t = 1:Nth]

    slices = 1:Nslices

    let s = string(orientation)
        println(stderr)
        @info "Analysing slices $slices along $s..."
    end

    for s in slices
        @info "  Slice $s/$Nslices"
        flush(stderr)
        slice = make_slice(gp.dims, orientation, s)
        analyse_slice!(
            stats_t, slice, gp, fields, to, data_params, eps_vel,
            resampling_factor, (with_p, with_vreg, with_v),
        )
    end

    @timeit to "reduce!" reduce!(stats, stats_t)

    stats
end

# Allocate fields common to all stats (circulation, velocity increments).
function allocate_common_fields(Nij_input, Nij_resampled, with_v;
                                compute_in_resampled_grid::Bool,
                                load_velocity)
    FFTW.set_num_threads(nthreads())  # make sure that FFTs are threaded
    if load_velocity
        ψ_in = nothing
        ψ = nothing
        ψ_buf = nothing
        fft_plans_p = nothing
        fft_plans_resample = nothing
        ρ = ones(Float64, Nij_input...)
    else
        ψ_in = Array{ComplexF64}(undef, Nij_input...)
        ψ = if Nij_input === Nij_resampled
            ψ_in  # in this case, the two point to the same data!
        else
            similar(ψ_in, Nij_resampled)
        end
        ψ_buf = similar(ψ)
        ρ = similar(ψ, Float64)
        fft_plans_resample = (
            fw = plan_fft!(ψ_in, flags=FFTW.MEASURE),
            bw = plan_ifft!(ψ, flags=FFTW.MEASURE),
        )
        fft_plans_p = GPFields.create_fft_plans_1d!(ψ)
    end
    Γ_size = compute_in_resampled_grid ? Nij_resampled : Nij_input
    ps = (similar(ρ), similar(ρ))  # momentum
    (
        ψ_in = ψ_in,
        ψ = ψ,
        ψ_buf = ψ_buf,
        ρ = ρ,
        dims_out = Γ_size,
        ps = ps,
        vs = with_v ? similar.(ps) : nothing,
        # FFTW plans for resampling
        fft_plans_resample = fft_plans_resample,
        # FFTW plans for computing momentum
        fft_plans_p = fft_plans_p,
    )
end

function load_psi_slice!(ψ::AbstractArray, ψ_in::AbstractArray, gp, slice,
                         data_params, plans, resampling_factor, to)
    @assert all(size(ψ) .÷ size(ψ_in) .== resampling_factor)
    @timeit to "load_psi!" GPFields.load_psi!(
        ψ_in, gp, data_params.directory, data_params.timestep, slice=slice)

    # Create parameters associated to original and resampled slices.
    gp_slice_in = ParamsGP(gp, slice)
    gp_slice = ParamsGP(gp_slice_in, dims=size(ψ))

    # Note that nξ changes in the resampled field!
    @assert gp_slice.nξ == gp_slice_in.nξ * resampling_factor

    @timeit to "resample ψ" begin
        # Note: resample_field_fourier! works with fields in Fourier space.
        plans.fw * ψ_in  # in-place FFT
        GPFields.resample_field_fourier!(ψ, ψ_in, gp_slice_in)
        plans.bw * ψ
    end

    gp_slice
end

function load_velocity_slice!(vs::Tuple, gp, slice, data_params, to)
    data_args = if hasproperty(data_params, :basename_velocity)
        (data_params.basename_velocity, )
    else
        (data_params.directory, data_params.timestep)
    end
    @timeit to "load_velocity!" GPFields.load_velocity!(
        vs, gp, data_args...; slice)
    ParamsGP(gp, slice)
end

function load_dissipation_slice!(ε, gp, slice, data_params, to)
    @timeit to "load_dissipation!" GPFields.load_scalar_field!(
        ε, gp, data_params.filename_dissipation; slice,
    )
end

function analyse_slice!(
        stats, slice, gp, F, to, data_params,
        eps_vel, resampling_factor,
        (with_p, with_vreg, with_v),
    )
    load_velocity = F.ψ === nothing
    if load_velocity
        if resampling_factor != 1
            error("resampling_factor can't be different from 1 when loading velocity field")
        end
        gp_slice = load_velocity_slice!(F.ps, gp, slice, data_params, to)
        if hasproperty(F, :ε)
            load_dissipation_slice!(F.ε, gp, slice, data_params, to)
        end
        for p in F.ps
            p ./= F.ρ  # this doesn't really do anything, since ρ = 1 everywhere
        end
    else
        gp_slice = load_psi_slice!(F.ψ, F.ψ_in, gp, slice, data_params,
                                   F.fft_plans_resample, resampling_factor, to)
        @timeit to "density!" GPFields.density!(F.ρ, F.ψ)
        @timeit to "momentum!" GPFields.momentum!(
            F.ps, F.ψ, gp_slice, buf=F.ψ_buf, fft_plans=F.fft_plans_p)
    end

    if with_p
        # Get all Momentum stats (one per thread)
        let stats = getindex.(stats, VelocityLikeFields.Momentum)
            compute!(stats, F, F.ps, to)
        end
    end

    if with_vreg
        @timeit to "compute_vreg!" compute_vreg!(F.vs, F.ps, F.ρ)
        let stats = getindex.(stats, VelocityLikeFields.RegVelocity)
            compute!(stats, F, F.vs, to)
        end
    end

    if with_v
        @timeit to "compute_vel!" compute_velocity!(F.vs, F.ps, F.ρ, eps_vel)
        let stats = getindex.(stats, VelocityLikeFields.Velocity)
            compute!(stats, F, F.vs, to)
        end
    end

    nothing
end

function compute_vreg!(vs::Tuple, ps::Tuple, ρ)
    @inbounds @threads for n in eachindex(ρ)
        one_over_sqrt_rho = inv(sqrt(ρ[n]))
        for (v, p) in zip(vs, ps)  # for each velocity component
            v[n] = one_over_sqrt_rho * p[n]
        end
    end
    vs
end

function compute_velocity!(vs::Tuple, ps::Tuple, ρ, eps_vel = 0)
    @inbounds @threads for n in eachindex(ρ)
        one_over_rho = inv(ρ[n] + eps_vel)
        for (v, p) in zip(vs, ps)  # for each velocity component
            v[n] = one_over_rho * p[n]
        end
    end
    vs
end
