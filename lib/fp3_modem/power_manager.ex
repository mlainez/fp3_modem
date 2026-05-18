# SPDX-FileCopyrightText: 2026 Marc Lainez
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Fp3Modem.PowerManager do
  @moduledoc """
  `VintageNet.PowerManager` implementation for the Fairphone 3+ in-SoC
  modem (msm8953, MPSS firmware, IPA data path).

  ## Why this exists

  On a cold boot the FP3+ modem firmware does **not** auto-enter the
  online operating mode. `QMI_DMS_GET_OPERATING_MODE` returns
  `:shutting_down`, which keeps the modem in a low-power state where:

    * `UIM_READ_TRANSPARENT` fails with `:internal` (EF_ICCID unreadable),
    * the modem never registers on the cellular network,
    * `WDS_START_NETWORK_INTERFACE` is rejected because the radio is off.

  ModemManager works around this in its enable step by always issuing
  `QMI_DMS_SET_OPERATING_MODE = ONLINE` regardless of the previous
  reading. We do the same here, in the standard VintageNet
  `power_on/1` callback so the modem lifecycle hooks into VintageNet's
  watchdog and reset machinery.

  ## Wiring it up

  Add to `config.exs`:

      config :vintage_net,
        power_managers: [
          {Fp3Modem.PowerManager,
           [ifname: "rmnet0", watchdog_timeout: 120_000]}
        ]

  ## Lifecycle

    * `power_on/1` — wait for QMI to be ready, then set operating mode
      to `:online`. Returned `hold_time` is 10 min so VintageNet's
      watchdog gives the modem and carrier registration enough room.
    * `start_powering_off/1` — issue `:persistent_low_power` so the
      modem detaches gracefully from the tower before we cut state.
      VintageNet then waits `time_to_power_off` (5 s) before calling
      `power_off/1`.
    * `power_off/1` — best-effort `:offline` (idempotent if already
      down). Returns a minimum-off window so we don't ping-pong.
  """

  @behaviour VintageNet.PowerManager

  require Logger

  # Generous hold so a cellular attach has time to complete.
  @power_on_hold_time 600_000

  # Time for the modem to detach gracefully from the carrier.
  @time_to_power_off 5_000

  # Minimum time the modem stays off before we'll power it on again.
  @min_power_off_time 2_000

  # How long power_on/1 will wait for the QMI driver to appear before
  # giving up on this attempt. VintageNet will retry via its watchdog.
  @qmi_ready_timeout_ms 30_000
  @qmi_poll_interval_ms 500

  @impl VintageNet.PowerManager
  def init(args) do
    ifname = Keyword.fetch!(args, :ifname)
    {:ok, %{ifname: ifname}}
  end

  @impl VintageNet.PowerManager
  def power_on(%{ifname: ifname} = state) do
    Logger.info("[Fp3Modem.PowerManager] power_on for #{ifname}")
    # QMI driver may not be up yet at boot. Do the work asynchronously
    # so we don't block the PowerManager GenServer.
    _ = Task.start(fn -> set_online_when_ready(ifname) end)
    {:ok, state, @power_on_hold_time}
  end

  @impl VintageNet.PowerManager
  def start_powering_off(%{ifname: ifname} = state) do
    Logger.info("[Fp3Modem.PowerManager] start_powering_off for #{ifname}")

    _ =
      Task.start(fn ->
        qmi = VintageNetQMI.qmi_name(ifname)

        case QMI.DeviceManagement.set_operating_mode(qmi, :persistent_low_power) do
          :ok ->
            :ok

          err ->
            Logger.warning(
              "[Fp3Modem.PowerManager] set_operating_mode(:persistent_low_power) → #{inspect(err)}"
            )
        end
      end)

    {:ok, state, @time_to_power_off}
  end

  @impl VintageNet.PowerManager
  def power_off(%{ifname: ifname} = state) do
    Logger.info("[Fp3Modem.PowerManager] power_off for #{ifname}")

    _ =
      Task.start(fn ->
        qmi = VintageNetQMI.qmi_name(ifname)
        _ = QMI.DeviceManagement.set_operating_mode(qmi, :offline)
      end)

    {:ok, state, @min_power_off_time}
  end

  @impl VintageNet.PowerManager
  def handle_info(_msg, state), do: {:noreply, state}

  defp set_online_when_ready(ifname) do
    qmi = VintageNetQMI.qmi_name(ifname)

    case wait_for_qmi(qmi, @qmi_ready_timeout_ms) do
      :ok ->
        case QMI.DeviceManagement.set_operating_mode(qmi, :online) do
          :ok ->
            Logger.info("[Fp3Modem.PowerManager] set_operating_mode(:online) → ok")

          err ->
            Logger.warning(
              "[Fp3Modem.PowerManager] set_operating_mode(:online) → #{inspect(err)}"
            )
        end

      :timeout ->
        Logger.warning(
          "[Fp3Modem.PowerManager] QMI driver for #{ifname} not ready after " <>
            "#{@qmi_ready_timeout_ms}ms; VintageNet watchdog will retry"
        )
    end
  end

  defp wait_for_qmi(_qmi, remaining) when remaining <= 0, do: :timeout

  defp wait_for_qmi(qmi, remaining) do
    case Process.whereis(qmi) do
      nil ->
        Process.sleep(@qmi_poll_interval_ms)
        wait_for_qmi(qmi, remaining - @qmi_poll_interval_ms)

      _pid ->
        :ok
    end
  end
end
