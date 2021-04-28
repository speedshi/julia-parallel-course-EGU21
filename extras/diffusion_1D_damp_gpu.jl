using CUDA, Plots, Printf, LinearAlgebra

function compute_flux!(qH, H, D, dx, nx)
    ix = (blockIdx().x-1) * blockDim().x + threadIdx().x
    if (ix<=nx-1)  qH[ix] = -D*(H[ix+1]-H[ix])/dx  end
    return
end

function compute_rate!(ResH, dHdt, H, Hold, qH, dt, damp, dx, nx)
    ix = (blockIdx().x-1) * blockDim().x + threadIdx().x
    if (2<=ix<=nx-1)  ResH[ix-1] = -(H[ix] - Hold[ix])/dt -(qH[ix]-qH[ix-1])/dx  end
    if (2<=ix<=nx-1)  dHdt[ix-1] = ResH[ix-1] + damp*dHdt[ix-1]  end
    return
end

function compute_update!(H, dHdt, dtau, nx)
    ix = (blockIdx().x-1) * blockDim().x + threadIdx().x
    if (2<=ix<=nx-1)  H[ix] = H[ix] + dtau*dHdt[ix-1]  end
    return
end

@views function diffusion_1D()
    # Physics
    lx     = 10.0       # domain size
    D      = 1.0        # diffusion coefficient
    ttot   = 0.6        # total simulation time
    dt     = 0.1        # physical time step
    # Numerics
    BLOC   = 16
    GRID   = 16
    nx     = BLOC*GRID  # numerical grid resolution
    tol    = 1e-6       # tolerance
    itMax  = 1e4        # max number of iterations
    damp   = 1-41/nx    # damping (this is a tuning parameter, dependent on e.g. grid resolution)
    # Derived numerics
    dx     = lx/nx      # grid size
    dtau   = (1.0/(dx^2/D/2.1) + 1.0/dt)^-1 # iterative timestep
    xc     = LinRange(dx/2, lx-dx/2, nx)
    cuthreads = BLOC
    cublocks  = GRID
    # Array allocation
    qH     = CUDA.zeros(nx-1)
    dHdt   = CUDA.zeros(nx-2)
    ResH   = CUDA.zeros(nx-2)
    # Initial condition
    H0     = CuArray( exp.(.-(xc.-lx./2.0).^2) )
    Hold   = copy(H0)
    H      = copy(H0)
    t = 0.0; it = 0; ittot = 0
    # Physical time loop
    while t<ttot
        iter = 0; err = 2*tol
        # Pseudo-transient iteration
        while err>tol && iter<itMax
            @cuda blocks=cublocks threads=cuthreads compute_flux!(qH, H, D, dx, nx)
            synchronize()
            @cuda blocks=cublocks threads=cuthreads compute_rate!(ResH, dHdt, H, Hold, qH, dt, damp, dx, nx)
            synchronize()
            @cuda blocks=cublocks threads=cuthreads compute_update!(H, dHdt, dtau, nx)
            synchronize()
            iter += 1; err = norm(ResH)/length(ResH)
        end
        ittot += iter; it += 1; t += dt
        Hold .= H
    end
   # Analytic solution
    Hana = 1/sqrt(4*(ttot+1/4)) * exp.(-(xc.-lx/2).^2 /(4*(ttot+1/4)))
    @printf("Total time = %1.2f, time steps = %d, iterations tot = %d, error vs analytic = %1.2e \n", round(ttot, sigdigits=2), it, ittot, norm(Array(H)-Hana))
    # Visualise
    plot(xc, Array(H0), linewidth=3); display(plot!(xc, Array(H), legend=false, framestyle=:box, linewidth=3, xlabel="lx", ylabel="H", title="damped diffusion (nt=$it, iters=$ittot)"))
    return
end

diffusion_1D()
