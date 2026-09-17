using Test
using QSPKit.QSPKitIO

Base.@kwdef struct _TinyOptions
    a::Int = 1
    b::Symbol = :x
end

struct _TinyResult
    options::_TinyOptions
    values::Vector{Float64}
    labels::Dict{Symbol, Int}
end

struct _RuntimeBox
    data::Int
    runtime::Any
end

struct _RefBox
    flag::Base.RefValue{Bool}
end

struct _DefaultBox
    a::Int
    b::Int
end

function _restore_runtime_box(::Type{_RuntimeBox}, env::AbstractDict, ctx)
    data = QSPKitIO.restore_payload(env["data"], ctx)
    return _RuntimeBox(data, :rebuilt)
end

@testset "QSPKitIO archive roundtrip" begin
    spec = ArchiveSpec("TinyResult";
        archive_version = 1,
        package_name = "QSPKitIOTest",
        package_module = QSPKitIO,
        archivable_modules = [:Main])
    payload = _TinyResult(_TinyOptions(a=3, b=:ok), [1.0, 2.0],
                          Dict(:A => 1, :B => 2))
    mktempdir() do dir
        path = joinpath(dir, "tiny.qio")
        native_payloads = Dict("runtime" => Dict("x" => 3))
        @test save_archive(path, payload; spec=spec,
                           manifest_extra=Dict("kind" => "unit-test"),
                           native_payloads=native_payloads) == path
        manifest = read_archive_manifest(path)
        @test manifest["format"] == "TinyResult"
        @test manifest["archive_version"] == 1
        @test manifest["kind"] == "unit-test"
        @test manifest["native_payload_keys"] == ["runtime"]
        @test has_archive_native_payload(path, "runtime")
        @test !has_archive_native_payload(path, "missing")
        @test read_archive_native_payload(path, "runtime") == native_payloads["runtime"]
        @test_throws ErrorException read_archive_native_payload(path, "missing")
        loaded = load_archive(path; expected_format="TinyResult",
                              max_archive_version=1)
        @test loaded isa _TinyResult
        @test loaded.options.a == 3
        @test loaded.options.b === :ok
        @test loaded.values == [1.0, 2.0]
        @test loaded.labels[:B] == 2
    end
end

@testset "QSPKitIO open-file-limit detection" begin
    @test QSPKitIO._is_open_file_limit_error(
        SystemError("opening file", Base.Libc.EMFILE, nothing))
    @test !QSPKitIO._is_open_file_limit_error(
        SystemError("opening file", Base.Libc.ENOENT, nothing))
end

@testset "QSPKitIO archive hooks" begin
    spec = ArchiveSpec("Hooked";
        archive_version = 1,
        package_name = "QSPKitIOTest",
        package_module = QSPKitIO,
        archivable_modules = [:Main],
        skip_fields = Dict(_RuntimeBox => (:runtime,)),
        ref_fields = Dict(_RefBox => (:flag,)),
        restore_handlers = Dict(_RuntimeBox => _restore_runtime_box),
        default_fields = Dict((_DefaultBox, :b) => (_T, _name) -> 9),
    )

    ctx = QSPKitIO.ArchiveContext(spec)
    runtime_box = _RuntimeBox(3, :live)
    archived_runtime = QSPKitIO.archive_payload(runtime_box, ctx)
    @test !haskey(archived_runtime, "runtime")
    restored_runtime = QSPKitIO.restore_payload(archived_runtime, spec)
    @test restored_runtime.runtime === :rebuilt
    @test_throws ErrorException QSPKitIO.archive_payload(_RuntimeBox(3, () -> 3), ArchiveSpec("NoOpaque"; archivable_modules=[:Main]))

    ref_box = _RefBox(Ref(true))
    restored_ref = QSPKitIO.restore_payload(QSPKitIO.archive_payload(ref_box, spec), spec)
    @test restored_ref.flag[] === true

    default_box = _DefaultBox(1, 2)
    archived_default = QSPKitIO.archive_payload(default_box, spec)
    delete!(archived_default, "b")
    restored_default = QSPKitIO.restore_payload(archived_default, spec)
    @test restored_default.a == 1
    @test restored_default.b == 9
end
