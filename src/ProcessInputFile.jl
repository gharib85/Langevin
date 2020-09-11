module ProcessInputFile

using Pkg.TOML
using Random
using Statistics
using LinearAlgebra
using Logging
using LibGit2

using ..UnitCells: UnitCell
using ..Lattices: Lattice
using ..Models: HolsteinModel, SSHModel
using ..MuFinder: MuTuner, update_μ!
using ..Models: assign_μ!, assign_ω!, assign_λ!, assign_ω4!
using ..Models: assign_t!, assign_ωij!, assign_hopping!
using ..Models: initialize_model!, update_model!, read_phonons
using ..GreensFunctions: EstimateGreensFunction, update!
using ..InitializePhonons: init_phonons_half_filled!
using ..LangevinDynamics: EulerDynamics, RungeKuttaDynamics, HeunsDynamics
using ..HMC: HybridMonteCarlo
using ..FourierAcceleration: FourierAccelerator, update_Q!, update_M!
using ..SimulationParams: SimulationParameters

using ..KPMPreconditioners: LeftRightKPMPreconditioner

export process_input_file, initialize_holstein_model


function process_input_file(filename::String)
    
    ########################
    ## READ IN INPUT FILE ##
    ########################
    
    input = TOML.parsefile(filename)

    # Input file must describe either a Langevin or a Hyrbid Monte Carlo Simulation but not both.
    @assert haskey(input,"hmc") ⊻ haskey(input,"langevin")

    ##################################
    ## DEFINE SIMULATION PARAMETERS ##
    ##################################

    if haskey(input,"hmc")
        meas_freq = input["hmc"]["meas_freq"]
        nsteps    = input["hmc"]["simulation_updates"]
        burnin    = input["hmc"]["burnin_updates"]
    else
        @assert input["langevin"]["burnin_timesteps"]%input["langevin"]["meas_freq"]==0
        meas_freq = input["langevin"]["meas_freq"]
        nsteps    = input["langevin"]["simulation_timesteps"]
        burnin    = input["langevin"]["burnin_timesteps"]
    end

    # construct simulation parameters object.
    sim_params = SimulationParameters(burnin,
                                      nsteps,
                                      meas_freq,
                                      input["simulation"]["num_bins"],
                                      input["simulation"]["filepath"],
                                      input["simulation"]["foldername"])

    # make direcotory data will be written to
    mkdir(sim_params.datafolder)

    # initialize random number generator with seed
    if !("random_seed" in keys(input["simulation"]))
        input["simulation"]["random_seed"] = abs(rand(Int))
    end
    Random.seed!(input["simulation"]["random_seed"])

    # copy input file into data folder
    cp(filename,sim_params.datafolder*filename)

    # create log for simulation
    logfilename = sim_params.datafolder*sim_params.foldername[1:end-1]*".log"
    logio       = open(logfilename,"w+")
    logger      = SimpleLogger(logio)
    global_logger(logger)
    
    # write current git commit tag of code to log file
    @info( "Commit Hash: "*LibGit2.head(abspath(joinpath(dirname(Base.find_package("Langevin")), ".."))) )
    flush(logio)

    #####################
    ## CONSTRUCT MODEL ##
    #####################
    
    if haskey(input,"holstein")
        model = initialize_holstein_model(filename)
    elseif haskey(input,"ssh")
        model = initialize_ssh_model(filename)
    end

    #####################################
    ## TUNE DENSITY/CHEMICAL POTENTIAL ##
    #####################################

    if haskey(input,"tune_density")
        targed_density = input["tune_density"]["density"]
        memory         = input["tune_density"]["memory"]
        κ_min          = input["tune_density"]["kappa_min"]
        μ_tuner = MuTuner(true, mean(model.μ), targed_density*model.Nsites, model.β, model.Δτ, memory, κ_min*model.Nsites)
    else
        μ_tuner = MuTuner(false, mean(model.μ), 1.0*model.Nsites, model.β, model.Δτ, 0.75, 0.1)
    end

    ###########################
    ## DEFINE PRECONDITIONER ##
    ###########################

    if lowercase(input["solver"]["type"])=="cg"
        preconditioner = I
    else
        λ_lo = input["solver"]["preconditioner"]["lambda_lo"]
        λ_hi = input["solver"]["preconditioner"]["lambda_hi"]
        c1   = input["solver"]["preconditioner"]["c1"]
        c2   = input["solver"]["preconditioner"]["c2"]
        preconditioner = LeftRightKPMPreconditioner(model,λ_lo,λ_hi,c1,c2,false)
    end
    
    #################################
    ## DEFINE FOURIER ACCELERATION ##
    #################################
    
    # defining FourierAccelerator type
    fa = FourierAccelerator(model)
    
    # set the mass used to construct fourier acceleration matrix
    for d in input["fourier_acceleration"]
        mass = d["mass"]
        if haskey(d,"c")
            c = d["c"]
        else
            c = 0.0
        end
        update_Q!(fa, model, d["omega_min"], d["omega_max"], mass)
        update_M!(fa, model, d["omega_min"], d["omega_max"], mass, c)
    end

    #####################
    ## DEFINE DYNAMICS ##
    #####################

    # number of degrees of freedom (phonon fields) to simulate
    NL = length(model)

    if haskey(input,"hmc")

        Δt              = input["hmc"]["dt"]
        tr              = input["hmc"]["trajectory_time"]
        construct_guess = input["hmc"]["construct_guess"]
        α               = input["hmc"]["momentum_conservation_fraction"]
        Nb              = input["hmc"]["num_multitimesteps"]
        if haskey(input["hmc"],"tau")
            τ = input["hmc"]["tau"]
        else
            # default value is infinity, recovering normal hamiltonian dynamics
            τ = Inf
        end
        # if τ is meant to be infinity, recovering normal hamiltonian dynamics
        if typeof(τ)==String
            if startswith(lowercase(τ),"inf")
                τ = Inf
            else
                throw(DomainError(τ,"invalid value for tau"))
            end
        end

        # log file instructions
        if haskey(input["hmc"],"log")
            log = input["hmc"]["log"]
        else
            log = false
        end
        if log & haskey(input["hmc"],"verbose")
            verbose = input["hmc"]["verbose"]
        else
            verbose = false
        end
        hmc_simulation_logfile = sim_params.datafolder*"hmc_sim_log.out"
        hmc_burnin_logfile = sim_params.datafolder*"hmc_burnin_log.out"

        @assert τ >= 0.0
        @assert 0.0 <= α < 1.0
        @assert !((α>0)&(isfinite(τ)))
        simulation_dynamics = HybridMonteCarlo(NL, Δt, tr, τ, α, Nb, construct_guess,
                                              log=log, verbose=verbose, logfile=hmc_simulation_logfile)

        # defining burnin dynamics
        if haskey(input["hmc"], "burnin")
            if haskey(input["hmc"]["burnin"],"dt")
                Δt = input["hmc"]["burnin"]["dt"]
            end
            if haskey(input["hmc"]["burnin"],"trajectory_time")
                tr = input["hmc"]["burnin"]["trajectory_time"]
            end
            if haskey(input["hmc"]["burnin"],"tau")
                τ = input["hmc"]["burnin"]["tau"]
                # if τ is meant to be infinity, recovering normal hamiltonian dynamics
                if typeof(τ)==String
                    if startswith(lowercase(τ),"inf")
                        τ = Inf
                    else
                        throw(DomainError(τ,"invalid value for tau"))
                    end
                end
            else
                τ = Inf
            end
            if haskey(input["hmc"]["burnin"],"construct_guess")
                construct_guess = input["hmc"]["burnin"]["construct_guess"]
            end
            if haskey(input["hmc"]["burnin"],"momentum_conservation_fraction")
                α = input["hmc"]["burnin"]["momentum_conservation_fraction"]
            end
            if haskey(input["hmc"]["burnin"],"num_multitimesteps")
                Nb = input["hmc"]["burnin"]["num_multitimesteps"]
            end
            @assert τ >= 0.0
            @assert 0.0 <= α < 1.0
            @assert !((α>0)&(isfinite(τ)))
        end
        burnin_dyanmics = HybridMonteCarlo(simulation_dynamics, Δt, tr, τ, α, Nb, construct_guess,
                                           log=log, verbose=verbose, logfile=hmc_burnin_logfile)

    elseif input["langevin"]["update_method"]==1

        Δt       = input["langevin"]["dt"]
        simulation_dynamics = EulerDynamics(NL,Δt)
        burnin_dyanmics = simulation_dynamics

    elseif input["langevin"]["update_method"]==2

        Δt       = input["langevin"]["dt"]
        simulation_dynamics = RungeKuttaDynamics(NL,Δt)
        burnin_dyanmics = simulation_dynamics

    elseif input["langevin"]["update_method"]==3

        Δt       = input["langevin"]["dt"]
        simulation_dynamics = HeunsDynamics(NL,Δt)
        burnin_dyanmics = simulation_dynamics

    end

    #########################
    ## DEFINE MEASUREMENTS ##
    #########################

    # specify which measurements to make
    measurements     = input["measurements"]
    unequaltime_meas = Vector{String}()
    equaltime_meas   = Vector{String}()
    for k in keys(measurements)
        if k != "num_random_vectors"
            if measurements[k]["measure"]
                if measurements[k]["time_dependent"]
                    push!(unequaltime_meas,k)
                else
                    push!(equaltime_meas,k)
                end
            end
        end
    end

    # construct object of estimating Green's function
    if haskey(input["measurements"],"num_random_vectors")
        num_random_vectors = input["measurements"]["num_random_vectors"]
    else
        num_random_vectors = 1
    end
    Gr = EstimateGreensFunction(model,num_random_vectors)
    
    return model, Gr, μ_tuner, sim_params, simulation_dynamics, burnin_dyanmics, fa, preconditioner, unequaltime_meas, equaltime_meas, input
