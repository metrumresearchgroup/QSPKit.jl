# Tests for event composition (seq, combine) and regimen templates (QD, BID, Q4W, loading_then)

using InjecKit
using Test

@testset "Event Composition" begin

    @testset "seq — sequential chaining" begin
        @testset "basic chaining" begin
            e1 = [ev(time=0.0, cmt=:C, amt=100.0)]
            e2 = [ev(time=0.0, cmt=:C, amt=50.0)]
            result = seq(e1, e2)
            @test length(result) == 2
            @test result[1].time == 0.0
            @test result[1].amt == 100.0
            @test result[2].time == 0.0  # e1 end time is 0.0, so offset is 0.0
            @test result[2].amt == 50.0
        end

        @testset "chaining with later start" begin
            e1 = [ev(time=5.0, cmt=:C, amt=100.0)]
            e2 = [ev(time=0.0, cmt=:C, amt=50.0), ev(time=2.0, cmt=:C, amt=25.0)]
            result = seq(e1, e2)
            @test length(result) == 3
            @test result[1].time == 5.0
            @test result[2].time == 5.0   # 0.0 + 5.0
            @test result[3].time == 7.0   # 2.0 + 5.0
        end

        @testset "chaining with ii/addl repeats" begin
            # e1 has time=0, ii=24, addl=2 -> end time = 0 + 24*2 = 48
            e1 = [ev(time=0.0, cmt=:C, amt=100.0, ii=24.0, addl=2)]
            e2 = [ev(time=0.0, cmt=:C, amt=50.0)]
            result = seq(e1, e2)
            @test length(result) == 2
            @test result[2].time == 48.0  # offset by end time of e1
        end

        @testset "chaining with multiple events and ii/addl" begin
            e1 = [
                ev(time=0.0, cmt=:C, amt=100.0, ii=12.0, addl=3),  # end = 0 + 12*3 = 36
                ev(time=10.0, cmt=:C, amt=50.0)                      # end = 10
            ]
            e2 = [ev(time=0.0, cmt=:C, amt=25.0)]
            result = seq(e1, e2)
            @test result[3].time == 36.0  # max(36, 10) = 36
        end

        @testset "empty vectors" begin
            e1 = IEvent[]
            e2 = [ev(time=0.0, cmt=:C, amt=100.0)]
            @test seq(e1, e2) == e2
            @test seq(e2, e1) == e2
            @test isempty(seq(e1, e1))
        end

        @testset "single events" begin
            e1 = [ev(time=0.0, cmt=:C, amt=100.0)]
            e2 = [ev(time=0.0, cmt=:C, amt=50.0)]
            result = seq(e1, e2)
            @test length(result) == 2
        end

        @testset "preserves event properties" begin
            e1 = [ev(time=0.0, cmt=:C, amt=100.0)]
            e2 = [ev(time=0.0, cmt=:depot, amt=50.0, rate=10.0, duration=5.0, ii=12.0, addl=2)]
            result = seq(e1, e2)
            shifted = result[2]
            @test shifted.cmt == :depot
            @test shifted.amt == 50.0
            @test shifted.rate == 10.0
            @test shifted.duration == 5.0
            @test shifted.ii == 12.0
            @test shifted.addl == 2
        end
    end

    @testset "combine — merge and sort" begin
        @testset "basic merge" begin
            e1 = [ev(time=0.0, cmt=:C, amt=100.0), ev(time=10.0, cmt=:C, amt=100.0)]
            e2 = [ev(time=5.0, cmt=:C, amt=50.0)]
            result = InjecKit.combine(e1, e2)
            @test length(result) == 3
            @test result[1].time == 0.0
            @test result[2].time == 5.0
            @test result[3].time == 10.0
        end

        @testset "same-time events preserved" begin
            e1 = [ev(time=0.0, cmt=:C, amt=100.0)]
            e2 = [ev(time=0.0, cmt=:depot, amt=50.0)]
            result = InjecKit.combine(e1, e2)
            @test length(result) == 2
            @test all(e -> e.time == 0.0, result)
        end

        @testset "empty vectors" begin
            e1 = IEvent[]
            e2 = [ev(time=5.0, cmt=:C, amt=50.0)]
            @test InjecKit.combine(e1, e2) == e2
            @test InjecKit.combine(e2, e1) == e2
            @test isempty(InjecKit.combine(e1, e1))
        end

        @testset "already sorted" begin
            e1 = [ev(time=0.0, cmt=:C, amt=100.0)]
            e2 = [ev(time=10.0, cmt=:C, amt=50.0)]
            result = InjecKit.combine(e1, e2)
            @test result[1].time == 0.0
            @test result[2].time == 10.0
        end

        @testset "does not mutate inputs" begin
            e1 = [ev(time=5.0, cmt=:C, amt=100.0)]
            e2 = [ev(time=1.0, cmt=:C, amt=50.0)]
            InjecKit.combine(e1, e2)
            @test e1[1].time == 5.0
            @test e2[1].time == 1.0
        end
    end
end

@testset "Regimen Templates" begin

    @testset "QD — once daily" begin
        @testset "single day" begin
            e = QD(100.0, :C)
            @test e.amt == 100.0
            @test e.cmt == :C
            @test e.ii == 1.0
            @test e.addl == 0
        end

        @testset "multiple days" begin
            e = QD(100.0, :C; days=7)
            @test e.ii == 1.0
            @test e.addl == 6
        end

        @testset "with extra kwargs" begin
            e = QD(100.0, :C; days=3, rate=10.0)
            @test e.rate == 10.0
            @test e.addl == 2
        end
    end

    @testset "BID — twice daily" begin
        @testset "single day" begin
            e = BID(50.0, :C)
            @test e.amt == 50.0
            @test e.cmt == :C
            @test e.ii == 0.5
            @test e.addl == 1  # 2*1 - 1
        end

        @testset "multiple days" begin
            e = BID(50.0, :C; days=3)
            @test e.ii == 0.5
            @test e.addl == 5  # 2*3 - 1
        end
    end

    @testset "Q4W — every 4 weeks" begin
        @testset "single dose" begin
            e = Q4W(200.0, :C)
            @test e.amt == 200.0
            @test e.cmt == :C
            @test e.ii == 28.0
            @test e.addl == 0
        end

        @testset "multiple doses" begin
            e = Q4W(200.0, :C; doses=6)
            @test e.ii == 28.0
            @test e.addl == 5
        end

        @testset "with infusion rate" begin
            e = Q4W(2.25, :C; doses=3, rate=0.3)
            @test e.rate == 0.3
            @test e.addl == 2
        end
    end

    @testset "loading_then — loading + maintenance" begin
        @testset "basic loading then maintenance" begin
            result = loading_then(7.25, 1.5, :C; q=3.0, doses=5)
            @test length(result) == 2
            # Loading dose
            @test result[1].amt == 7.25
            @test result[1].time == 0.0
            @test result[1].cmt == :C
            # First maintenance dose is coadministered at the loading timestamp.
            @test result[2].time == 0.0
            @test result[2].amt == 1.5
            @test result[2].ii == 3.0
            @test result[2].addl == 4  # doses-1
        end

        @testset "with extra kwargs" begin
            result = loading_then(4.4, 0.65, :depot; q=2.5, doses=3, rate=0.2)
            @test result[1].rate == 0.2
            @test result[2].rate == 0.2
            @test result[1].cmt == :depot
            @test result[2].cmt == :depot
        end

        @testset "single maintenance dose" begin
            result = loading_then(1.1, 0.3, :C; q=5.5, doses=1)
            @test length(result) == 2
            @test result[2].addl == 0
        end
    end
end
