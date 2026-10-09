# Driver mode (experimental)

Tap mode, the default, needs the System Audio Recording permission, and macOS shows its Privacy
indicator while eq runs. Driver mode plays through a virtual output device instead, **"BE-RCA · EQ"**
(named after the real device it plays on), from a Core Audio plug-in in `Driver/`: apps play to it,
and the plug-in runs the same EQ, compressor, colour and limiter on the real device. Nothing
records audio, so there is no permission and no indicator, and the device reports its whole latency,
so video players keep lip sync. It breaks Apple's rule that a plug-in may not use the HAL client
API, which is how it plays on the real device; see [Driver/README.md](../Driver/README.md).

```sh
eq mode driver
```

The first time, it installs the driver EQ.app carries: one administrator prompt (sudo in a
terminal, a macOS dialog otherwise), a copy to `/Library/Audio/Plug-Ins/HAL`, and a coreaudiod
restart, which drops every app's sound for about a second; eq waits for the EQ device, then
switches. It shows the device, points it at the current output, sends it that output's curve,
makes it the default output and writes `"mode": "driver"` to `eq.json`; the daemon then stops its
tap. `eq mode` shows the mode and the driver's build, `--dry-run` says what a switch would do,
password prompt included.

After `brew upgrade eq` the driver in `/Library` stays and keeps playing until you update it; see
[Updates](#updates).

From a checkout: `Driver/build.sh && sudo Driver/dev-install.sh` (see [Driver/README.md](../Driver/README.md)).

While the daemon runs in driver mode:

- Keep picking real devices in the Sound menu. When the default output becomes a real device, eq
  plays on it with its curve and makes the EQ device the default again, 0.4 s after the last change,
  so clicking through the menu costs one switch. Virtual devices, aggregates and AirPlay are left
  alone as the default, and if something moves the default more than three times in 10 s, eq stops
  taking it back for 30 s.
- Every change to the config, a preset, an app rule, `eq on|off`, the dynamics or a solo is sent to
  the plug-in, which keeps the last curve per device and plays it without the daemon, across
  coreaudiod restarts.
- `eq status` shows `mode: driver (BE-RCA · EQ → BE-RCA)`, the latency the device reports, and the
  plug-in's IO, underruns, overruns, clock correction and whether it plays a curve; `eq watch`
  reads the plug-in's meter; `eq events` adds `mode` and `target` events; `eq doctor` adds driver rows.
- If the EQ device is missing when the daemon starts, or stays gone for 3 s, the daemon runs the
  tap and says why in `eq status`, `eq mode` and `eq doctor`, rather than leave you without EQ; it
  goes back to the driver when the device returns.

A [silent output](commands.md#silent-outputs) gets a record that plays zeros, sent for every silent
output whether the EQ device plays on it or not, so the plug-in plays zeros from its first buffer on
it, and goes on doing so without the daemon. An EQ driver from before silent outputs (protocol 1)
cannot play zeros: it gets every gain at its floor instead, −120 dB, and `eq doctor` says the update
gives full silence.

In tap mode the EQ device is hidden and never the default output. `"driver": {"hideWhileDefault":
true}` tries hiding it while it is the default too; `eq doctor` reports whether macOS kept it.

## Updates

When EQ.app carries a newer driver than the one in `/Library`, `eq status`, `eq mode` and
`eq doctor` say so, and `eq mode driver` updates it with the same one prompt. Only a driver too old
to read this eq's settings sends the daemon back to the tap until you run it. A driver disabled by
its kill file (below) is never replaced, and nothing below offers to.

In driver mode, the next `eq` command you type in a terminal asks once, before it runs:

```
A newer EQ driver is in this eq (build 14 → 18): spectrum analyser, true silence for silent outputs.
Update it now? sudo asks for your password; sound drops for about a second. [y/N]
```

`y` updates it as `eq mode driver` would, then runs the command. Anything else is remembered for
that build in `~/.cache/eq/driver-update-declined`, and only a newer build asks again; Ctrl-C
stops both the question and the command. `eq tui` asks before it takes the screen. Nothing asks
under `--json` or `--dry-run`, without a terminal on stdin and stderr, from `eq mode`,
`eq driver uninstall`, completion, help or the man page, or with `EQ_NO_DRIVER_PROMPT=1`.

The daemon also posts one macOS notification per newer build, "EQ driver update", while it plays
the driver; the first one makes macOS ask whether EQ may send notifications. Clicking it runs
`eq mode driver` without a terminal, so macOS asks for the password in a dialog, and a second
notification says whether the update went through. If notifications are off for EQ, or a click
does nothing, `eq mode driver` in a terminal does the same. Without a click the daemon never asks
for a password, and in tap mode, or with no driver installed, nothing is offered.

## Back to tap mode, and recovery

```sh
eq mode tap
```

It writes the mode first, moves the default output back to the real device, then hides the EQ
device, each step giving up after 2 s, so a hung plug-in cannot hang it. If the default output
cannot be moved, it says so and prints the next steps. In order, stop at the first that brings sound back:

1. `sudo killall coreaudiod` (launchd starts it again).
2. Disable the plug-in with its kill file:
   `sudo touch /Library/Audio/Plug-Ins/HAL/EQDriver.driver/Contents/Resources/disabled && sudo killall coreaudiod`.
3. Remove it: `eq driver uninstall`, or `sudo rm -rf /Library/Audio/Plug-Ins/HAL/EQDriver.driver && sudo killall coreaudiod`.

[Driver/README.md](../Driver/README.md) has more on the plug-in.
