defmodule Fp3Modem.MixProject do
  use Mix.Project

  def project do
    [
      app: :fp3_modem,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:qmi, github: "mlainez/qmi"},
      {:vintage_net, "~> 0.13"},
      {:vintage_net_qmi, github: "mlainez/vintage_net_qmi"}
    ]
  end
end
