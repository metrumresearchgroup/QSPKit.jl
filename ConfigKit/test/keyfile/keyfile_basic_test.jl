using Test
using QSPKit.ConfigKit
using Unitful
using OrderedCollections
using YAML

@testset "Keyfile Basic Functionality" begin
    
    @testset "Simple Parameter Parsing" begin
        path, io = mktemp()
        close(io)
        simple_yaml = """
        Parameters:
          clearance:
            abbr: "CL"
            value: 5.0
          volume:
            abbr: "V"
            value: 50.0
        Variables:
          drug_amount:
            abbr: "A"
            initial: 100.0
        """
        write(path, simple_yaml)
        
        try
            result = ConfigKit.parse_keyfile_for_defaults(path)
            @test result isa ConfigKit.KeyfileAccessor
            @test haskey(result.parameter_defaults, :clearance)
            @test result.parameter_defaults[:clearance] == 5.0
            @test haskey(result.parameter_defaults, :volume)
            @test result.parameter_defaults[:volume] == 50.0
            @test haskey(result.variable_initials, :drug_amount)
        finally
            rm(path, force=true)
        end
    end
    
    @testset "Variant Resolution" begin
        path, io = mktemp()
        close(io)
        variant_yaml = """
        Parameters:
          clearance:
            abbr: "CL"
            desc: "Clearance parameter"
            variants:
              adult:
                value: 10.0
              pediatric:
                value: 5.0
        Variables:
          drug_amount:
            abbr: "A"
            initial: 100.0
        """
        write(path, variant_yaml)
        
        try
            # Load with adult variant
            result_adult = ConfigKit.parse_keyfile_for_defaults(path; variant = "adult")
            @test result_adult isa ConfigKit.KeyfileAccessor
            @test haskey(result_adult.parameter_defaults, :clearance)
            @test result_adult.parameter_defaults[:clearance] == 10.0
            
            # Load with pediatric variant
            result_ped = ConfigKit.parse_keyfile_for_defaults(path; variant = "pediatric")
            @test result_ped.parameter_defaults[:clearance] == 5.0
        finally
            rm(path, force=true)
        end
    end
    
    @testset "Unit Handling" begin
        path, io = mktemp()
        close(io)
        units_yaml = """
        Parameters:
          rate:
            abbr: "k"
            value: 0.1
            unit: "1/hr"
        Variables:
          drug_amount:
            abbr: "A"
            initial: 100.0
        """
        write(path, units_yaml)
        
        try
            result = ConfigKit.parse_keyfile_for_defaults(path)
            @test result isa ConfigKit.KeyfileAccessor
            @test haskey(result.parameter_defaults, :rate)
            @test result.parameter_defaults[:rate] !== nothing
        finally
            rm(path, force=true)
        end
    end
    
    @testset "Constants Handling" begin
        path, io = mktemp()
        close(io)
        const_yaml = """
        Constants:
          PI_VALUE:
            abbr: "pi"
            value: 3.14159
        Parameters:
          radius:
            abbr: "r"
            value: 5.0
        Variables:
          area:
            abbr: "A"
            initial: 0.0
        """
        write(path, const_yaml)
        
        try
            result = ConfigKit.parse_keyfile_for_defaults(path)
            @test result isa ConfigKit.KeyfileAccessor
            # Constants should be in parameter_defaults in ConfigKit logic
            @test haskey(result.parameter_defaults, :PI_VALUE)
            @test result.parameter_defaults[:PI_VALUE] == 3.14159
            @test haskey(result.parameter_defaults, :radius)
        finally
            rm(path, force=true)
        end
    end
    
    @testset "load_keyfile convenience function" begin
        path, io = mktemp()
        close(io)
        test_yaml = """
        Parameters:
          param1:
            abbr: "p1"
            value: 1.0
        Variables:
          var1:
            abbr: "v1"
            initial: 0.0
        """
        write(path, test_yaml)
        
        try
            result = ConfigKit.load_keyfile(path)
            @test result isa ConfigKit.KeyfileAccessor
            @test haskey(result.parameter_defaults, :param1)
            @test haskey(result.variable_initials, :var1)
        finally
            rm(path, force=true)
        end
    end
end
