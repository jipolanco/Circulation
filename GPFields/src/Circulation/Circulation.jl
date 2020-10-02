module Circulation

export IntegralField2D, Rectangle, circulation

using ..GPFields

using Base.Threads
using FFTW

include("rectangle.jl")
include("integral_field.jl")

"""
    circulation!(Γ::AbstractMatrix, I::IntegralField2D, rs; grid_step=1)

Compute circulation on a 2D slice around loops with a fixed rectangle shape.

## Parameters

- `Γ`: output real matrix containing the circulation associated to each point of
  the physical grid.

- `I`: `IntegralField2D` containing integral information of 2D vector field.

- `rs = (r_x, r_y)`: rectangle dimensions.

- `grid_step`: optional parameter allowing to visit only a subset of grid
  points. For instance, if `grid_step = 2`, one out of two grid points is
  considered in every direction. Note that the dimensions of `Γ` must be
  consistent with this parameter.

"""
function circulation!(
        Γ::AbstractMatrix{<:Real}, I::IntegralField2D, rs::NTuple{2,Int};
        grid_step::Int = 1,
    )
    if grid_step .* size(Γ) != size(I)
        throw(DimensionMismatch("incompatible size of output array"))
    end
    loops = LoopIterator(I, rs, grid_step)
    @threads for j ∈ axes(Γ, 2)
        for i ∈ axes(Γ, 1)
            @inbounds loop = loops[i, j]
            @inbounds Γ[i, j] = circulation(loop, I)
        end
    end
    Γ
end

"""
    circulation(loop::Rectangle, I::IntegralField2D)

Compute circulation around the given loop on a 2D slice.

The rectangle must be given in integer coordinates (grid indices).

See also `circulation!`.
"""
function circulation(loop::Rectangle{Int}, I::IntegralField2D)
    # Coordinates (including end point).
    xs = LinRange.(0, I.L, I.N .+ 1)

    # Indices of rectangle points.
    ia, ja = loop.x
    ib, jb = loop.x .+ loop.r

    # Coordinates of rectangle corners, taking periodicity into account.
    (ia, xa), (ja, ya) = _make_coordinate.(xs, (ia, ja))
    (ib, xb), (jb, yb) = _make_coordinate.(xs, (ib, jb))

    dx = xb - xa
    dy = yb - ya

    int_x_ya = I.U[1][ja] * dx + I.w[1][ib, ja] - I.w[1][ia, ja]
    int_x_yb = I.U[1][jb] * dx + I.w[1][ib, jb] - I.w[1][ia, jb]

    int_y_xa = I.U[2][ia] * dy + I.w[2][ia, jb] - I.w[2][ia, ja]
    int_y_xb = I.U[2][ib] * dy + I.w[2][ib, jb] - I.w[2][ib, ja]

    int_x_ya + int_y_xb - int_x_yb - int_y_xa
end

function _make_coordinate(x::AbstractVector, i::Int)
    # Return coordinate x[i] taking periodicity into account.
    @assert x[1] == 0
    N = length(x) - 1
    L = x[N + 1]
    x0 = zero(L)
    while i <= 0
        i += N
        x0 -= L
    end
    while i > N
        i -= N
        x0 += L
    end
    i, x0 + x[i]
end

end
