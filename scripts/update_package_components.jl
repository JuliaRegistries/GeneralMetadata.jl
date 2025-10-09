using TOML: TOML
using DataStructures: DefaultOrderedDict, OrderedDict
using CSV: CSV
using DataFrames: DataFrames, DataFrame, groupby, combine, transform, combine, eachrow

using GeneralMetadata: add_components!

function main()
    # Load Repology data and reshape for efficiency
    repology_info = TOML.parsefile(joinpath(@__DIR__, "..", "repology_info.toml"))
    additional_info = TOML.parsefile(joinpath(@__DIR__, "..", "additional_info.toml"))
    repositories = Dict{String, String}()
    url_patterns = Pair{Regex, String}[]
    for (proj, info) in repology_info
        if haskey(info, "repositories")
            for repo in info["repositories"]
                # Allow repositories both with and without a git suffix
                repositories[chopsuffix(repo, ".git")] = proj
                repositories[chopsuffix(repo, ".git")*".git"] = proj
            end
        end
        if haskey(info, "url_patterns")
            for pattern in info["url_patterns"]
                # And allow both http and https
                push!(url_patterns, (Regex(replace(pattern, r"https?://" => "http\\Es?\\Q://"), "i") => proj))
            end
        end
    end

    for (proj, info) in additional_info
        if haskey(info, "repositories")
            for repo in info["repositories"]
                # Allow repositories both with and without a git suffix
                repositories[chopsuffix(repo, ".git")] = proj
                repositories[chopsuffix(repo, ".git")*".git"] = proj
            end
        end
        if haskey(info, "url_patterns")
            for pattern in info["url_patterns"]
                # And allow both http and https
                push!(url_patterns, (Regex(replace(pattern, r"https?://" => "http\\Es?\\Q://"), "i") => proj))
            end
        end
    end

    # Now walk through the JLL metadata to populate the package_components
    jll_metadata = TOML.parsefile(joinpath(@__DIR__, "..", "jll_metadata.toml"))
    package_components = DefaultOrderedDict{String, Any}(()->DefaultOrderedDict{String, Any}(()->OrderedDict{String, Any}()))
    git_cache = Dict{String,String}()
    for (jllname, jllinfo) in sort(OrderedDict(jll_metadata))
        for (jllversion, verinfo) in sort(OrderedDict(jllinfo), by=VersionNumber)
            haskey(verinfo, "sources") || continue
            for source in verinfo["sources"]
                add_components!(package_components[jllname][jllversion], source; repositories, url_patterns, git_cache)
            end
        end
    end

    # Flatten arrays of versions if they are not needed
    for (_, pkginfo) in package_components, (_, components) in pkginfo, (component, component_versions) in components
        if length(component_versions) == 1
            components[component] = only(component_versions)
        elseif "*" in component_versions
            components[component] = "*"
        end
    end

    # Now update the existing package_components if any of our versions are better than what's stored
    package_components_toml = joinpath(@__DIR__, "..", "package_components.toml")
    out = TOML.parsefile(package_components_toml)
    for (jll, jllinfo) in package_components
        haskey(out, jll) || (out[jll] = Dict{String, Any}())
        for (jll_version, components) in jllinfo
            haskey(out[jll], jll_version) || (out[jll][jll_version] = Dict{String, Any}())
            for (component, component_versions) in components
                if !haskey(out[jll][jll_version], component) || out[jll][jll_version][component] == "*"
                    out[jll][jll_version][component] = component_versions
                end
            end
        end
    end

    # If a JLL has a component at _one_ version, ensure it's there on all versions by default:
    for (pkg, pkginfo) in out
        components = unique(Iterators.flatten(keys.(values(pkginfo))))
        for version in keys(jll_metadata[pkg])
            !haskey(pkginfo, version) && (pkginfo[version] = Dict{String, Any}())
            for component in components
                component in keys(pkginfo[version]) && continue
                pkginfo[version][component] = "*"
            end
        end
    end

    open(package_components_toml, "w") do f
        println(f, """
            # This file contains the mapping between a Julia package version and the upstream project(s) it directly provides.
            # The keys are package name and version, pointing to a table that maps from an included upstream project name
            # (as defined in upstream_project_info.toml) and its version(s). Typically versions can simply be a string, but
            # in rare cases packages may include more than one copy of an upstream project at differing versions. In such cases,
            # an array of multiple versions can be specified.
            #
            # This file is automatically updated, based upon the sources recorded in jll_metadata.toml; comments are not preserved.
            # The automatic update script (`scripts/update_package_components.jl`) assumes that if a project is included at _some_
            # package version, then it should have definitions (perhaps manually entered) at all versions. To explicitly state that
            # the project is not incorporated and prevent such suggestions, use an empty array.""")
        TOML.print(f, out,
            inline_tables=IdSet{Dict{String,Any}}(vertable for jlltable in values(out) for vertable in values(jlltable) if length(values(vertable)) <= 2),
            sorted = true, by = x->something(tryparse(VersionNumber, x), x))
    end
    return package_components
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
