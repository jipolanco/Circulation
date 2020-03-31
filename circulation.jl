#!/usr/bin/env julia

using GPFields
using Circulation

using FFTW
using InteractiveUtils

import Base.Threads

@info "Using $(Threads.nthreads()) threads"
if Threads.nthreads() == 1
    @info "Set the JULIA_NUM_THREADS environment variable to change this."
end

# Input data parameters
const DATA_DIR_BASE = expanduser("~/Dropbox/circulation/data/4vortices")
const DATA_IDX = 1

const GP_PARAMS = ParamsGP(
    (256, 256),  # resolution (can be 2D or 3D)
    c = 1.0,
    nxi = 1.5,
)

const SLICE_3D = (:, :, 1)  # slice of a 3D dataset

const VELOCITY_EPS = 1e-10

function read_psi(params::ParamsGP, dir_base, resolution, idx)
    datadir = joinpath(dir_base, string(resolution))
    ψ = GPFields.load_psi(params, datadir, idx)
    @info "Loaded $(summary(ψ)) from $datadir"
    ψ
end

# Determine dimensions along which a slice is performed.
# For instance, if the slice is (42, :, :, 15, :) -> dims = (2, 3, 5)
slice_dims() = ()
slice_dims(::Any, etc...) = 1 .+ slice_dims(etc...)
slice_dims(::Colon, etc...) = (1, (1 .+ slice_dims(etc...))...)
slice_dims(t::Tuple) = slice_dims(t...)

@assert slice_dims(42, :, :, 15, :) === (2, 3, 5)
@assert slice_dims(:, 2, :) === (1, 3)
@assert slice_dims(2, :, 1) === (2, )
@assert slice_dims(:, 2) === (1, )
@assert slice_dims(1, 2) === ()

# Select slice and perform FFTs.
# Case of 3D input data
function prepare_slice(v::NTuple{3,AbstractArray{T,3}} where T,
                       slice=(:, :, 1))
    dims = slice_dims(slice)
    if length(dims) != 2
        throw(ArgumentError(
            "the given slice should have dimension 2 (got $slice)"
        ))
    end
    vs = v[dims[1]], v[dims[2]]  # select the 2 relevant components
    vsub = view.(vs, slice...)
    @assert all(ndims.(vsub) .== 2) "Slices don't have dimension 2"
    rfft(vsub[1], 1), rfft(vsub[2], 2)
end

# Case of 2D input data (the `slice` argument is ignored)
prepare_slice(v::NTuple{2,AbstractArray{T,2}} where T, args...) =
    (rfft(v[1], 1), rfft(v[2], 2))

generate_slice(::ParamsGP{2}) = (:, :)    # 2D case
generate_slice(::ParamsGP{3}) = SLICE_3D  # 3D case

function main()
    params = GP_PARAMS
    slice = generate_slice(params)
    dims = slice_dims(slice) :: Tuple{Int,Int}
    @info "Using slice = $slice (dimensions: $dims)"

    # Load field from file
    psi = read_psi(params, DATA_DIR_BASE, params.dims[1], DATA_IDX)

    # Compute different fields (can be 2D or 3D)
    rho = GPFields.compute_density(psi)
    p = GPFields.compute_momentum(psi, params)     # = (px, py, [pz])
    v = map(pp -> pp ./ (rho .+ VELOCITY_EPS), p)  # = (vx, vy, [vz])
    vreg = map(pp -> pp ./ sqrt.(rho), p)          # regularised velocity

    pf = prepare_slice(p, slice)

    # Build wave numbers and allocate circulation matrix
    ks, circ = let (i, j) = dims
        Ns = params.dims[i], params.dims[j]  # physical dimensions of slice (N1, N2)
        Ls = params.L[i], params.L[j]        # physical lengths (L1, L2)
        fs = 2pi .* Ns ./ Ls                 # FFT sampling frequency
        ks = rfftfreq.(Ns, fs)               # non-negative wave numbers
        circ = similar(rho, Ns...)           # circulation matrix
        ks, circ
    end

    rs = (8, 8)  # rectangle loop dimensions

    # Compute circulation over slice
    circulation!(circ, pf, rs, ks)
end

main()
