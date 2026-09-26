defmodule Fp3Modem.MixProject do
  use Mix.Project

  def project do
    [
      app: :fp3_modem,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # The qrtr-transport branches add the QRTR transport the FP3+
      # in-SoC modem needs; upstream qmi/vintage_net_qmi only speak QMUX.
      {:qmi, github: "mlainez/qmi", branch: "qrtr-transport"},
      {:vintage_net, "~> 0.13"},
      {:vintage_net_qmi, github: "mlainez/vintage_net_qmi", branch: "qrtr-transport"}
    ]
  end

  # Tests run on the host: don't start vintage_net and friends.
  defp aliases do
    [test: "test --no-start"]
  end
end
