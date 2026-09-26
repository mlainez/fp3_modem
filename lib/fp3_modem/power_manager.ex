# SPDX-FileCopyrightText: 2026 Marc Lainez
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Fp3Modem.PowerManager do
  @moduledoc """
  `VintageNet.PowerManager` implementation for the Fairphone 3+ in-SoC
  modem (msm8953, MPSS firmware, IPA data path), talking QMI over QRTR.

  ## Why this exists

  On a cold boot the FP3+ modem firmware does **not** enter the online
  operating mode by itself. `QMI_DMS_GET_OPERATING_MODE` returns
  `:shutting_down`, which keeps the modem in a low-power state where:

    * `UIM_READ_TRANSPARENT` fails with `:internal` (EF_ICCID unreadable),
    * the modem never registers on the cellular network,
    * `WDS_START_NETWORK_INTERFACE` is rejected because the radio is off.

  ModemManager works around this in its enable step by always issuing
  `QMI_DMS_SET_OPERATING_MODE = ONLINE`. This module does the same from
  the VintageNet `power_on/1` callback, so the modem lifecycle hooks into
  VintageNet's watchdog and reset machinery.

  ## Configuration

  Requires the `qrtr-transport` branches of the
  [`qmi`](https://github.com/mlainez/qmi) and
  [`vintage_net_qmi`](https://github.com/mlainez/vintage_net_qmi) forks.
  Known-good configuration from a working FP3+ firmware (replace the
  APN):

      config :vintage_net,
        power_managers: [
          {Fp3Modem.PowerManager, [ifname: "rmnet0", watchdog_timeout: 120_000]}
        ],
        config: [
          {"rmnet0",
           %{
             type: VintageNetQMI,
             vintage_net_qmi: %{
               service_providers: [%{apn: "your.apn"}],
               provision_uim: true,
               ip_method: :qmi_profile,
               rmnet_child: %{parent: "rmnet_ipa0", mux_id: 1}
             }
           }}
        ]

  Init arguments:

    * `:ifname` (required) — the VintageNetQMI interface name, a non-empty
      string (`"rmnet0"` above). Used to find the QMI instance that
      VintageNetQMI starts (`VintageNetQMI.qmi_name/1`).
    * `:watchdog_timeout` (optional) — read by VintageNet itself, not by
      this module.
    * `:retry_min_ms` / `:retry_max_ms` (optional, defaults `500` /
      `10_000`) — backoff between attempts to put the modem online.

  Invalid arguments raise `ArgumentError` from `init/1`; VintageNet logs
  it and disables this power manager.

  ## Lifecycle

    * `power_on/1` returns immediately with a 10 min hold time and starts
      a background task that sends `set_operating_mode(:online)`. Until
      that succeeds it retries with exponential backoff (`:retry_min_ms`
      doubling up to `:retry_max_ms`), for at most the 10 min hold time.
      Before the modem announces its DMS service over QRTR, the qmi
      driver answers `{:error, {:service_not_found, 2}}`; that, other
      `{:error, _}` results and exits are logged and retried, never
      raised.
    * `start_powering_off/1` stops that task, sends a best-effort
      `set_operating_mode(:persistent_low_power)` in the background (so
      the modem can detach from the network), and asks VintageNet to
      wait 5 s before `power_off/1`.
    * `power_off/1` stops the task, sends a best-effort
      `set_operating_mode(:offline)` in the background, and keeps the
      modem off for at least 2 s.
    * `handle_info/2` ignores all messages.

  No callback raises or blocks on QMI.
  """

  @behaviour VintageNet.PowerManager

  require Logger

  # Generous hold so a cellular attach has time to complete. Also the
  # longest the power-on task keeps retrying.
  @power_on_hold_time 600_000

  # Time for the modem to detach gracefully from the carrier.
  @time_to_power_off 5_000

  # Minimum time the modem stays off before we'll power it on again.
  @min_power_off_time 2_000

  # QMI Device Management Service id.

  @impl VintageNet.PowerManager
  def init(args) do
    ifname = Keyword.get(args, :ifname)

    unless is_binary(ifname) and ifname != "" do
      raise ArgumentError, "Fp3Modem.PowerManager: :ifname must be a non-empty string"
    end

    retry_min = positive_int!(args, :retry_min_ms, 500)
    retry_max = positive_int!(args, :retry_max_ms, 10_000)

    if retry_max < retry_min do
      raise ArgumentError, "Fp3Modem.PowerManager: :retry_max_ms must be >= :retry_min_ms"
    end

    {:ok,
     %{
       ifname: ifname,
       qmi: VintageNetQMI.qmi_name(ifname),
       retry_min_ms: retry_min,
       retry_max_ms: retry_max,
       online_task: nil
     }}
  end

  defp positive_int!(args, key, default) do
    case Keyword.get(args, key, default) do
      v when is_integer(v) and v > 0 ->
        v

      other ->
        raise ArgumentError,
              "Fp3Modem.PowerManager: #{inspect(key)} must be a positive integer, got #{inspect(other)}"
    end
  end

  @impl VintageNet.PowerManager
  def power_on(state) do
    Logger.info("[Fp3Modem.PowerManager] power_on for #{state.ifname}")
    state = stop_online_task(state)
    deadline = System.monotonic_time(:millisecond) + @power_on_hold_time
    {:ok, pid} = Task.start(fn -> online_loop(state, 0, deadline) end)
    {:ok, %{state | online_task: pid}, @power_on_hold_time}
  end

  @impl VintageNet.PowerManager
  def start_powering_off(state) do
    Logger.info("[Fp3Modem.PowerManager] start_powering_off for #{state.ifname}")
    state = stop_online_task(state)
    {:ok, _} = Task.start(fn -> set_mode_if_ready(state.qmi, :persistent_low_power) end)
    {:ok, state, @time_to_power_off}
  end

  @impl VintageNet.PowerManager
  def power_off(state) do
    Logger.info("[Fp3Modem.PowerManager] power_off for #{state.ifname}")
    state = stop_online_task(state)
    {:ok, _} = Task.start(fn -> set_mode_if_ready(state.qmi, :offline) end)
    {:ok, state, @min_power_off_time}
  end

  @impl VintageNet.PowerManager
  def handle_info(_msg, state), do: {:noreply, state}

  defp stop_online_task(%{online_task: pid} = state) when is_pid(pid) do
    Process.exit(pid, :kill)
    %{state | online_task: nil}
  end

  defp stop_online_task(state), do: state

  defp online_loop(state, attempt, deadline) do
    case set_mode(state.qmi, :online) do
      :ok ->
        Logger.info("[Fp3Modem.PowerManager] set_operating_mode(:online) -> ok")

      error ->
        delay = backoff(attempt, state.retry_min_ms, state.retry_max_ms)

        if System.monotonic_time(:millisecond) + delay > deadline do
          Logger.error(
            "[Fp3Modem.PowerManager] giving up on set_operating_mode(:online) for " <>
              "#{state.ifname}: #{inspect(error)}; VintageNet's watchdog will reset the modem"
          )
        else
          if attempt == 0 or not match?({:error, {:service_not_found, _}}, error) do
            Logger.warning(
              "[Fp3Modem.PowerManager] set_operating_mode(:online) -> #{inspect(error)}, " <>
                "retrying in #{delay} ms"
            )
          end

          Process.sleep(delay)
          online_loop(state, attempt + 1, deadline)
        end
    end
  end

  @doc false
  @spec backoff(non_neg_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def backoff(attempt, min_ms, max_ms), do: min(max_ms, min_ms * Integer.pow(2, min(attempt, 16)))

  defp set_mode_if_ready(qmi, mode) do
    case set_mode(qmi, mode) do
      :ok ->
        :ok

      error ->
        Logger.warning(
          "[Fp3Modem.PowerManager] set_operating_mode(#{inspect(mode)}) -> #{inspect(error)}"
        )
    end
  end

  @doc false
  # Sends set_operating_mode. Before the modem announces its DMS service
  # the qmi driver answers {:error, {:service_not_found, 2}}, which the
  # callers retry. Never raises.
  @spec set_mode(atom(), atom()) :: :ok | {:error, term()}
  def set_mode(qmi, mode) do
    case QMI.DeviceManagement.set_operating_mode(qmi, mode) do
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, {:unexpected, other}}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
