using Test

pkg_dir  = dirname(@__DIR__)
src      = read(joinpath(pkg_dir, "src", "Tab_Simulation_Callbacks.jl"), String)

starts   = [m.offset for m in eachmatch(r"callback!\(", src)]
blocks   = [src[starts[i]:(i < length(starts) ? starts[i+1]-1 : end)] for i in eachindex(starts)]

is_load  = b -> occursin(r"Input\(\s*\"load-state-diagram-button\"", b)
is_save  = b -> occursin("@save file ", b)

@testset "save/load state wiring" begin
    load_blocks = filter(is_load, blocks)
    save_blocks = filter(is_save, blocks)

    @test length(load_blocks) >= 6
    @test length(save_blocks) == 1

    @testset "load callbacks read the load filename field" begin
        for b in load_blocks
            @test !occursin("save-state-filename-id", b)
        end
    end

    @testset "save callback reads the save filename field" begin
        for b in save_blocks
            @test occursin("save-state-filename-id", b)
            @test !occursin("load-state-filename-id", b)
        end
    end

    @testset "every loaded option key is saved" begin
        save_line = only(m.captures[1] for m in eachmatch(r"@save file ([^\n]+)", src))
        saved     = Set(split(strip(save_line)))

        loaded = Set{String}()
        for b in load_blocks, m in eachmatch(r"@load file[ \t]+((?:\w+[ \t]*)+)", b)
            union!(loaded, split(strip(m.captures[1])))
        end

        @test !isempty(loaded)
        @test isempty(setdiff(loaded, saved))
    end
end
