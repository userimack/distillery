defmodule Mix.Tasks.Release do
  @moduledoc """
  Build a release for the current mix application.

  ## Examples

      # Build a release using defaults
      mix release

      # Build an upgrade release
      mix release --upgrade

      # Build an upgrade release from a specific version
      mix release --upgrade --upfrom=0.1.0

      # Build a specific release
      mix release --name=myapp

      # Build a release for a specific environment
      mix release --env=staging

      # Build a specific profile
      mix release --profile=myapp:staging

      # Pass args to erlexec when running the release
      mix release --erl="-env TZ UTC"

      # Enable dev mode. Make changes, compile using MIX_ENV=prod
      # and execute your release again to pick up the changes
      mix release --dev

      # Mute logging output
      mix release --silent

      # Quiet logging output
      mix release --quiet

      # Verbose logging output
      mix release --verbose

      # Do not package release, just assemble it
      mix release --no-tar

  """
  @shortdoc "Build a release for the current mix application"
  use Mix.Task
  alias Mix.Releases.{Release, Logger}

  def run(args) do
    # Parse options
    opts = parse_args(args)
    verbosity = Keyword.get(opts, :verbosity)
    Logger.configure(verbosity)

    # make sure loadpaths are updated
    Mix.Task.run("loadpaths", [])

    # load release configuration
    Logger.debug "Loading configuration.."
    config_path = Path.join([File.cwd!, "rel", "config.exs"])
    config = case File.exists?(config_path) do
               true ->
                 try do
                   Mix.Releases.Config.read!(config_path)
                 rescue
                   e in [Mix.Releases.Config.LoadError]->
                     file = e.file
                     message = e.error.message
                     Logger.error "Failed to load config (#{file})\n" <>
                       "    #{message}"
                     exit({:shutdown, 1})
                 end
               false ->
                 Logger.error "You are missing a release config file. Run the release.init task first"
                 exit({:shutdown, 1})
             end

    # Apply override options
    config = case Keyword.get(opts, :dev_mode) do
               nil -> config
               m   -> %{config | :dev_mode => m}
             end
    config = case Keyword.get(opts, :erl_opts) do
               nil -> config
               o   -> %{config | :erl_opts => o}
             end
    config = %{config |
               :is_upgrade => Keyword.fetch!(opts, :is_upgrade),
               :upgrade_from => Keyword.fetch!(opts, :upgrade_from),
               :selected_environment => Keyword.fetch!(opts, :selected_environment),
               :selected_release => Keyword.fetch!(opts, :selected_release)}
    no_tar? = Keyword.get(opts, :no_tar)

    # build release
    Logger.info "Assembling release.."
    case {Mix.Releases.Assembler.assemble(config), no_tar?} do
      {{:ok, %Release{:name => name}}, true} ->
        print_success(name)
      {{:ok, %Release{:name => name} = release}, false} ->
        Logger.info "Packaging release.."
        case Mix.Releases.Archiver.archive(release) do
          :ok ->
            print_success(name)
          other ->
            Logger.error "Problem generating release tarball:\n    " <>
              "#{inspect other}"
            exit({:shutdown, 1})
        end
      {{:error, reason},_} when is_binary(reason) ->
        Logger.error "Failed to build release:\n    " <>
          reason
        exit({:shutdown, 1})
      {{:error, reason},_} ->
        Logger.error "Failed to build release:\n    " <>
          "#{inspect reason}"
        exit({:shutdown, 1})
    end
  end

  defp print_success(app) do
    Logger.success "Release successfully built!\n    " <>
      "You can run it in one of the following ways:\n      " <>
      "Interactive: rel/#{app}/bin/#{app} console\n      " <>
      "Foreground: rel/#{app}/bin/#{app} foreground\n      " <>
      "Daemon: rel/#{app}/bin/#{app} start"
  end

  defp parse_args(argv) do
    switches = [silent: :boolean, quiet: :boolean, verbose: :boolean,
                dev: :boolean, erl: :string, no_tar: :boolean,
                upgrade: :boolean, upfrom: :string, name: :string,
                env: :string]
    {overrides, _} = OptionParser.parse!(argv, switches)
    verbosity = :normal
    verbosity = cond do
      Keyword.get(overrides, :verbose, false) -> :verbose
      Keyword.get(overrides, :quiet, false)   -> :quiet
      Keyword.get(overrides, :silent, false)  -> :silent
      :else -> verbosity
    end
    {rel, env} = case Keyword.get(overrides, :profile) do
      nil ->
        rel = Keyword.get(overrides, :name, :default)
        env = Keyword.get(overrides, :env, :default)
        {rel, env}
      profile ->
        case String.split(profile, ":", trim: true, parts: 2) do
          [rel, env] -> {rel, env}
          other ->
            Logger.error "invalid profile name `#{other}`, must be `name:env`"
            exit({:shutdown, 1})
        end
    end
    [verbosity: verbosity,
     selected_release: rel,
     selected_environment: env,
     dev_mode: Keyword.get(overrides, :dev),
     erl_opts: Keyword.get(overrides, :erl),
     no_tar:   Keyword.get(overrides, :no_tar, false),
     is_upgrade:   Keyword.get(overrides, :upgrade, false),
     upgrade_from: Keyword.get(overrides, :upfrom, :latest)]
  end
end
