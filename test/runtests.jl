using GeneralMetadata
using Repology: Repology
using Test
using Pkg: Pkg, Registry
using Dates: Dates, DateTime

@testset "Package coverage" begin
    cd(GeneralMetadata.general_repo()) do
        # Roll the registry back to the commit at the time of the last recorded update
        meta = GeneralMetadata.metadata()
        timestamp = GeneralMetadata.last_update(meta) + Dates.Millisecond(500) # --before is exclusive
        last_commit = split(readchomp(`git rev-list --first-parent --before=$(timestamp)Z master`), "\n")[1]
        run(`git checkout --quiet --force $last_commit`)
        reg = Registry.RegistryInstance(pwd())
        last_update = GeneralMetadata.last_update(meta)

        # Ensure all registry packages are present in the metadata, and that all versions present in the metadata are present in the registry
        all_registered_names = Set(values(reg.pkgs) .|> x->x.name)
        in_meta_but_not_registered = Pair{String,String}[]
        for (pkg, pkginfo) in meta
            @test pkg in all_registered_names
            reg_info = GeneralMetadata.registered_package_versions(pkg; registry=reg)
            for (ver, verinfo) in pkginfo
                if !haskey(reg_info, VersionNumber(ver))
                    push!(in_meta_but_not_registered, (pkg=>ver))
                end
            end
        end
        @test isempty(in_meta_but_not_registered)

        # And vice-versa: all registry metadata packages are present in the registry...
        in_registry_but_not_meta = Pair{String,String}[]
        for (pkguuid, pkginfo) in reg.pkgs
            pkg_name = pkginfo.name
            meta_info = get(meta, pkg_name, Dict{String,Any}())
            reg_info = GeneralMetadata.registered_package_versions(pkguuid; registry=reg)
            for (ver, verinfo) in reg_info
                if !haskey(meta_info, string(ver))
                    push!(in_registry_but_not_meta, (pkg_name=>string(ver)))
                end
            end
         end
         @test isempty(in_registry_but_not_meta)
     end
end

@testset "package TOML schema" begin
    meta = GeneralMetadata.metadata(; expand_artifact_urls=false)
    for (pkg, pkginfo) in meta
        @test !isempty(pkginfo)
        for (ver, verinfo) in pkginfo
            # All packages must be registered
            @test haskey(verinfo, "registered")
            @test verinfo["registered"] isa DateTime
            # But yanked is optional
            if haskey(verinfo, "yanked")
                @test verinfo["yanked"] isa DateTime
            end
            # Some packages might be missing artifact URL info, unfortunately
            if haskey(verinfo, "artifact_urls")
                @test verinfo["artifact_urls"] isa Vector
                @test all(x->isa(x, String), verinfo["artifact_urls"])
            end
            if haskey(verinfo, "artifact_metadata")
                @test verinfo["artifact_metadata"] isa Vector
                for ainfo in verinfo["artifact_metadata"]
                    @test ainfo isa Dict
                    if haskey(ainfo, "artifact_urls")
                        @test ainfo["artifact_urls"] isa Vector
                        @test all(x->isa(x, String), ainfo["artifact_urls"])
                        @test all(in(get(verinfo, "artifact_urls", String[])), ainfo["artifact_urls"])
                    else
                        @test length(verinfo["artifact_metadata"]) == 1
                    end

                    if get(ainfo, "metadata_type", "") != "JLLGenerator JLL.toml"
                        @test haskey(ainfo, "buildscript")
                        @test ainfo["buildscript"] isa String
                    end
                    @test haskey(ainfo, "metadata_source")
                    @test ainfo["metadata_source"] isa String
                    @test haskey(ainfo, "metadata_type")
                    @test ainfo["metadata_type"] isa String
                    @test haskey(ainfo, "metadata_version")
                    @test ainfo["metadata_version"] isa String
                    @test haskey(ainfo, "metadata")
                    @test ainfo["metadata"] isa String
                    if !contains(ainfo["metadata"], "://")
                        @test isfile(joinpath(@__DIR__, "..", ainfo["metadata"]))
                    end

                    sources = get(ainfo, "sources", [])
                    @test sources isa Vector
                    for src in sources
                        @test src isa Dict
                        if haskey(src, "type")
                            @test src["type"] isa String
                            @test src["type"] in ["file", "archive", "git", "directory", "builddependency"]
                        end
                        if haskey(src, "type") && src["type"] == "builddependency"
                            @test haskey(src, "package")
                            @test src["package"] isa String
                            # TODO: will need to add versioning information
                        elseif get(src, "type", "") == "directory" && haskey(src, "path")
                            @test src["path"] isa String
                            @test src["treehash"] isa String
                        else
                            # all other types have `url`
                            @test haskey(src, "url")
                            @test src["url"] isa String
                            if get(src, "type", "") != "directory"
                                # and all other types except directory have a hash
                                @test haskey(src, "hash") || haskey(src, "treehash")
                                @test get(src, "hash", get(src, "treehash", nothing)) isa String
                            end
                        end
                        if haskey(src, "upstream")
                            @test src["upstream"] isa Dict
                            @test haskey(src["upstream"], "project")
                            @test src["upstream"]["project"] isa String
                            # Entries from before provenance was recorded only gain it in a full regeneration
                            haskey(src["upstream"], "provenance") && @test src["upstream"]["provenance"] in (Repology.PROVENANCES..., "manual")
                            if haskey(src["upstream"], "version")
                                @test src["upstream"]["version"] isa String
                            end
                        end
                    end
                end
            end
        end
    end
