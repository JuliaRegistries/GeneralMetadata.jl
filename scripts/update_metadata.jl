using GeneralMetadata

function main()
    meta = GeneralMetadata.metadata(; expand_artifact_urls=false)
    GeneralMetadata.update_registration_dates!(meta)
    GeneralMetadata.update_artifact_urls!(meta)
    GeneralMetadata.update_jll_metadata!(meta)
    GeneralMetadata.extract_jll_sources!(meta)
    GeneralMetadata.identify_upstream!(meta; regenerate=get(ENV, "REGENERATE_UPSTREAM", "false") == "true")
    GeneralMetadata.save_metadata!(meta)
    return meta
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

# updates: 4
