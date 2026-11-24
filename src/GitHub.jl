module GitHub

import HTTP, JSON
using Base64: base64decode


const API_BASE = "https://api.github.com"
function build_headers()
    headers = [
        "Accept" => "application/vnd.github+json",
        "User-Agent" => "JuliaRegistries-GeneralMetadata.jl-Fetcher/1.0"
    ]
    if haskey(ENV, "GITHUB_TOKEN")
        push!(headers, "Authorization" => "Bearer $(ENV["GITHUB_TOKEN"])")
    end
    return headers
end
function get_tags(owner, repo)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/tags"), build_headers())
    if response.status != 200
        error("Failed to fetch tags: HTTP $(response.status)")
    end

    return JSON.parse(response.body)
end
function get_releases(owner, repo)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/releases"), build_headers())
    if response.status != 200
        error("Failed to fetch releases: HTTP $(response.status)")
    end

    return JSON.parse(response.body)
end
function get_release(owner, repo, name)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/releases/tags/", name), build_headers())
    if response.status != 200
        error("Failed to fetch release for tag $name: HTTP $(response.status)")
    end

    return JSON.parse(response.body)
end
function commit_from_tagname(owner, repo, tag_name)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/git/ref/tags/", tag_name), build_headers())
    if response.status != 200
        error("Failed to fetch tag info for $tag_name: HTTP $(response.status)")
    end
    tagsinfo = JSON.parse(response.body)
    if haskey(tagsinfo, "object") && tagsinfo["object"]["type"] == "tag"
        # This is an annotated tag, so we need to dereference it to get the commit SHA
        lightweight_response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/git/tags/", tagsinfo["object"]["sha"]), build_headers())
        if lightweight_response.status != 200
            error("Failed to fetch lightweight tag info for $tag_name: HTTP $(lightweight_response.status)")
        end
        tagsinfo = JSON.parse(lightweight_response.body)
    end
    # This is a lightweight tag, so the object is the commit
    @assert tagsinfo["object"]["type"] == "commit"
    return tagsinfo["object"]["sha"]
end

function get_commit(owner, repo, commit_sha)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/git/commits/", commit_sha), build_headers())
    if response.status != 200
        error("Failed to fetch commit info for $commit_sha: HTTP $(response.status)")
    end
    return JSON.parse(response.body)
end

tree_sha_from_commit(owner, repo, commit_sha) = get_commit(owner, repo, commit_sha)["tree"]["sha"]
commit_timestamp(owner, repo, commit_sha) = get_commit(owner, repo, commit_sha)["committer"]["date"]

function find_commit_for_tree(repo_url, tree_sha)
    mktempdir() do dir
        run(`git clone --quiet --bare --filter=tree:0 $repo_url $dir`)
        for line in readlines(`git -C $dir log --all --format=%H%x20%T`)
            commit, tree = split(line)
            tree == tree_sha && return commit
        end
        return nothing
    end
end

function registered_jll_commit(owner, repo, tag, tree_sha)
    tagged_commit = try
        commit_from_tagname(owner, repo, tag)
    catch ex
        ex isa HTTP.Exceptions.StatusError && ex.status == 404 || rethrow()
        nothing
    end
    if !isnothing(tagged_commit) && tree_sha_from_commit(owner, repo, tagged_commit) == tree_sha
        return tagged_commit, true
    end
    commit = find_commit_for_tree("https://github.com/$owner/$repo.git", tree_sha)
    isnothing(commit) && error("no commit in $owner/$repo for $tag matches General's tree $tree_sha")
    return commit, false
end

get_readme(owner, repo, tree_sha) = get_file(owner, repo, tree_sha, ==("README.md"))
function get_file(owner, repo, tree_sha, path_filter)
    response = HTTP.get(string(API_BASE, "/repos/", owner, "/", repo, "/git/trees/", tree_sha), build_headers())
    if response.status != 200
        error("Failed to fetch file: HTTP $(response.status)")
    end

    tree = JSON.parse(response.body)
    file = filter(x->path_filter(x.path), tree.tree)
    isempty(file) && return nothing

    blob = JSON.parse(HTTP.get(file[].url, build_headers()).body)
    blob.encoding == "base64" || return nothing
    return String(base64decode(blob.content))
end

is_sha(str) = length(str) in (40, 64) && occursin(r"^[a-f0-9]+$", str)

end