end

@testset "JLLGenerator sources" begin
    contents = """
    format_version = "1.0"
    [[builds]]
    [[builds.artifact.download_sources]]
    url = "https://example.org/one.tar.gz"
    [[builds.sources]]
    url = "https://github.com/example/project.git"
    treehash = "sha1:$("a"^40)"
    [[builds.sources]]
    url = "https://example.org/source.tar.gz"
    treehash = "sha1:$("b"^40)"
    [[builds.sources]]
    url = "/cache/machine-one/yggdrasil/H/HelloWorldCxx/bundled"
    treehash = "sha1:$("c"^40)"
    [[builds]]
    [[builds.artifact.download_sources]]
    url = "https://example.org/two.tar.gz"
    [[builds.sources]]
    url = "/cache/machine-two/yggdrasil/H/HelloWorldCxx/bundled"
    treehash = "sha1:$("c"^40)"
    [[builds.sources]]
    url = "https://example.org/patch.txt"
    treehash = "sha1:$("d"^40)"
    """
    artifactmeta = Dict{String,Any}("metadata_type" => "JLLGenerator JLL.toml",
        "artifact_urls" => ["https://example.org/one.tar.gz", "https://example.org/two.tar.gz"])
    sources = GeneralMetadata.parse_artifact_metadata_sources(contents, artifactmeta)
    @test sources == [
        Dict("type" => "git", "url" => "https://github.com/example/project.git", "hash" => "a"^40),
        Dict("type" => "archive", "url" => "https://example.org/source.tar.gz", "treehash" => "b"^40),
        Dict("type" => "directory", "path" => "H/HelloWorldCxx/bundled", "treehash" => "c"^40),
        Dict("type" => "file", "url" => "https://example.org/patch.txt", "treehash" => "d"^40)]
    for source in sources
        source["upstream"] = Dict("project" => "repology.org/project/example")
        delete!(source, "upstream")
    end
    verinfo = Dict("artifact_urls" => copy(artifactmeta["artifact_urls"]))
    delete!(artifactmeta, "artifact_urls")
    @test GeneralMetadata.parse_artifact_metadata_sources(contents, artifactmeta, verinfo) == sources
    artifactmeta["artifact_urls"] = ["https://example.org/one.tar.gz"]
    @test GeneralMetadata.parse_artifact_metadata_sources(contents, artifactmeta, verinfo) == sources[1:3]
    @test GeneralMetadata.parse_artifact_metadata_sources(contents, artifactmeta) == sources[1:3]
    artifactmeta["artifact_urls"] = String[]
    @test isempty(GeneralMetadata.parse_artifact_metadata_sources(contents, artifactmeta, verinfo))
    @test isempty(GeneralMetadata.parse_artifact_metadata_sources(contents, artifactmeta))
    @test isempty(GeneralMetadata.parse_artifact_metadata_sources("", artifactmeta))
    @test_throws GeneralMetadata.TOML.ParserError GeneralMetadata.parse_artifact_metadata_sources("[", artifactmeta)
end

