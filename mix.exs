defmodule PayDayLoan.Mixfile do
  use Mix.Project

  def project do
    [
      app: :pay_day_loan,
      version: "0.6.1",
      description: description(),
      package: package(),
      elixir: "~> 1.5",
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
        flags: [:error_handling, :race_conditions]
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: [main: "PayDayLoan"],
      deps: deps()
    ]
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
      {:patiently, "~> 0.1.0", only: :test},
      {:ex_doc, "~> 0.16.2", only: :dev},
      {:dialyxir, "~>0.5.1", only: :dev, runtime: false},
      {:excoveralls, "~> 0.7.2", only: :test},
      {:credo, "~> 0.8.6", only: [:dev]}
    ]
  end
end
