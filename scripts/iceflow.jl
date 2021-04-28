using JLD, Plots, Printf, LinearAlgebra

@views av(A)    = 0.25*(A[1:end-1,1:end-1].+A[2:end,1:end-1].+A[1:end-1,2:end].+A[2:end,2:end])
@views av_xa(A) = 0.5.*(A[1:end-1,:].+A[2:end,:])
@views av_ya(A) = 0.5.*(A[:,1:end-1].+A[:,2:end])
@views inn(A)   = A[2:end-1,2:end-1]

@views function iceflow(dx, dy, Zbed, Hice, Mask, grad_b, z_ELA, b_max)
    println("Initialising ice flow model ... ")
    # physics
    s2y      = 3600*24*365.25  # seconds to years
    rho_i    = 910.0           # ice density
    g        = 9.81            # gravity acceleration
    npow     = 3.0             # Glen's power law exponent
    a0       = 1.5e-24         # Glen's law enhancement term
    # numerics
    @assert (dx>0 && dy>0) "dx and dy need to be positive"
    nx, ny   = size(Zbed,1), size(Zbed,2) # numerical grid resolution
    @assert (nx, ny) == size(Zbed) == size(Hice) == size(Mask) "Sizes don't match"
    itMax    = 1e5             # number of iteration (max)
    nout     = 200             # error check frequency
    tolnl    = 1e-6            # nonlinear tolerance
    epsi     = 1e-4            # small number
    damp     = 0.85            # convergence accelerator
    dtausc   = 1.0/3.0         # iterative dtau scaling
    # derived physics
    a        = 2.0*a0/(npow+2)*(rho_i*g)^npow*s2y
    # derived numerics
    cfl      = max(dx^2,dy^2)/4.1
    # array initialisation
    Err      = zeros(nx  , ny  )
    dSdx     = zeros(nx-1, ny  )
    dSdy     = zeros(nx  , ny-1)
    gradS    = zeros(nx-1, ny-1)
    D        = zeros(nx-1, ny-1)
    qHx      = zeros(nx-1, ny-2)
    qHy      = zeros(nx-2, ny-1)
    dtau     = zeros(nx-2, ny-2)
    ResH     = zeros(nx-2, ny-2)
    dHdt     = zeros(nx-2, ny-2)
    Vx       = zeros(nx-1, ny-1)
    Vy       = zeros(nx-1, ny-1)
    M        = zeros(nx  , ny  )
    B        = zeros(nx  , ny  )
    H        = zeros(nx  , ny  )
    S        = zeros(nx  , ny  )
    # initial conditions
    B       .= Zbed
    H       .= Hice
    S       .= B .+ H
    println(" starting iteration loop:")
    # iteration loop
    it = 1; err = 2*tolnl
    while err>tolnl && it<itMax
        Err   .= H
        # mass balance
        M     .= min.(grad_b.*(S .- z_ELA), b_max)
        # compute diffusivity
        dSdx  .= diff(S, dims=1)/dx
        dSdy  .= diff(S, dims=2)/dy
        gradS .= sqrt.(av_ya(dSdx).^2 .+ av_xa(dSdy).^2)
        D     .= a*av(H).^(npow+2) .* gradS.^(npow-1)
        # compute flux
        qHx   .= .-av_ya(D).*diff(S[:,2:end-1], dims=1)/dx
        qHy   .= .-av_xa(D).*diff(S[2:end-1,:], dims=2)/dy
        # update ice thickness
        dtau  .= dtausc*min.(10.0, cfl./(epsi .+ av(D)))
        ResH  .= .-(diff(qHx, dims=1)/dx .+ diff(qHy, dims=2)/dy) .+ inn(M)
        dHdt  .= dHdt.*damp .+ ResH
        H[2:end-1,2:end-1] .= max.(0.0, inn(H) .+ dtau.*dHdt)
        # apply mask
        H[Mask.==0] .= 0.0
        # update surface
        S     .= B .+ H
        # error check
        if mod(it, nout)==0
            Err .= Err .- H
            err = norm(Err)/length(Err)
            @printf(" it = %d, error = %1.2e \n", it, err)
            if isnan(err) error("NaNs") end # safeguard
        end
        it += 1
    end
    # compute velocities
    Vx .= -D./(av(H) .+ epsi).*av_ya(dSdx)
    Vy .= -D./(av(H) .+ epsi).*av_xa(dSdy)
    # return as GeoArrays
    return  as_geoarray(H, Zbed, name=:thickness),
            as_geoarray(S, Zbed, name=:surface),
            as_geoarray(M, Zbed, name=:smb),
            as_geoarray(Vx, Zbed, name=:vel_x, staggerd=true),
            as_geoarray(Vy, Zbed, name=:vel_y, staggerd=true)
end
# ------------------------------------------------------------------------------
include("helpers.jl")

# load the data
print("Loading the data ... ")
Zbed, Hice, Mask, dx, dy, xc, yc = load_bedmachine_greenland(; nx=200)
#Zbed, Hice, Mask, dx, dy, xc, yc = load_bedmachine_greenland(; nx=96)
#out = load_bedmachine_greenland(; nx=96)
println("done.")

# apply some smoothing
print("Applying some smoothing ... ")
for is=1:2 # two smoothing steps
    smooth!(Zbed)
    smooth!(Hice)
