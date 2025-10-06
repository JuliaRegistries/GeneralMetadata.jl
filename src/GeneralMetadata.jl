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

function extract_registration_dates(dates = registration_dates(); after=maximum(Iterators.flatmap(values, Iterators.flatmap(values, values(dates))), init=DateTime("2018-08-08T17:02:39")), before=after + Dates.Year(1))
    # This uses --first-parent to get the _availability_ date on master
    cd(general_repo()) do
        commits = split(readchomp(`git rev-list --first-parent --reverse --after=$(after)Z --before=$(before)Z master`), "\n")
        N = length(commits)
        @info "processing $(N) commits from $(commits[begin])..$(commits[end])"
        t = Dates.now()-Dates.Hour(1)
        fastpaths = 0
        for (i, commit) in enumerate(commits)
            fastpaths += process_commit!(dates, commit)
            (Dates.now()-t) > Dates.Second(60) && (println("commit: ", commit, " ($i/$N; $fastpaths/$i fastpaths)"); t = Dates.now())
        end
    end
    return dates
end

function extract_simple_tags_from_diff(commit)
    # Rather than using a general Diff/TOML parser, this just very specifically parses the typical one-package diff
    # to Versions.toml. If we can't match this, then we fall back to checking out and parsing the entire registry (slow!).
    diff = readchomp(`git show --first-parent $commit -U0 --no-commit-id --no-notes --pretty="" -- '*/Versions.toml'`)
    newlines = findall(==('\n'), diff)
    positions = [0; newlines[8:8:end]; length(diff)]
    regex = r"""
        ^\Qdiff --git a/\E(.*)\Q/Versions.toml b/\E\1\Q/Versions.toml
        index \E.*\Q
        --- a/\E\1\Q/Versions.toml
        +++ b/\E\1\Q/Versions.toml
        @@ \E.*\Q
        +
        +["\E(.*)\Q"]
        +git-tree-sha1 = "\E.*\Q"\E$"""
    pkg_vers = Pair{String,String}[]
    for i in 1:length(positions)-1
        chunk = SubString(diff, positions[i]+1, positions[i+1])
        m = match(regex, chunk)
        isnothing(m) && return nothing
        path, ver = m.captures
        push!(pkg_vers, splitpath(path)[end] => ver)
    end
    return pkg_vers
end

function process_commit!(dates, commit)
    # First attempt to direclty extract a new tag from the diff directly
    stamp = readchomp(addenv(`git log $commit -1 --format="%cd" --date=iso-strict-local`, "TZ"=>"UTC"))
    timestamp = parse(DateTime, chopsuffix(chopsuffix(stamp, "+00:00"), "Z"))
    pkg_vers = extract_simple_tags_from_diff(commit)
    if !isnothing(pkg_vers)
        fastpath = true
        for (pkg, ver) in pkg_vers
            if !haskey(dates, pkg)
                dates[pkg] = Dict{String, Any}()
            end
            @assert !haskey(dates[pkg], ver) "commit $commit introduced $pkg $ver, but it's already set"
            dates[pkg][ver] = Dict{String,Any}("registered" => timestamp)
        end
    else
        fastpath = false
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
                isempty(info) && continue # There has been at least one time when a corrupted entry was commited (a60167d6c29b433119d6fbf051a733fa465e6ae7)
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
    return fastpath
end

end