end

"""
Initialize Holstein Model from config file.
"""
function initialize_holstein_model(filename::String)

    # read input file
    input = TOML.parsefile(filename)
    
    # define lattice geometry
    unit_cell = UnitCell(input["lattice"]["ndim"],
                         input["lattice"]["norbits"],
                         hcat(input["lattice"]["lattice_vectors"]...),
                         hcat(input["lattice"]["basis_vectors"]...))
    
    # define lattice
    lattice = Lattice(unit_cell, input["lattice"]["L"])

    # restart for GMRES solver
    if haskey(input["solver"],"restart")
        restart = input["solver"]["restart"]
    else
        restart = 20
    end
    
    # initialize holstein model
    holstein = HolsteinModel(lattice,
                             input["holstein"]["beta"],
                             input["holstein"]["dtau"],
                             is_complex      = false,
                             iterativesolver = input["solver"]["type"],
                             tol             = input["solver"]["tol"],
                             maxiter         = input["solver"]["maxiter"],
                             restart         = restart)
    
    # adding phonon frequencies
    for d in input["holstein"]["omega"]
        stddev = 0.0
        if "stddev" in keys(d)
            stddev = d["stddev"]
        end
        for orbit in d["orbit"]
            assign_ω!(holstein,d["val"],stddev,orbit)
        end
    end
    
    # adding chemical potential
    for d in input["holstein"]["mu"]
        stddev = 0.0
        if "stddev" in keys(d)
            stddev = d["stddev"]
        end
        for orbit in d["orbit"]
            assign_μ!(holstein,d["val"],stddev,orbit)
        end
    end

    # check in anharmic term defined
    if "omega4" in keys(input["holstein"])
        # adding anharmoic term to holstein model
        for d in input["holstein"]["omega4"]
            stddev = 0.0
            if "stddev" in keys(d)
                stddev = d["stddev"]
            end
            for orbit in d["orbit"]
                assign_ω4!(holstein,d["val"],stddev,orbit)
            end
        end
    end
    
    # check if any hopping defined
    if "t" in keys(input["holstein"])
        for t in input["holstein"]["t"]
            stddev = 0.0
            if "stddev" in keys(t)
                stddev = t["stddev"]
            end
            assign_t!(holstein, t["val"], stddev,
                        t["orbit"][1], t["orbit"][2], Vector{Int}(t["dL"]))
        end
    end

    # adding electron-phonon coupling
    for d in input["holstein"]["lambda"]
        stddev = 0.0
        if "stddev" in keys(d)
            stddev = d["stddev"]
        end
        for orbit in d["orbit"]
            assign_λ!(holstein,d["val"],stddev,orbit)
        end
    end

    # organize electron hoppings for checkerboard decomposition
    initialize_model!(holstein)

    # intialize phonon field
    if input["holstein"]["read_phonon_config"]
        phononfile = input["holstein"]["phonon_config_file"]
        read_phonons(holstein, phononfile)
        cp(filename, sim_params.datafolder * phononfile)
    else
        init_phonons_half_filled!(holstein)
    end

    # construct exponentiated interaction matrix
    update_model!(holstein)

    return holstein