@testset "Expand artifact metadata URLs" begin
    urls = ["https://example.org/one.tar.gz", "https://example.org/two.tar.gz"]
    inherited = Dict{String,Any}()
    subset = Dict("artifact_urls" => urls[1:1])
    empty = Dict("artifact_urls" => String[])
    unknown = Dict{String,Any}()
    pkgmeta = Dict(
        "1.0.0" => Dict("artifact_urls" => urls, "artifact_metadata" => [inherited]),
        "2.0.0" => Dict("artifact_metadata" => [unknown]),
        "3.0.0" => Dict("artifact_urls" => urls, "artifact_metadata" => [subset, empty]),
    )
    GeneralMetadata.expand_artifact_urls!(pkgmeta)
    @test inherited["artifact_urls"] == urls
    @test inherited["artifact_urls"] !== urls
    @test subset["artifact_urls"] == urls[1:1]
    @test isempty(empty["artifact_urls"])
    @test !haskey(unknown, "artifact_urls")
    push!(pkgmeta["1.0.0"]["artifact_metadata"], Dict{String,Any}())
    @test_throws ArgumentError GeneralMetadata.expand_artifact_urls!(pkgmeta)
end

@testset "Append artifact metadata URLs" begin
    urls = ["https://example.org/one.tar.gz", "https://example.org/two.tar.gz"]
    verinfo = Dict{String,Any}("artifact_urls" => urls)
    full = Dict{String,Any}()
    subset = Dict{String,Any}()
    GeneralMetadata.append_artifact_metadata!(verinfo, full, urls)
    @test !haskey(full, "artifact_urls")
    GeneralMetadata.append_artifact_metadata!(verinfo, subset, urls[1:1])
    @test full["artifact_urls"] == urls
    @test subset["artifact_urls"] == urls[1:1]
    second_full = Dict{String,Any}()
    GeneralMetadata.append_artifact_metadata!(verinfo, second_full, urls)
    @test second_full["artifact_urls"] == urls
end

struct JLLReleaseFixture
    status::Int
    jll_contents::Union{String,Nothing}
    readme::Union{String,Nothing}
end
const FIXTURE_TREE = "a"^40
const FIXTURE_COMMIT = "b"^40

GeneralMetadata.GitHub.get_release(org, repo::JLLReleaseFixture, tag) =
    throw(GeneralMetadata.HTTP.Exceptions.StatusError(repo.status, "GET", "/releases/tags/$tag", nothing))
function GeneralMetadata.GitHub.registered_jll_commit(org, repo::JLLReleaseFixture, tag, tree_sha)
    @test tree_sha == FIXTURE_TREE
    return FIXTURE_COMMIT, false
end
function GeneralMetadata.GitHub.get_file(org, repo::JLLReleaseFixture, tree_sha, path_filter)
    @test tree_sha == FIXTURE_TREE
    return path_filter("JLL.toml") ? repo.jll_contents : repo.readme
end
# Reaching this means the README passed validation; stop before cloning Yggdrasil
GeneralMetadata.GitHub.commit_timestamp(org, repo::JLLReleaseFixture, commit) = error("reached wrapper commit timestamp")

@testset "Missing JLL releases use General's tree" begin
    versions = Dict(v"1.2.3+0" => (git_tree_sha1=FIXTURE_TREE,))
    lookup(args...) = GeneralMetadata.metadata_for_jll_release("JuliaBinaryWrappers", JLLReleaseFixture(args...), "Example-v1.2.3+0", versions)

    # BB2: JLL.toml in the registered tree
    meta = lookup(404, "format_version = \"1.0\"", nothing)
    @test endswith(meta["metadata"], "/$FIXTURE_COMMIT/JLL.toml")
    @test meta["metadata_type"] == "JLLGenerator JLL.toml"
    @test meta["metadata_version"] == "1.0"

    # BB1: requires a README link pinned to a Yggdrasil commit
    readme(ref) = """
    # `Example_jll.jl` (v1.2.3+0)
    originating [`build_tarballs.jl`](https://github.com/JuliaPackaging/Yggdrasil/blob/$ref/E/Example/build_tarballs.jl)
    """
    @test_throws "no pinned Yggdrasil recipe link" lookup(404, nothing, nothing)
    @test_throws "no pinned Yggdrasil recipe link" lookup(404, nothing, readme("master"))
    @test_throws "reached wrapper commit timestamp" lookup(404, nothing, readme("c"^40))

    # Only 404s fall back
    @test_throws GeneralMetadata.HTTP.Exceptions.StatusError lookup(403, "format_version = \"1.0\"", nothing)
end
