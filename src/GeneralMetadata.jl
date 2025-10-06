module GeneralMetadata

import TOML, JSON3, HTTP, CSV
using DataFrames: DataFrames, DataFrame
using Dates: Dates, DateTime, Date, Day, Millisecond

function manifest_packages(manifest_path)
    collect(keys(TOML.parsefile(manifest_path)["deps"]))
end

# Write your package code here.
function license(packagename)
    JSON3.read(String(HTTP.get("https://juliahub.com/docs/General/$packagename/stable/pkg.json").body)).license
end

function write_csv_for_manifest(manifest_path, output_path)
    pkgs = manifest_packages(manifest_path)
    licenses = [(try license(pkg); catch ex; missing end) for pkg in pkgs]
    CSV.write(output_path, DataFrame(pkg=pkgs, license=licenses))
end

const GENERAL = Ref{String}()
function general_repo()
    isassigned(GENERAL) && return GENERAL[]
    dir = mktempdir()
    run(`git clone https://github.com/JuliaRegistries/General $dir`)
    return GENERAL[] = dir
end
const REGISTRATION_DATES = Ref{Dict{String, Any}}()
registration_dates() = isassigned(REGISTRATION_DATES) ? REGISTRATION_DATES[] :
    (REGISTRATION_DATES[] = isfile(joinpath(@__DIR__, "..", "registration_dates.toml")) ?
        TOML.parsefile(joinpath(@__DIR__, "..", "registration_dates.toml")) : Dict{String, Any}())

function extract_registration_dates(dates = registration_dates(); after=maximum(Iterators.flatmap(values, Iterators.flatmap(values, values(dates))), init=DateTime("2018-08-08T17:02:39")), before=Dates.now(Dates.UTC))
    # This uses --first-parent to get the _availability_ date on master
    cd(general_repo()) do
        commits = split(readchomp(`git rev-list --reverse --after=$(after)Z --before=$(before)Z master`), "\n")
        N = length(commits)
        @info "processing $(N) commits from $(commits[begin])..$(commits[end])"
        for (i, commit) in enumerate(commits)
            println("commit: ", commit, " ($i/$N)")
            process_commit!(dates, commit)
        end
    end
    return dates
end

function extract_single_tag_from_diff(commit)
    diff = readchomp(`git show $commit -U0 --no-commit-id --no-notes --pretty=""`)
    # Rather than using a general Diff/TOML parser, this just very specifically parses a known
    # common diff. If we can't match this, then we fall back to checking out and parsing the entire registry.
    regex = r"""
        ^\Qdiff --git a/\E(.*)\Q/Versions.toml b/\E\1\Q/Versions.toml
        index \E.*\Q
        --- a/\E\1\Q/Versions.toml
        +++ b/\E\1\Q/Versions.toml
        @@ \E.*\Q
        +
        +["\E(.*)\Q"]
        +git-tree-sha1 = "\E(.*)"$"""
    m = match(regex, diff)
    isnothing(m) && return nothing, nothing
    path, ver, sha = m.captures
    # This assumes the final path component is the package name
    return splitpath(path)[end], ver
end

function process_commit!(dates, commit)
    # First attempt to direclty extract a new tag from the diff directly
    timestamp = parse(DateTime, chopsuffix(readchomp(addenv(`git log $commit -1 --format="%cd" --date=iso-strict-local`, "TZ"=>"UTC")), "+00:00"))
    pkg, ver = extract_single_tag_from_diff(commit)
    if haskey(dates, pkg) && !haskey(dates[pkg], ver)
        dates[pkg][string(ver)] = Dict{String,Any}("registered" => timestamp)
    else
        # Checkout the entire state of the repo at this commit
        run(pipeline(`git checkout $commit`, stdout=Base.devnull, stderr=Base.devnull))
        reg = TOML.parsefile("Registry.toml")
        for (uuid, pkginfo) in reg["packages"]
            pkg = pkginfo["name"]
            isfile(joinpath(pkginfo["path"], "Versions.toml")) || continue
            versions = TOML.parsefile(joinpath(pkginfo["path"], "Versions.toml"))
            if !haskey(dates, pkg)
                dates[pkg] = Dict{String, Any}()
            end
            for (ver, info) in versions
                if !haskey(dates[pkg], ver)
                    dates[pkg][string(ver)] = Dict{String, Any}()
                end
                if !haskey(dates[pkg][string(ver)], "registered")
                    dates[pkg][string(ver)]["registered"] = timestamp
                end
                if get(info, "yanked", false) && !haskey(dates[pkg][string(ver)], "yanked")
                    dates[pkg][string(ver)]["yanked"] = timestamp
                end
            end
        end
    end
end

end
