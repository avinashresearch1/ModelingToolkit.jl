function System(eqs::AbstractVector{<:Equation}, iv, args...; name = nothing,
        kw...)
    ODESystem(eqs, iv, args...; name, kw..., checks = false)
end

"""
$(SIGNATURES)

Structurally simplify algebraic equations in a system and compute the
topological sort of the observed equations in `sys`.

### Optional Arguments:
+ optional argument `io` may take a tuple `(inputs, outputs)`. This will convert all `inputs` to parameters and allow them to be unconnected, i.e., simplification will allow models where `n_unknowns = n_equations - n_inputs`.

### Optional Keyword Arguments:
+ When `simplify=true`, the `simplify` function will be applied during the tearing process.
+ `allow_symbolic=false`, `allow_parameter=true`, and `conservative=false` limit the coefficient types during tearing. In particular, `conservative=true` limits tearing to only solve for trivial linear systems where the coefficient has the absolute value of ``1``.
+ `fully_determined=true` controls whether or not an error will be thrown if the number of equations don't match the number of inputs, outputs, and equations.
"""
function structural_simplify(
        sys::AbstractSystem, io = nothing; simplify = false, split = true,
        allow_symbolic = false, allow_parameter = true, conservative = false, fully_determined = true,
        kwargs...)
    newsys′ = __structural_simplify(sys, io; simplify,
        allow_symbolic, allow_parameter, conservative, fully_determined,
        kwargs...)
    if newsys′ isa Tuple
        @assert length(newsys′) == 2
        newsys = newsys′[1]
    else
        newsys = newsys′
    end
    if newsys isa DiscreteSystem &&
       any(eq -> symbolic_type(eq.lhs) == NotSymbolic(), equations(newsys))
        error("""
            Encountered algebraic equations when simplifying discrete system. This is \
            not yet supported.
        """)
    end
    if newsys isa ODESystem || has_parent(newsys)
        @set! newsys.parent = complete(sys; split)
    end
    newsys = complete(newsys; split)
    if has_defaults(newsys) && (defs = get_defaults(newsys)) !== nothing
        ks = collect(keys(defs))  # take copy to avoid mutating defs while iterating.
        for k in ks
            if Symbolics.isarraysymbolic(k) && Symbolics.shape(k) !== Symbolics.Unknown()
                for i in eachindex(k)
                    defs[k[i]] = defs[k][i]
                end
            end
        end
    end
    if newsys′ isa Tuple
        idxs = [parameter_index(newsys, i) for i in io[1]]
        return newsys, idxs
    else
        return newsys
    end
end

function __structural_simplify(sys::JumpSystem, args...; kwargs...)
    return sys
end

function __structural_simplify(sys::AbstractSystem, io = nothing; simplify = false, substitute_eqs = false, old_eq = nothing, new_eq = nothing,
        kwargs...)
    sys = expand_connections(sys)
    
    if substitute_eqs
        @warn "Substituting $old_eq with $new_eq"
        old_eq_idx = findall(e -> e == old_eq, full_equations(sys))
        @set! sys.eqs[first(old_eq_idx)] = new_eq
    end
    state = TearingState(sys)

    @unpack structure, fullvars = state
    @unpack graph, var_to_diff, var_types = structure
    eqs = equations(state)
    brown_vars = Int[]
    new_idxs = zeros(Int, length(var_types))
    idx = 0
    for (i, vt) in enumerate(var_types)
        if vt === BROWNIAN
            push!(brown_vars, i)
        else
            new_idxs[i] = (idx += 1)
        end
    end
    if isempty(brown_vars)
        return structural_simplify!(state, io; simplify, kwargs...)
    else
        Is = Int[]
        Js = Int[]
        vals = Num[]
        new_eqs = copy(eqs)
        dvar2eq = Dict{Any, Int}()
        for (v, dv) in enumerate(var_to_diff)
            dv === nothing && continue
            deqs = 𝑑neighbors(graph, dv)
            if length(deqs) != 1
                error("$(eqs[deqs]) is not handled.")
            end
            dvar2eq[fullvars[dv]] = only(deqs)
        end
        for (j, bj) in enumerate(brown_vars), i in 𝑑neighbors(graph, bj)
            push!(Is, i)
            push!(Js, j)
            eq = new_eqs[i]
            brown = fullvars[bj]
            (coeff, residual, islinear) = Symbolics.linear_expansion(eq, brown)
            islinear || error("$brown isn't linear in $eq")
            new_eqs[i] = 0 ~ residual
            push!(vals, coeff)
        end
        g = Matrix(sparse(Is, Js, vals))
        sys = state.sys
        @set! sys.eqs = new_eqs
        @set! sys.unknowns = [v
                              for (i, v) in enumerate(fullvars)
                              if !iszero(new_idxs[i]) &&
                                 invview(var_to_diff)[i] === nothing]
        # TODO: IO is not handled.
        ode_sys = structural_simplify(sys, io; simplify, kwargs...)
        eqs = equations(ode_sys)
        sorted_g_rows = zeros(Num, length(eqs), size(g, 2))
        for (i, eq) in enumerate(eqs)
            dvar = eq.lhs
            # differential equations always precede algebraic equations
            _iszero(dvar) && break
            g_row = get(dvar2eq, dvar, 0)
            iszero(g_row) && error("$dvar isn't handled.")
            g_row > size(g, 1) && continue
            @views copyto!(sorted_g_rows[i, :], g[g_row, :])
        end
        # Fix for https://github.com/SciML/ModelingToolkit.jl/issues/2490
        if sorted_g_rows isa AbstractMatrix && size(sorted_g_rows, 2) == 1
            # If there's only one brownian variable referenced across all the equations,
            # we get a Nx1 matrix of noise equations, which is a special case known as scalar noise
            noise_eqs = sorted_g_rows[:, 1]
            is_scalar_noise = true
        elseif isdiag(sorted_g_rows)
            # If the noise matrix is diagonal, then the solver just takes a vector column of equations
            # and it interprets that as diagonal noise.
            noise_eqs = diag(sorted_g_rows)
            is_scalar_noise = false
        else
            noise_eqs = sorted_g_rows
            is_scalar_noise = false
        end
        return SDESystem(full_equations(ode_sys), noise_eqs,
            get_iv(ode_sys), unknowns(ode_sys), parameters(ode_sys);
            name = nameof(ode_sys), is_scalar_noise)
    end
end
