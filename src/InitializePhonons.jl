module InitializePhonons

using ..Models: HolsteinModel, SSHModel, update_model!
using ..Utilities: get_index, reshaped

export init_phonons_single_site!, init_phonons_half_filled!, sample_qho


function init_phonons_half_filled!(ssh::SSHModel{T1,T2}) where {T1,T2}
    
    # info about temperature of system
    β  = ssh.β::T1
    Δτ = ssh.Δτ::T1
    Lτ = ssh.Lτ::Int

    # number of phonons
    Nph = ssh.Nph

    # get phonon fields
    x = ssh.x

    # keeps track of the fields
    field = 0

    # iterate over phonons
    for phonon in 1:Nph

        # calculate average phonon position
        α  = ssh.α[phonon]
        ω  = ssh.ω[phonon]
        x0 = sample_qho(ω,β)

        # iterate over imaginary time slices
        for τ in 1:Lτ

            # increment field count
            field += 1

            # set phonon value
            x[field] = x0

            # iterate over eqivalent fields
            for i in 1:ssh.num_equivalent_fields[field]
                field′    = ssh.equivalent_fields[i,field]
                x[field′] = x0
            end
        end
    end

    # udpate exponentiated interaction matrix
    update_model!(ssh)

    return nothing
end

function init_phonons_half_filled!(holstein::HolsteinModel{T1,T2}) where {T1,T2}

    # info about temperature of system
    β  = holstein.β::T1
    Δτ = holstein.Δτ::T1
    Lτ = holstein.Lτ::Int

    # iterate over sites in lattice
    for site in 1:holstein.Nsites

        # get parameters for site in lattice
        ω = holstein.ω[site]
        λ = holstein.λ[site]

        # get all phonon fields corresponding to current
        # site in lattice.
        i_start = get_index(1,site,Lτ)
        i_end   = get_index(Lτ,site,Lτ)
        path    = @view holstein.x[i_start:i_end]

        # shift levy path by ammount corresponding having either
        # a density of 0 or 2 on the site
        x0 = -2*λ/ω^2 * rand(0:1)
        xr = x0 + sample_qho(ω,β)
        @. path = xr
    end

    # udpate exponentiated interaction matrix
    update_model!(holstein)

    return nothing
end

"""
Samples the position distribution of a QHO with frequency `ω` at inverse temperature `β`.
"""
function sample_qho(ω::T,β::T)::T where {T<:Number}
    
    σ = sqrt( tanh(β*ω/2) / (2*ω) )
    return σ*randn()
end

end