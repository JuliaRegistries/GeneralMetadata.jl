using TOML: TOML
using JSON: JSON
using DataStructures: OrderedDict

function main()
    allversions = TOML.parsefile(joinpath(@__DIR__, "..", "registration_dates.toml"))
    general = only(filter(x->x.uuid==Base.UUID("23338594-aafe-5451-b93e-139f81909106"), Pkg.Registry.reachable_registries()))
    root = mkpath(joinpath(@__DIR__, "..", "webroot", "api"))
    for (pkg, versions) in allversions
        pkgdir = mkpath(joinpath(root, pkg))
        JSON.json(joinpath(pkgdir, "versions.json"), sort(OrderedDict(versions), by=VersionNumber))
        JSON.json(joinpath(pkgdir, "info.json"), (; name=pkg, uuid=string(only(Pkg.Registry.uuids_from_name(general, pkg)))))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
