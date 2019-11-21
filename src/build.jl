using BinaryBuilder
using LibGit2
import SHA: sha256

function filehash(path)
    open(path, "r") do f
        bytes2hex(sha256(f))
    end
end

"""
    obtain_julia(the_ver)

Download the specified version of Julia using the information provided in `Versions.toml`.
"""
function obtain_julia(the_ver::VersionNumber)
    vers = read_versions()
    for (ver, data) in vers
        ver == string(the_ver) || continue
        dir = julia_path(ver)
        mkpath(dirname(dir))
        if haskey(data, "url")
            url = data["url"]

            file = get(data, "file", "julia-$ver.tar.gz")
            @assert !isabspath(file)
            file = downloads_dir(file)
            mkpath(dirname(file))

            Pkg.PlatformEngines.download_verify_unpack(url, data["sha"], dir;
                                                        tarball_path=file, force=true)
        else
            file = data["file"]
            !isabspath(file) && (file = downloads_dir(file))
            Pkg.PlatformEngines.verify(file, data["sha"])
            isdir(dir) || Pkg.PlatformEngines.unpack(file, dir)
        end
        return
    end
    error("Requested Julia version not found")
end

"""
    version = download_julia(name::String)

Download Julia from an on-line source listed in Builds.toml as identified by `name`.
Returns the `version` (what other functions use to identify this build).
This version will be added to Versions.toml.
"""

function download_julia(name::String)
    builds = read_builds()
    @assert haskey(builds, name) "Julia build $name is not registered in Builds.toml"
    data = builds[name]

    # get the filename and extension from the url
    url = data["url"]
    name = basename(url)
    dot_idx = findfirst(isequal('.'), name)
    ext = name[dot_idx+1:end]
    name = name[1:dot_idx-1]

    # download
    temp_file = downloads_dir(name)
    mkpath(dirname(temp_file))
    ispath(temp_file) && rm(temp_file)
    Pkg.PlatformEngines.download(url, temp_file)

    # unpack
    temp_dir = julia_path(name)
    ispath(temp_dir) && rm(temp_dir; recursive=true)
    Pkg.PlatformEngines.unpack(temp_file, temp_dir)

    # figure out stuff from the downloaded binary
    version = VersionNumber(read(`$(installed_julia_dir(name))/bin/julia -e 'print(Base.VERSION_STRING)'`, String))
    if version.prerelease != ()
        commit_short = read(`$(installed_julia_dir(name))/bin/julia -e 'print(Base.GIT_VERSION_INFO.commit_short)'`, String)
        version = VersionNumber(string(version) * string("-", commit_short))
    end
    rm(temp_dir; recursive=true) # let `obtain_julia` unpack; keeps code simpler here

    versions = read_versions()
    if haskey(versions, string(version))
        @info "Julia $name (version $version) already available"
        rm(temp_file)
    else
        # always use the hash of the downloaded file to force a check during `obtain_julia`
        hash = filehash(temp_file)

        # move to its final location
        name = "julia-$version.$ext"
        file = downloads_dir(name)
        if ispath(file)
            @warn "Destination file $name already exists, assuming it matches"
            rm(temp_file)
        else
            mv(temp_file, file)
        end

        # Update Versions.toml
        version_stanza = """
            ["$version"]
            file = "$name"
            sha = "$hash"
            """
        open(versions_file(); append=true) do f
            println(f, version_stanza)
        end
    end

    return version
end

"""
    version = build_julia(ref::String="master"; binarybuilder_args::Vector{String}=String["--verbose"])

Check-out and build Julia at git reference `ref` using BinaryBuilder.
Returns the `version` (what other functions use to identify this build).
This version will be added to Versions.toml.
"""
function build_julia(ref::String="master"; binarybuilder_args::Vector{String}=String["--verbose"])
    # get the Julia repo
    repo_path = downloads_dir("julia")
    if !isdir(repo_path)
        @info "Cloning Julia repository..."
        repo = LibGit2.clone("https://github.com/JuliaLang/julia", repo_path)
    else
        repo = LibGit2.GitRepo(repo_path)
        LibGit2.fetch(repo)
    end

    # lookup the version number and commit hash
    reference = LibGit2.GitCommit(repo, ref)
    tree = LibGit2.peel(LibGit2.GitTree, reference)
    version = VersionNumber(chomp(LibGit2.content(tree["VERSION"])))
    commit = string(LibGit2.GitHash(reference))
    if version.prerelease != ()
        commit_short = commit[1:10]
        version = VersionNumber(string(version) * string("-", commit_short))
    end

    versions = read_versions()
    if haskey(versions, string(version))
        @info "Julia $ref (version $version) already available"
        return version
    end

    # Collection of sources required to build julia
    sources = [
        "https://github.com/JuliaLang/julia.git" => commit,
    ]

    # Bash recipe for building across all platforms
    script = raw"""
    cd $WORKSPACE/srcdir
    mount -t devpts -o newinstance jrunpts /dev/pts
    mount -o bind /dev/pts/ptmx /dev/ptmx

    cd julia
    cat > Make.user <<EOF
    JULIA_CPU_TARGET=generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)
    EOF
    make -j${nproc}

    make install
    cp LICENSE.md ${prefix}
    contrib/fixup-libgfortran.sh ${prefix}/lib/julia
    contrib/fixup-libstdc++.sh ${prefix}/lib ${prefix}/lib/julia
    """

    # These are the platforms we will build for by default, unless further
    # platforms are passed in on the command line
    platforms = [
        Linux(:x86_64, libc=:glibc)
    ]

    # The products that we will ensure are always built
    products = Product[
        ExecutableProduct("julia", :julia)
    ]

    # Dependencies that must be installed before this package can be built
    dependencies = []

    # Build the tarballs
    product_hashes = cd(joinpath(@__DIR__, "..", "deps")) do
        build_tarballs(binarybuilder_args, "julia", version, sources, script, platforms, products, dependencies, preferred_gcc_version=v"7", skip_audit=true)
    end
    temp_file, hash = product_hashes[platforms[1]]
    name = basename(temp_file)

    # Update Versions.toml
    version_stanza = """
        ["$version"]
        file = "$name"
        sha = "$hash"
        """
    open(versions_file(); append=true) do f
        println(f, version_stanza)
    end

    # Copy the generated tarball to the downloads folder
    file = downloads_dir(name)
    if ispath(file)
        # NOTE: we can't use the previous file here (like in `download_julia`)
        #       because the hash will most certainly be different
        @warn "Destination file $name already exists, overwriting"
    end
    mv(temp_file, file)

    return version
end