end

"""
Initialize SSH model from config file.
"""
function initialize_ssh_model(filename::String)

    # read input file
    input = TOML.parsefile(filename)
    
    # define lattice geometry
    unit_cell = UnitCell(input["lattice"]["ndim"],
                         input["lattice"]["norbits"],
                         hcat(input["lattice"]["lattice_vectors"]...),
                         hcat(input["lattice"]["basis_vectors"]...))
    
    # define lattice
    lattice = Lattice(unit_cell, input["lattice"]["L"])

    # restart for GMRES solver
    if haskey(input["solver"],"restart")
        restart = input["solver"]["restart"]
    else
        restart = 20
    end
    
    # initialize holstein model
    ssh = SSHModel(lattice,
                   input["ssh"]["beta"],
                   input["ssh"]["dtau"],
                   is_complex      = false,
                   iterativesolver = input["solver"]["type"],
                   tol             = input["solver"]["tol"],
                   maxiter         = input["solver"]["maxiter"],
                   restart         = restart)

    # adding chemical potential
    for d in input["ssh"]["mu"]
        stddev = 0.0
        if "stddev" in keys(d)
            stddev = d["stddev"]
        end
        for orbit in d["orbit"]
            assign_μ!(holstein,d["val"],stddev,orbit)
        end
    end

    # add hoppings
    if haskey(input["ssh"]["hopping"])
        for d in input["ssh"]["hopping"]
            if haskey(d,"t_avg")
                t = d["t_avg"]
            else
                t = 0.0
            end
            if haskey(d,"t_std")
                σt = d["t_std"]
            else
                σt = 0.0
            end
            if haskey(d,"alpha_avg")
                α = d["alpha_avg"]
            else
                α = 0.0
            end
            if haskey(d,"alpha_std")
                σα = d["alpha_std"]
            else
                σα = 0.0
            end
            if haskey(d,"omega_avg")
                ω = d["omega_avg"]
            else
                ω = 1.0
            end
            if haskey(d,"omega_std")
                σω = d["omega_std"]
            else
                σω = 0.0
            end
            o₁ = d["orbits"][1]
            o₂ = d["orbits"][2]
            dL = d["dL"]
            assign_hopping!(ssh,t,σt,ω,σω,α,σα,o₁,o₂,dL)
        end
    end

    # initialize model
    initialize_model!(ssh)

    # intialize phonon field
    if input["ssh"]["read_phonon_config"]
        phononfile = input["ssh"]["phonon_config_file"]
        read_phonons(ssh, phononfile)
        cp(filename, sim_params.datafolder * phononfile)
    else
        init_phonons_half_filled!(ssh)
    end

    # construct exponentiated interaction matrix
    update_model!(ssh)

    return ssh
end

end