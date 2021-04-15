# Compute circulation statistics conditioned on scale-averaged dissipation.
#
# Uses example data from Taylor-Green vortex (tgtest_data).

using GPFields
using GPStatistics

using TimerOutputs
using HDF5

import Base.Threads

function make_loop_sizes(; base, dims)
    Rmax = min(dims...) - 1  # max loop size is N - 1
    Nmax = floor(Int, log(base, Rmax))
    unique(round.(Int, base .^ (0:Nmax)))
end

function main()
    dims = (16, 15, 14)
    Ls = (2π, 2π, 2π)

    data_params = (
        load_velocity = true,
        basename_velocity = "examples/tgtest_data/VI*-0.bin",
        filename_dissipation = "examples/tgtest_data/dissipation-0.bin",
    )

    gp = ParamsGP(dims; L = Ls, c = 1, nxi = 1)
    loop_sizes = make_loop_sizes(; base = 1.4, dims = dims)

    output = (
        statistics = "tgtest_circulation.h5",
    )


    circulation = let
        fields = (
            # If divide_by_area = true, we actually compute statistics of Γ / A,
            # which has units of vorticity (and tends to ω when A → 0).
            # This is more consistent with the coarse-grained dissipation field,
            # which is also an area integral normalised by the loop area.
            CirculationField(divide_by_area = true),
            DissipationField(),
        )
        bin_edges = (
            # Circulation bins.
            # NOTE: since we set divide_by_area = true, the limits should be
            # roughly the extrema of vorticity in the domain.
            range(-50, 50; step = 0.1),
            range(0, 50; step = 0.1),
        )
        (;
            max_slices = nothing,
            stats_params = (
                ParamsHistogram2D(Int64, fields; bin_edges),
            )
        )
    end

    # ============================================================ #

    convolution_kernels = RectangularKernel.(loop_sizes .* gp.dx[1])

    @info "Loop sizes: $loop_sizes ($(length(loop_sizes)) sizes)"

    to = TimerOutput()
    stats = init_statistics(
        CirculationStats,
        convolution_kernels,
        circulation.stats_params;
        which = (VelocityLikeFields.Velocity, ),
    )

    analyse!(stats, gp, data_params; to, max_slices = 1)

    reset_timer!(to)
    reset!(stats)

    analyse!(stats, gp, data_params; to, max_slices = circulation.max_slices)

    println(to)

    write_results(output.statistics, stats, gp)

    nothing
end

function write_results(outfile, stats, gp)
    mkpath(dirname(outfile))
    @info "Saving $(outfile)"
    h5open(outfile, "w") do ff
        write(create_group(ff, "SimParams"), gp)
        write(create_group(ff, "Statistics"), stats)
    end
    nothing
end

main()
