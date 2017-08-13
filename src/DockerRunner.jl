import Base: run, show

# The docker image we use
const BUILD_IMAGE = "staticfloat/julia_workerbase:crossbuild-x64"
BUILD_IMAGE_UPDATED = false

function update_build_image(; verbose::Bool = false, force::Bool = false)
    global BUILD_IMAGE_UPDATED
    if !BUILD_IMAGE_UPDATED || force
        info("Updating build image $BUILD_IMAGE, this may take a few minutes...")
        oc = OutputCollector(`docker pull $BUILD_IMAGE`; verbose=verbose)
        did_succeed = wait(oc)
        if !did_succeed
            error("Could not update build image $BUILD_IMAGE")
        end

        BUILD_IMAGE_UPDATED = true
    end
end

type DockerRunner
    cmd_prefix::Cmd
    platform::Symbol
end

function show(io::IO, x::DockerRunner)
    write(io, "$(x.platform) DockerRunner")
end

function getuid()
    return ccall((:getuid, :libc), UInt32, ())
end

function getgid()
    return ccall((:getgid, :libc), UInt32, ())
end

function target_envs(target::String)
    target_tool = tool -> "/opt/$(target)/bin/$(target)-$(tool)"
    mapping = Dict(
        "PATH" => "/opt/$(target)/bin:/usr/local/bin:/usr/bin:/bin",
        "AR" => target_tool("ar"),
        "CC" => target_tool("gcc"),
        "CXX" => target_tool("g++"),
        "FC" => target_tool("gfortran"),
        "LD" => target_tool("ld"),
        "NM" => target_tool("nm"),
        "AS" => target_tool("as"),
        "RANLIB" => target_tool("ranlib"),
        "STRIP" => target_tool("strip"),
        "INSTALL_NAME_TOOL" => target_tool("install_name_tool"),
        "LIBTOOL" => target_tool("libtool"),
        "LIPO" => target_tool("lipo"),
        "OTOOL" => target_tool("otool"),
        "target" => target,
    )

    return mapping
end

const platform_to_target_mapping = Dict(
    :linux64 => "x86_64-linux-gnu",
    :linuxaarch64 => "aarch64-linux-gnu",
    :linuxarmv7l => "arm-linux-gnueabihf",
    :linuxppc64le => "powerpc64le-linux-gnu",
    :mac64 => "x86_64-apple-darwin14",
    :win64 => "x86_64-w64-mingw32",
)

function supported_platforms()
    return keys(platform_to_target_mapping)
end

function platform_map(platform::Symbol)
    return platform_to_target_mapping[platform]
end


"""
`platform_suffix(kernel::Symbol = Sys.KERNEL, arch::Symbol = Sys.ARCH)`

Returns the platform-dependent suffix of a packaging tarball for the current
platform, or any other though the use of the `kernel` and `arch` parameters.
"""
function platform_suffix(kernel::Symbol = Sys.KERNEL, arch::Symbol = Sys.ARCH)
    const kern_dict = Dict(
        :Darwin => "mac",
        :Apple => "mac",
        :Linux => "linux",
        :FreeBSD => "bsd",
        :OpenBSD => "bsd",
        :NetBSD => "bsd",
        :DragonFly => "bsd",
        :Windows => "win",
        :NT => "win",
    )

    const arch_dict = Dict(
        :x86_64 => "64",
        :i686 => "32",
        :powerpc64le => "ppc64le",
        :ppc64le => "ppc64le",
        :arm => "arm",
        :aarch64 => "arm64",
    )    
    return Symbol("$(kern_dict[kernel])$(arch_dict[arch])")
end

function DockerRunner(;prefix::Prefix = global_prefix, platform::Symbol = platform_suffix(), volume_mapping::Vector = [])
    # We are using `docker run` to provide isolation
    cmd_prefix = `docker run --rm -i`

    # The volumes we'll always map into the docker container
    push!(volume_mapping, (prefix.path, prefix.path))
    for v in volume_mapping
        cmd_prefix = `$cmd_prefix -v $(v[1]):$(v[2])`
    end

    # The environment variables we'll set
    env_mapping = target_envs(platform_map(platform))
    for v in env_mapping
        cmd_prefix = `$cmd_prefix -e $(v[1])=$(v[2])`
    end

    # Set our user id and group id to match the outside world
    cmd_prefix = `$cmd_prefix --user=$(getuid()):$(getgid())`

    # Manually set DESTDIR environment variable
    cmd_prefix = `$cmd_prefix -e DESTDIR=$(prefix.path)`

    # Actually update the build image, if we need to
    update_build_image()

    return DockerRunner(cmd_prefix, platform)
end

function run(dr::DockerRunner, cmd::Cmd, logpath::AbstractString; verbose::Bool = false)
    # Create the directory where we'll store logs, if we need to
    mkpath(dirname(logpath))

    # Run the command
    d = pwd()
    user_cmd = `$(dr.cmd_prefix) -w $(d) -v $(d):$(d) $BUILD_IMAGE $cmd`

    oc = OutputCollector(user_cmd; verbose=verbose)
    did_succeed = wait(oc)

    # Write out the logfile, regardless of whether it was successful or not 
    mkpath(dirname(logpath))
    open(logpath, "w") do f
        # First write out the actual command, then the command output
        println(f, cmd)
        print(f, merge(oc))
    end

    # Return whether we succeeded or not
    return did_succeed
end

function runshell(dr::DockerRunner)
    d = pwd()
    user_cmd = `$(dr.cmd_prefix) -w $(d) -v $(d):$(d) -t $BUILD_IMAGE bash`
    run(user_cmd)
end

function runshell(platform::Symbol)
    runshell(DockerRunner(platform=platform))
end
