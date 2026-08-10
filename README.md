# fp3_modem

> ### ⚠️ Very early work — built for a workshop, not for production
>
> Written for the **Goatmire Elixir workshop** on running Nerves on
> Fairphone 3 hardware. It exists for tinkering and teaching.
>
> **Not an actively maintained project** (yet) — no stability
> guarantees, no test coverage, APIs will change without notice.

`VintageNet.PowerManager` for the Fairphone 3+ in-SoC modem (msm8953,
MPSS firmware, IPA data path).

## Why this exists

On a cold boot the FP3+ modem firmware does **not** put itself into
online mode. `QMI_DMS_GET_OPERATING_MODE` reports `:shutting_down`, a
low-power state where:

- `UIM_READ_TRANSPARENT` fails with `:internal`, so EF_ICCID is
  unreadable — you can't even see the SIM
- the modem never registers on the network
- `WDS_START_NETWORK_INTERFACE` is rejected, because the radio is off

The symptom is a modem that looks present but does nothing, with no
obvious error explaining why.

ModemManager papers over this by unconditionally issuing
`QMI_DMS_SET_OPERATING_MODE = ONLINE` during its enable step, regardless
of what the previous read said. This library does the same, from the
standard VintageNet `power_on/1` callback — so the modem lifecycle hooks
into VintageNet's existing watchdog and reset machinery instead of
sitting outside it.

## Install

```elixir
defp deps do
  [{:fp3_modem, github: "mlainez/fp3_modem"}]
end
```

Depends on the [`qmi`](https://github.com/mlainez/qmi) and
[`vintage_net_qmi`](https://github.com/mlainez/vintage_net_qmi) forks —
upstream doesn't have the QRTR transport this modem needs.

## Configure

```elixir
config :vintage_net,
  power_managers: [
    {Fp3Modem.PowerManager, ifname: "wwan0"}
  ]
```

## License

Apache-2.0
