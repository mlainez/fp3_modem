# fp3_modem

> ### ⚠️ Very early work — built for a workshop, not for production
>
> Written for the **Goatmire Elixir workshop** on running Nerves on Fairphone 3 hardware. There are no stability guarantees and APIs will change without notice.

`VintageNet.PowerManager` for the Fairphone 3+ in-SoC modem (msm8953,
MPSS firmware, IPA data path), talking QMI over QRTR.

## Why this exists

On a cold boot the FP3+ modem firmware does **not** put itself into
online mode. `QMI_DMS_GET_OPERATING_MODE` reports `:shutting_down`, a
low-power state where:

- `UIM_READ_TRANSPARENT` fails with `:internal`, so EF_ICCID is
  unreadable — you can't even see the SIM
- the modem never registers on the network
- `WDS_START_NETWORK_INTERFACE` is rejected, because the radio is off

ModemManager papers over this by unconditionally issuing
`QMI_DMS_SET_OPERATING_MODE = ONLINE` during its enable step. This
library does the same from the standard VintageNet `power_on/1`
callback, so the modem lifecycle hooks into VintageNet's watchdog and
reset machinery.

## Install

```elixir
defp deps do
  [{:fp3_modem, github: "mlainez/fp3_modem"}]
end
```

The `qrtr-transport` branches of the [`qmi`](https://github.com/mlainez/qmi)
and [`vintage_net_qmi`](https://github.com/mlainez/vintage_net_qmi) forks
are **required** (upstream only speaks QMUX, not the QRTR transport this
modem uses). `fp3_modem` already depends on them; if your firmware also
lists `qmi` or `vintage_net_qmi` directly, point them at the same
branch:

```elixir
{:qmi, github: "mlainez/qmi", branch: "qrtr-transport", override: true},
{:vintage_net_qmi, github: "mlainez/vintage_net_qmi", branch: "qrtr-transport", override: true}
```

## Configure

Known-good configuration from a working FP3+ firmware. Replace the APN
with your carrier's:

```elixir
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
```

Power manager arguments:

| key                 | default   | meaning                                               |
|---------------------|-----------|-------------------------------------------------------|
| `:ifname`           | required  | VintageNetQMI interface name (non-empty string)       |
| `:watchdog_timeout` | `60_000`  | read by VintageNet, not by this module                |
| `:retry_min_ms`     | `500`     | first delay between attempts to put the modem online  |
| `:retry_max_ms`     | `10_000`  | backoff cap                                           |

Invalid arguments make `init/1` raise; VintageNet logs that and disables
the power manager.

## Behaviour

- `power_on/1` returns immediately (10 min hold time) and starts a
  background task. It waits until VintageNetQMI's QMI driver is running
  and the modem has announced its DMS service on QRTR, then sends
  `set_operating_mode(:online)`. Errors and exits from QMI are logged
  and retried with exponential backoff for up to the 10 min hold time;
  after that VintageNet's watchdog takes over.
- `start_powering_off/1` stops that task, sends
  `:persistent_low_power` (if DMS is reachable) so the modem detaches
  from the network, and gives it 5 s.
- `power_off/1` stops the task, sends a best-effort `:offline`, and keeps
  the modem off for at least 2 s.

No callback raises or blocks on QMI, so a missing modem or QMI service
can't crash VintageNet's power manager.

To detect the DMS announcement the module reads the QMI driver's
transport from its process state (the fork has no public API for it),
so it's tied to the internals of the `qrtr-transport` branch.

## Toolchain

Built and tested with Erlang/OTP 29.1.1 and Elixir 1.20.4, matching the
official Nerves systems (see `.tool-versions`).

`mix test` runs on the host against fake QMI driver/transport processes.
The retry/readiness changes have **not** been re-verified on a Fairphone
3+ yet.

## License

Apache-2.0
