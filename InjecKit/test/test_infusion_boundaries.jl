using Test, InjecKit, ModelingToolkitBase, Sundials

@testset "Infusion boundaries restart multistep solvers" begin
    @independent_variables t
    @variables A(t)=0.0
    @parameters k=0.56
    D = Differential(t)
    sys = mtkcompile(System([D(A) ~ -k*A],t;name=gensym(:infusion_boundary)))
    prob = ODEProblem(sys,[],(0.,3.))
    for start in (0.0,1.0)
        dose = ev(time=start,cmt=:A,amt=2.0,rate=4.0)
        runner = PreparedEventSolve(prob,[dose])
        sol = runner(;alg=CVODE_BDF(),abstol=1e-11,reltol=1e-10,saveat=0.05)
        @test InjecKit.SciMLBase.successful_retcode(sol)
        for time in (0.25,0.75,1.25,1.75,2.5)
            elapsed = time-start
            expected = elapsed < 0 ? 0.0 : elapsed <= 0.5 ?
                4/0.56*(1-exp(-0.56*elapsed)) :
                4/0.56*(1-exp(-0.56*0.5))*exp(-0.56*(elapsed-0.5))
            @test sol(time;idxs=A) ≈ expected rtol=1e-7 atol=1e-9
        end
    end
end
