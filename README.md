# Elixir Release Manager

Thanks to @tylerflint for the original Makefile, rel.config, and runner script which inspired this project!

## Preface 

This is a fork of bitwalker's excellent EXPM package used to prototype rpm support. This branch is functional and provides the following features:

- intelligent defaults to generate an rpm which installs the release, an init script, and chkconfig 
- the rpm handles new installs as well as live upgrades
- mix task to copy the rpm and init script templates for customization
- works for systems without the rpm build tools, generating all the required source files for later rpm build

## TODO

- Add support for clean 
- Move the rpm to the rel directory
- Add support for other architectures
- Add configuration support for other spec file variables like description, summary, url, etc 
- More testing
- Discard once this functionality once it has been added to the official exrm package

## Usage

NOTE: Due to a bug in Elixir's compilation process (fixed in v0.13), the v0.12.x versions of Elixir will require you to add `:kernel`, `:stdlib`, and `:elixir` to your projects application dependencies array in order for releases to work for you. If you encounter issues, please let me know and I will work with you to make sure you are able to use exrm with your project.

You can build a release with the `release` task:

- `mix release`

This task constructs the complete release for you. The output is sent to `rel/<project>`. To see what flags you can pass to this task, use `mix help release`.

One really cool thing you can do is `mix release --dev`. This will symlink your application's code into the release, allowing you to make code changes, recompile with `MIX_ENV=prod mix compile`, and rerun your release with `rel/<project>/bin/<project> console` to see the changes. Being able to rapidly test and tweak your release like this goes a long way to making the release process less tedious!

- `mix release.clean [--implode]`

Without args, this will clean up the release corresponding to the
current project version.

With `--implode`, all releases, configuration, generated tools, etc.,
will be cleaned up, leaving your project directory the same as if exrm
had never been run. This is a destructive operation, as you can't get
your releases back unless they were source-controlled, so exrm will ask
you for confirmation before proceeding with the cleanup.

- `mix release --rpm` 

This option generates the release and build an RPM using the default spec and init script templates. The generated files can be found in:

- _build/rpm/SPECS/name.spec      # the generated spec file used to build the rpm
- _build/rpm/SOURCES/name         # the generated init script included in the rpm
- _build/rpm/RPMS/x86_64/name-version-x86_64.rpm  # the generated rpm

Used the following mix task to customize the rpm

- `mix release.copy_rpm_templates`

This task creates a copy of the spec and init script templates:

- rpm/templates/spec
- rpm/templates/init_script

You can customize this files. They will be used instead of the defaults on subsequent rpm builds.

## Getting Started

This project's goal is to make releases with Elixir projects a breeze. It is composed of a mix task, and all build files required to successfully take your Elixir project and perform a release build. All you have to do to get started is the following:

#### Add exrm as a dependency to your project

```elixir
  defp deps do
    [{:exrm, "~> 0.5.0"}]
  end
```

#### Fetch and Compile

- `mix deps.get`
- `mix deps.compile`

#### Perform a release

- `mix release`

#### Run your app! (my example is based on a simple ping server, see the appendix for more info)

```
> rel/test/bin/test console
Erlang/OTP 17 [RELEASE CANDIDATE 1] [erts-6.0] [source-fdcdaca] [64-bit] [smp:4:4] [async-threads:10] [hipe] [kernel-poll:false]

Interactive Elixir (0.12.5) - press Ctrl+C to exit (type h() ENTER for help)
iex(1)> :gen_server.call(:test, :ping)
:v1
iex(2)>
```

See the next few sections for information on how to deploy, run, upgrade/downgrade, and remotely connect to your release!

## Deployment

Now that you've generated your first release, it's time to deploy it! Let's walk through a simulated deployment to the `/tmp` directory on your machine, using the example app from the Appendix.

1. `mix release`
2. `mkdir -p /tmp/test`
3. `cp rel/test/test-0.0.1.tar.gz /tmp/`
4. `cd /tmp/test`
5. `tar -xf /tmp/test-0.0.1.tar.gz`

Now to start your app:

`bin/test start`

You can test if your app is alive and running with `bin/test ping`. 

If you want to connect a remote shell to your now running app:

`bin/test remote_console`

Ok, you should be staring at a standard `iex` prompt, but slightly different: `iex(test@localhost)1>`. The prompt shows us that we are currently connected to `test@localhost`, which is the value of `name` in our `vm.args` file. Feel free to ping the app using `:gen_server.call(:test, :ping)` to make sure it works.

At this point, you can't just abort from the prompt like usual and make the node shut down. This would be an obviously bad thing in a production environment. Instead, you can issue `:init.stop` from the `iex` prompt, and this will shut down the node. You will still be connected to the shell, but once you quit the shell, the node is gone.

## Upgrading Releases

So you've made some changes to your app, and you want to generate a new relase and perform a no-downtime upgrade. I'm here to tell you that this is going to be a breeze, so I hope you're ready (I'm using my test app as an example here again):

1. `mix release`
2. `mkdir -p /tmp/test/releases/0.0.2`
3. `cp rel/test/test-0.0.2.tar.gz /tmp/test/releases/0.0.2/test.tar.gz`
4. `cd /tmp/test`
5. `bin/test upgrade "0.0.2"`

Annnnd we're done. Your app was upgraded in place with no downtime, and is now running your modified code. You can use `bin/test remote_console` to connect and test to be sure your changes worked as expected.

You can also provide your own .appup file, by writing one and placing it in
`rel/<app>.appup`. This location is checked before generating a new
release, and will be used instead of autogenerating an appup file for
you.

## Downgrading Releases

This is even easier! Using the example from before:

1. `cd /tmp/test`
2. `bin/test downgrade "0.0.1"`

All done!

## Common Issues

I'm starting this list to begin collating the various caveats around
building releases. As soon as I feel like I have a firm grasp of all the
edge cases, I'll formalize this in a better format perhaps as a
"Preparing for Release" document.

- Ensure all dependencies for your application are defined in the
  `:applications` block of your `mix.exs` file. This is how the build
  process knows that those dependencies need to be bundled in to the
  release. **This includes dependencies of your dependencies, if they were
  not properly configured**. For instance, if you depend on `mongoex`, and
  `mongoex` depends on `erlang-mongodb`, but `mongoex` doesn't have `erlang-mongodb`
  in it's applications section, your app will fail in it's release form,
  because `erlang-mongodb` won't be loaded.
- If you are running into issues with your dependencies missing their
  dependencies, it's likely that the author did not put the dependencies in
  the `:application` block of *their* `mix.exs`. You may have to fork, or
  issue a pull request in order to resolve this issue. Alternatively, if
  you know what the dependency is, you can put it in your own `mix.exs`, and
  the release process will ensure that it is loaded with everything else.

If you run into problems, this is still early in the project's development, so please create an issue, and I'll address ASAP.

## Appendix

The example server I setup was as simple as this:

1. `mix new test`
2. `cd test && touch lib/test/server.ex`

Then put the following in `lib/test/server.ex`

```elixir
defmodule Test.Server do
  use GenServer.Behaviour

  def start_link() do
    :gen_server.start_link({:local, :test}, __MODULE__, [], [])
  end

  def init([]) do
    { :ok, [] }
  end
  
  def handle_call(:ping, _from, state) do
    { :reply, :pong, state }
  end

end
```

You can find the source code for my example application [here](https://github.com/bitwalker/exrm-test). You should be able to replicate my example using these steps. If you can't, please let me know.
