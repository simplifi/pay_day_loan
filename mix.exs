defmodule PayDayLoan.Mixfile do
  use Mix.Project

  def project do
    [
      app: :pay_day_loan,
      version: version(),
      description: description(),
      package: package(),
      elixir: "~> 1.12",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      dialyzer: [
        plt_add_apps: [],
        ignore_warnings: ".dialyzer_ignore",
        flags: [:error_handling]
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: [main: "PayDayLoan"],
      deps: deps()
    ]
  end

  # Auto version stamp, a la CoMix.
  defp version do
    case :file.consult("hex_metadata.config") do
      # Use version from hex_metadata when we're a package
      {:ok, data} ->
        {"version", version} = List.keyfind(data, "version", 0)
        version

      # Otherwise, use git version
      _ ->
        case System.cmd("git", ["describe", "--tags"]) do
          {"v" <> version, 0} ->
            String.trim(version)

          {tag_or_err, code} ->
            Mix.raise("Failed to get version from `git describe --tags`. Code #{code}: #{inspect(tag_or_err)}")
        end
    end
  end

  def application do
    [applications: [:logger]]
  end

  defp description do
    """
    Framework for building on-demand caching.  Fast cache now!
    """
  end

  defp package do
    [
      files: ["lib", "LICENSE.txt", "mix.exs", "mix.lock", "README.md"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/simplifi/pay_day_loan"},
      maintainers: ["Simpli.fi Development Team"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:patiently, "~> 0.2", only: :test},
      {:ex_doc, "~> 0.28", only: :dev},
      {:dialyxir, "~> 1.2", only: :dev, runtime: false},
      {:excoveralls, "~> 0.14", only: :test},
      {:credo, "~> 1.6", only: [:dev]}
    ]
  end
end
