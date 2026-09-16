using Test, SimKit, ModelingToolkit, DataFrames
using InjecKit: ev

@testset "Periodic steady state" begin
    @test !has_steady_state([ev(cmt=:A, amt=10)])
    @test has_steady_state([ev(cmt=:A, amt=10, ss=1, ii=7)])

    opts = SteadyStateOptions(abstol=1e-10, reltol=1e-9)
    @test_throws ArgumentError SteadyStateOptions(reltol=0)
    @test_throws ArgumentError SteadyStateOptions(min_cycles=1)
    @test_throws ArgumentError SteadyStateOptions(min_cycles=20, max_cycles=10)
    u0 = [0.0, 0.0]
    ss = advance_to_steady_state(u -> reshape([0.5u[1]+1, 0.95u[2]+1],2,1), u0; options=opts)
    @test ss.state ≈ [2,20] rtol=3e-8
    @test ss.cycles > 10 # the slow compartment must also converge
    @test ss.error <= 1
    @test u0 == [0,0]
    @test_throws ErrorException advance_to_steady_state(u -> reshape(u .+ 1,2,1), u0;
        options=SteadyStateOptions(max_cycles=12))
    @test_throws ErrorException advance_to_steady_state(u -> fill(NaN,2,1), u0)
    # End-of-infusion changes cannot be hidden by a constant trough.
    count_cycles = Ref(0)
    changing_peak = u -> (count_cycles[] += 1; [Float64(count_cycles[]) 1.0])
    @test_throws ErrorException advance_to_steady_state(changing_peak, [0.0];
        options=SteadyStateOptions(max_cycles=12))
    for dose in (ev(cmt=:A,amt=10,ss=2,ii=7), ev(cmt=:A,amt=10,ss=1),
                 ev(cmt=:A,amt=10,ss=1,ii=7,rate=1), ev(time=1,cmt=:A,amt=10,ss=1,ii=7),
                 ev(cmt=:A,amt=10,ss=1,ii=7,rate=-1))
        @test_throws ArgumentError steady_state_regimen([dose],0.0)
    end
    r = steady_state_regimen([ev(cmt=:A,amt=10,ss=1,ii=7,addl=2)],0.0)
    @test only(r.forward).addl == 2
    @test only(r.forward).ss === nothing
    df = DataFrame(ID=[1,1],TIME=[0.,1.],EVID=[1,0],AMT=[10.,missing],
        CMT=[:A,:A],II=[7.,missing],SS=[1,missing])
    pop = Population(df; time=:TIME, evid=:EVID, amt=:AMT, cmt=:CMT, steady_state=:converge)
    @test only(pop[1].events).ss == 1
    @test only(pop[1].events).time == 0.0

    # Endogenous production and deliberately different time constants.
    @independent_variables t
    @variables A(t)=3.0 B(t)=4.0
    @parameters k=0.3 production=0.9
    D = Differential(t)
    sys = mtkcompile(System([D(A) ~ production-k*A, D(B) ~ 0.01*(4-B)],t;name=gensym(:ss)))
    prob = ODEProblem(sys,[],(0.,14.))
    original_u0 = copy(prob.u0)
    stage_events = isdefined(SimKit,:dose) ? SimKit.dose : SimKit.events
    for rate in (nothing, 10.0)
        event = ev(cmt=:A,amt=20,rate=rate,ii=7,addl=1,ss=1)
        ctx = SimContext(prob; solver=SimKit.OrdinaryDiffEq.Tsit5()) |>
            stage_events([event]) |> simulate(14.; saveat=0.25, abstol=1e-11, reltol=1e-10, ss_options=opts)
        duration = rate === nothing ? 0.0 : 2.0
        trough = rate === nothing ? 20/(exp(0.3*7)-1) :
            10/0.3*(1-exp(-0.3*duration))*exp(-0.3*(7-duration))/(1-exp(-0.3*7))
        for time in (0.25,1.0,2.5,6.75,7.25,8.0,9.5,13.75)
            phase = mod(time,7)
            expected = if rate === nothing
                3 + (trough+20)*exp(-0.3*phase)
            elseif phase <= duration
                3 + trough*exp(-0.3*phase) + 10/0.3*(1-exp(-0.3*phase))
            else
                3 + (trough*exp(-0.3*duration)+10/0.3*(1-exp(-0.3*duration)))*exp(-0.3*(phase-duration))
            end
            @test ctx.sol(time; idxs=A) ≈ expected rtol=1e-7
            @test ctx.sol(time; idxs=B) ≈ 4.0 rtol=1e-7
        end
    end
    @test prob.u0 == original_u0
end