end
println("done.")

# calculate mass balance coefficients for given spatial grid
grad_b, z_ELA, b_max = mass_balance_constants(xc, yc)

# run the SIA flow model
H, S, M, Vx, Vy = iceflow(abs(dx), abs(dy), Zbed, Hice, Mask, grad_b, z_ELA, b_max)

# handle output
do_visu = true
do_save = true

# visu and save
nx, ny = size(H)
if do_visu
    !ispath("../output") && mkdir("../output")

    H_v = fill(NaN, nx, ny)
    S_v = fill(NaN, nx, ny)
    M_v = fill(NaN, nx, ny)
    V_v = fill(NaN, nx-2, ny-2)

    # outputs
    FS  = 7
    H_v.=H; H_v[Mask.==0].=NaN
    S_v.=S; S_v[Mask.==0].=NaN
    M_v.=M; M_v[Mask.==0].=NaN
    V_v.=sqrt.(av(Vx).^2 .+ av(Vy).^2); V_v[inn(H).==0].=NaN
    p1 = heatmap(xc./1e3, reverse(yc)./1e3, reverse(S_v, dims=2)', c=:davos, aspect_ratio=1, xlims=(xc[1], xc[end])./1e3, ylims=(yc[end], yc[1])./1e3, yaxis=font(FS, "Courier"), ticks=nothing, framestyle=:box, title="Surface elev. [m]", titlefontsize=FS, titlefont="Courier")
    p2 = heatmap(xc./1e3, reverse(yc)./1e3, reverse(H_v, dims=2)', c=:davos, aspect_ratio=1, xlims=(xc[1], xc[end])./1e3, ylims=(yc[end], yc[1])./1e3, yaxis=font(FS, "Courier"), ticks=nothing, framestyle=:box, title="Ice thickness [m]", titlefontsize=FS, titlefont="Courier")
    p3 = heatmap(xc[2:end-1]./1e3, reverse(yc[2:end-1])./1e3, reverse(log10.(V_v), dims=2)', c=:batlow, aspect_ratio=1, xlims=(xc[2], xc[end-1])./1e3, ylims=(yc[end-1], yc[2])./1e3, clims=(0.1, 2.0), yaxis=font(FS, "Courier"), ticks=nothing, framestyle=:box, title="log10(vel) [m/yr]", titlefontsize=FS, titlefont="Courier")
    p4 = heatmap(xc./1e3, reverse(yc)./1e3, reverse(M_v, dims=2)', c=:devon, aspect_ratio=1, xlims=(xc[1], xc[end])./1e3, ylims=(yc[end], yc[1])./1e3, yaxis=font(FS, "Courier"), ticks=nothing, framestyle=:box, title="Mass Bal. rate [m/yr]", titlefontsize=FS, titlefont="Courier")
    # display(plot(p1, p2, p3, p4, size=(400,400)))
    plot(p1, p2, p3, p4, size=(400,400), dpi=200) #background_color=:transparent, foreground_color=:white
    savefig("../output/iceflow_out1.png")

    # error
    H_diff = Hice.-H; H_diff[Mask.==0] .= NaN
    Hice[Mask.==0] .= NaN
    H[Mask.==0]    .= NaN
    FS = 7
    p1 = heatmap(xc./1e3, reverse(yc)./1e3, reverse(Hice, dims=2)'  , c=:davos, aspect_ratio=1, xlims=(xc[1], xc[end])./1e3, ylims=(yc[end], yc[1])./1e3, yaxis=font(FS, "Courier"), ticks=nothing, framestyle=:box, title="H data [m]", titlefontsize=FS, titlefont="Courier")
    p2 = heatmap(xc./1e3, reverse(yc)./1e3, reverse(H, dims=2)'     , c=:davos, aspect_ratio=1, xlims=(xc[1], xc[end])./1e3, ylims=(yc[end], yc[1])./1e3, yaxis=font(FS, "Courier"), ticks=nothing, framestyle=:box, title="H model [m]", titlefontsize=FS, titlefont="Courier")
    p3 = heatmap(xc./1e3, reverse(yc)./1e3, reverse(H_diff, dims=2)', c=:viridis, aspect_ratio=1, xlims=(xc[1], xc[end])./1e3, ylims=(yc[end], yc[1])./1e3, yaxis=font(FS, "Courier"), ticks=nothing, framestyle=:box, title="H (data-model) [m]", titlefontsize=FS, titlefont="Courier")
    # display(plot(p1, p2, p3, layout=(1, 3), size=(500,160)))
    plot(p1, p2, p3, layout=(1, 3), size=(500,160), dpi=200) #background_color=:transparent, foreground_color=:white
    savefig("../output/iceflow_out2.png")
end

if do_save
    save("../output/iceflow_$(nx)x$(ny).jld", "Hice", convert(Matrix{Float32}, Hice),
                                              "Mask", convert(Matrix{Float32}, Mask),
                                              "H"   , convert(Matrix{Float32}, H),
                                              "S"   , convert(Matrix{Float32}, S),
                                              "M"   , convert(Matrix{Float32}, M),
                                              "Vx"  , convert(Matrix{Float32}, Vx),
                                              "Vy"  , convert(Matrix{Float32}, Vy),
                                              "xc", xc, "yc", yc)
end

println("... done.")
