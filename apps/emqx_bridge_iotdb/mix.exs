defmodule EMQXBridgeIotdb.MixProject do
  use Mix.Project
  alias EMQXUmbrella.MixProject, as: UMP

  def project do
    [
      app: :emqx_bridge_iotdb,
      version: "6.0.0",
      build_path: "../../_build",
      erlc_options: UMP.erlc_options(),
      erlc_paths: UMP.erlc_paths(),
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: UMP.extra_applications(),
      env: [
        emqx_action_info_modules: [:emqx_bridge_iotdb_action_info],
        emqx_connector_info_modules: [:emqx_bridge_iotdb_connector_info]
      ]
    ]
  end

  def deps() do
    [
      {:iotdb, github: "emqx/iotdb-client-erl", tag: "0.2.1"},
      {:emqx_connector, in_umbrella: true, runtime: false},
      {:emqx_resource, in_umbrella: true},
      {:emqx_bridge, in_umbrella: true, runtime: false},
      {:emqx_bridge_http, in_umbrella: true, runtime: false}
    ]
  end
end
