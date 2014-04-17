defmodule ReleaseManager.Relx do
  @moduledoc """
  Utilities and helpers for working with Relx
  """
  import ReleaseManager.Utils, only: [get_elixir_path: 0]

  def default_config(app, version, releases) do
    elixir_path = get_elixir_path() |> Path.join("lib")
    lib_dirs = {:lib_dirs, [
        '#{elixir_path}',
        '../_build/prod'
      ]}
    # Specify the release to build by default (current project version #)
    default_rel = {:default_release, app, '#{version}'}
    # Any older releases are next:
    releases = Enum.map releases, &define_release/2
    # The latest release definition for the current project version
    current_rel = define_release(app, version)
    # ERTS is included by default, but let's be explicit
    include_erts? = {:include_erts, true}

    # TODO: Support providing a sys.config file
    #{:sys_config, "./path/to/sys.config"}.
    # TODO: Support overrides
    # {overrides, [{example_app, "./path/to/example_app"}]}
    # TODO: Support custom vm.args file
    #{:vm_args, "./path/to/vm.args"}.

    # We're providing our own start script (see below)
    start_script_ext? = {:extended_start_script, true}
    start_script?     = {:generate_start_script, false}
    # This copies our custom start script to the release bin directory
    overlays = {:overlay, [
        {:mkdir, 'releases/#{version}'},
        {:copy,  './files/sys.config', 'releases/#{version}/sys.config'},
        {:copy,  './files/runner', 'bin/#{app}'}
      ]}

    # Make a list of all the terms to write to the final config, in order
    terms = 
      [lib_dirs, default_rel] ++
      releases ++
      [current_rel, include_erts?, start_script_ext?, start_script?, overlays]

    # Each term must be formatted as '~p.\n' individually
    format = Stream.repeatedly(fn -> '~p.\n' end) 
    |> Enum.take(Enum.count(terms)) 
    |> Enum.join
    |> String.to_char_list!

    :io_lib.fwrite(format, terms)
  end

  defp define_release(app, version) do
    {:release, { app, '#{version}' }, [
      { app, '#{version}' },
      :elixir,
      :iex,   # needed for iex remote console
      :sasl   # required for upgrades
    ]}
  end
end