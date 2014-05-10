defmodule Mix.Tasks.Release do
  @moduledoc """
  Build a release for the current mix application.

  ## Examples

    # Build a release using defaults
    mix release
    # Pass args to erlexec when running the release
    mix release --erl="-env TZ UTC"
    # Enable dev mode. Make changes, compile using MIX_ENV=prod
    # and execute your release again to pick up the changes
    mix release --dev
    # Set the verbosity level
    mix release --verbosity=[silent|quiet|normal|verbose]

  You may pass any number of arguments as needed. Make sure you pass arguments
  using `--key=value`, not `--key value`, as the args may be interpreted incorrectly
  otherwise.

  """
  @shortdoc "Build a release for the current mix application."

  use    Mix.Task
  import ReleaseManager.Utils

  @_RELXCONF    "relx.config"
  @_RUNNER      "runner"
  @_SYSCONFIG   "sys.config"
  @_RELEASE_DEF "release_definition.txt"
  @_SPEC        "spec"
  @_INIT_FILE   "init_script"
  @_RELEASES    "{{{RELEASES}}}"
  @_NAME        "{{{PROJECT_NAME}}}"
  @_VERSION     "{{{PROJECT_VERSION}}}"
  @_ERTS_VSN    "{{{ERTS_VERSION}}}"
  @_ERL_OPTS    "{{{ERL_OPTS}}}"
  @_ELIXIR_PATH "{{{ELIXIR_PATH}}}"

  def run(args) do
    # Ensure this isn't an umbrella project
    if Mix.Project.umbrella? do
      raise Mix.Error, message: "Umbrella projects are not currently supported!"
    end
    # Start with a clean slate
    Mix.Tasks.Release.Clean.do_cleanup(:build)
    # Collect release configuration
    config = [ priv_path:  Path.join([__DIR__, "..", "..", "..", "priv"]) |> Path.expand,
               name:       Mix.project |> Keyword.get(:app) |> atom_to_binary,
               version:    Mix.project |> Keyword.get(:version),
               dev:        false,
               erl:        "",
               upgrade?:   false,
               verbosity:  :quiet,
               build_dir:  Path.join(["/", "tmp", "build"]),
               init_dir:   Path.join(["etc", "init.d"]),
               rpmbuild:   "/usr/bin/rpmbuild",
               rpmbuild_opts: "-bb",
               rpm:        false]
    config
    |> Keyword.merge(args |> parse_args)
    |> prepare_relx
    |> build_project
    |> generate_relx_config
    |> generate_runner
    |> do_release
    |> do_rpm
    |> do_init_script
    |> create_rpm

    info "Your release is ready!"
  end

  defp prepare_relx(config) do
    # Ensure relx has been downloaded
    verbosity = config |> Keyword.get(:verbosity)
    priv = config |> Keyword.get(:priv_path)
    relx = Path.join([priv, "bin", "relx"])
    dest = Path.join(File.cwd!, "relx")
    case File.copy(relx, dest) do
      {:ok, _} ->
        dest |> chmod("+x")
        # Continue...
        config
      {:error, reason} ->
        if verbosity == :verbose do
          error reason
        end
        error "Unable to copy relx to your project's directory!"
        exit(:normal)
    end
  end

  defp build_project(config) do
    # Fetch deps, and compile, using the prepared Elixir binaries
    verbosity = config |> Keyword.get(:verbosity)
    cond do
      verbosity == :verbose ->
        mix "deps.get",     :prod, :verbose
        mix "deps.compile", :prod, :verbose
        mix "compile",      :prod, :verbose
      true ->
        mix "deps.get",     :prod
        mix "deps.compile", :prod
        mix "compile",      :prod
    end
    # Continue...
    config
  end

  defp generate_relx_config(config) do
    # Get configuration
    priv     = config |> Keyword.get(:priv_path)
    name     = config |> Keyword.get(:name)
    version  = config |> Keyword.get(:version)
    # Get paths
    deffile  = Path.join([priv, "rel", "files", @_RELEASE_DEF])
    source   = Path.join([priv, "rel", @_RELXCONF])
    base     = Path.join(File.cwd!, "rel")
    dest     = Path.join(base, @_RELXCONF)
    # Get relx.config template contents
    relx_config = source |> File.read!
    # Get release definition template contents
    tmpl = deffile |> File.read!
    # Generate release configuration for historical releases
    releases = get_releases(name)
      |> Enum.map(fn {rname, rver} -> tmpl |> replace_release_info(rname, rver) end)
      |> Enum.join
    # Set upgrade flag if this is an upgrade release
    config = case releases do
      "" -> config
      _  -> config |> Keyword.merge [upgrade?: true]
    end
    # Write release configuration
    relx_config = relx_config
      |> String.replace(@_RELEASES, releases)
      |> String.replace(@_ELIXIR_PATH, get_elixir_path() |> Path.join("lib"))
    # Replace placeholders for current release
    relx_config = relx_config |> replace_release_info(name, version)
    # Ensure destination base path exists
    File.mkdir_p!(base)
    # Write relx.config
    File.write!(dest, relx_config)
    # Return the project config after we're done
    config
  end

  defp generate_runner(config) do
    priv      = config |> Keyword.get(:priv_path)
    name      = config |> Keyword.get(:name)
    version   = config |> Keyword.get(:version)
    erts      = :erlang.system_info(:version) |> iolist_to_binary
    erl_opts  = config |> Keyword.get(:erl)
    runner    = Path.join([priv, "rel", "files", @_RUNNER])
    sysconfig = Path.join([priv, "rel", "files", @_SYSCONFIG])
    base      = Path.join([File.cwd!, "rel", "files"])
    dest      = Path.join(base, @_RUNNER)
    # Ensure destination base path exists
    File.mkdir_p!(base)
    debug "Generating boot script..."
    contents = File.read!(runner)
      |> String.replace(@_NAME, name)
      |> String.replace(@_VERSION, version)
      |> String.replace(@_ERTS_VSN, erts)
      |> String.replace(@_ERL_OPTS, erl_opts)
    File.write!(dest, contents)
    # Copy default sys.config only if user hasn't provided their own
    case Path.join(base, @_SYSCONFIG) |> File.exists? do
      true -> :ok
      _    -> File.cp!(sysconfig, Path.join(base, @_SYSCONFIG))
    end
    # Make executable
    dest |> chmod("+x")
    # Return the project config after we're done
    config
  end

  defp do_rpm(config) do
    rpm?        = config |> Keyword.get(:rpm)
    if rpm? do
      IO.puts "Generating rpm..." 
      priv      = config |> Keyword.get(:priv_path)
      name      = config |> Keyword.get(:name)
      version   = config |> Keyword.get(:version)
      build_dir = config |> Keyword.get(:build_dir)
      init_dir  = config |> Keyword.get(:init_dir)

      dest          = Path.join([build_dir, "SPECS", "#{name}.spec"])
      spec          = Path.join([priv, "rel", "files", @_SPEC])
      app_name      = "#{name}-#{version}.tar.gz"
      app_tar_path  = Path.join([File.cwd!, "rel", name, app_name])
      sources_path  = Path.join([build_dir, "SOURCES", app_name])

      build_tmp_build(build_dir, init_dir)

      contents = File.read!(spec)
        |> String.replace(@_NAME, name)
        |> String.replace(@_VERSION, version)
      File.write!(dest, contents)

      File.cp!(app_tar_path, sources_path)
    end
    config
  end

  defp do_init_script(config) do
    rpm?        = config |> Keyword.get(:rpm)
    if rpm? do
      IO.puts "Generating init.d script..." 
      priv      = config |> Keyword.get(:priv_path)
      name      = config |> Keyword.get(:name)
      version   = config |> Keyword.get(:version)
      build_dir = config |> Keyword.get(:build_dir)
      init_dir  = config |> Keyword.get(:init_dir)

      sources_dest = Path.join([build_dir, "SOURCES", "#{name}-#{version}-other.tar.gz"])
      dest = Path.join([build_dir, "TMP", init_dir, "#{name}"])
      init_file = Path.join([priv, "rel", "files", @_INIT_FILE])
      tar_root = Path.join(build_dir, "TMP")

      contents = File.read!(init_file)
        |> String.replace(@_NAME, name)
      File.write!(dest, contents)

      # TODO: replace this with something erlang or elixir
      System.cmd "tar czf #{sources_dest} -C #{tar_root} ."
    end
    config
  end

  defp create_rpm(config) do
    rpm?        = config |> Keyword.get(:rpm)
    if rpm? do
      IO.puts "Building rpm..." 
      name          = config |> Keyword.get(:name)
      #version       = config |> Keyword.get(:version)
      rpmbuild      = config |> Keyword.get(:rpmbuild)
      rpmbuild_opts = config |> Keyword.get(:rpmbuild_opts)
      build_dir     = config |> Keyword.get(:build_dir)
      spec_path     = Path.join([build_dir, "SPECS", "#{name}.spec"])

      unless File.exists?(rpmbuild) do
        IO.puts """
        Cannot find rpmbuild tool #{rpmbuild}. Skipping rpm build!
        The generated build files can be found in #{build_dir} 
        """
      else
        System.cmd "#{rpmbuild} #{rpmbuild_opts} #{spec_path}"
      end 
    end
    config
  end


  defp do_release(config) do
    debug "Generating release..."
    name      = config |> Keyword.get(:name)
    version   = config |> Keyword.get(:version)
    verbosity = config |> Keyword.get(:verbosity)
    upgrade?  = config |> Keyword.get(:upgrade?)
    dev_mode? = config |> Keyword.get(:dev)
    # If this is an upgrade release, generate an appup
    if upgrade? do
      # Change mix env for appup generation
      with_env :prod do
        # Generate appup
        app      = name |> binary_to_atom
        v1       = get_last_release(name)
        v1_path  = Path.join([File.cwd!, "rel", name, "lib", "#{name}-#{v1}"])
        v2_path  = Mix.Project.config |> Mix.Project.compile_path |> String.replace("/ebin", "")
        own_path = Path.join([File.cwd!, "rel", "#{name}.appup"])
        # Look for user's own .appup file before generating one
        case own_path |> File.exists? do
          true ->
            # Copy it to ebin
            case File.cp(own_path, Path.join([v2_path, "/ebin", "#{name}.appup"])) do
              :ok ->
                info "Using custom .appup located in rel/#{name}.appup"
              {:error, reason} ->
                error "Unable to copy custom .appup file: #{reason}"
                exit(:normal)
            end
          _ ->
            # No custom .appup found, proceed with autogeneration
            case ReleaseManager.Appups.make(app, v1, version, v1_path, v2_path) do
              {:ok, _}         ->
                info "Generated .appup for #{name} #{v1} -> #{version}"
              {:error, reason} ->
                error "Appup generation failed with #{reason}"
                exit(:normal)
            end
        end
      end
    end
    # Do release
    case relx name, version, verbosity, upgrade?, dev_mode? do
      :ok ->
        # Clean up template files
        Mix.Tasks.Release.Clean.do_cleanup(:relfiles)
        # Continue..
        config
      {:error, message} ->
        error message
        exit(:normal)
    end
  end

  defp parse_args(argv) do
    {args, _, _} = OptionParser.parse(argv)
    args |> Enum.map(&parse_arg/1)
  end
  defp parse_arg({:verbosity, verbosity}), do: {:verbosity, binary_to_atom(verbosity)}
  defp parse_arg({_key, _value} = arg),    do: arg

  defp replace_release_info(template, name, version) do
    template
    |> String.replace(@_NAME, name)
    |> String.replace(@_VERSION, version)
  end

  defp build_tmp_build(build_dir, init_dir) do
    File.mkdir_p! Path.join([build_dir,"SPECS"])
    File.mkdir_p! Path.join([build_dir,"SOURCES"])
    File.mkdir_p! Path.join([build_dir,"RPMS"])
    File.mkdir_p! Path.join([build_dir,"SRPMS"])
    File.mkdir_p! Path.join([build_dir,"BUILD"])
    File.mkdir_p! Path.join([build_dir,"TMP", init_dir])
  end

end
