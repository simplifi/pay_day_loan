defmodule PayDayLoan.Mixfile do
  use Mix.Project

  def project do
    [app: :pay_day_loan,
     version: "0.2.0",
     description: description,
     package: package,
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     test_coverage: [tool: Coverex.Task],
     elixirc_paths: elixirc_paths(Mix.env),
     docs: [main: "PayDayLoan"],
     deps: deps]
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
      {:ex_doc, "~> 0.7", only: :dev},
      {:dialyze, "~>0.2", only: :dev},
      {:coverex, "~> 1.4.9", only: :test},
      {:credo, "~> 0.6.1", only: [:dev]}
    ]
  end
end
