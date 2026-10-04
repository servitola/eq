# Events, hooks and the meter socket

## Events

`eq events` prints one JSON line per state change until Ctrl-C, and exits 1 when the daemon
is not running or predates events. Every line has `t` (Unix seconds) and `event`:

| `event` | fields | when |
| --- | --- | --- |
| `daemon` | `state`, `version`, `error` | the daemon's state changes; also the first line, the state it is in now |
| `device` | `device`, `uid`, `transport`, `rate` | the EQ runs on another output |
| `rate` | `device`, `rate` | the same output changes sample rate |
| `profile` | `device`, `preset` (or `null`), `source` (`device` or `default`) | the curve, preset or knob in effect changes |
| `enabled` | `enabled` | `eq on` / `eq off` |
| `solo` | `solo`: `{"low":L,"high":H}` or `null` | a watch starts or stops listening to one range |
| `app` | `app`, `name`, `preset` (or `null`) | an app rule starts or stops being heard (experimental) |
| `mode` | `mode` (`tap` or `driver`), `target` (or `null`), `reason` (or `null`) | the path changes; `reason` says why the tap runs in driver mode |
| `target` | `device`, `uid` | in driver mode, the EQ device plays on another real device |

```sh
eq events | jq -r --unbuffered 'select(.event == "device") | "\(.device) at \(.rate) Hz"'
```

A `device` event is sent when the profile is applied to the new output, before the daemon has
confirmed that the output is running. A rate change that narrows or widens the range a solo can
actually play publishes no new `solo` event; the last one keeps the range clamped at the old rate.

It rides the meter socket: a client that writes `{"subscribe":"events"}` as its first line gets
events instead of frames, and the meter stays off for it. A client that writes nothing, as
`eq stream` and `eq watch` do, gets frames exactly as before.

## Hooks

Hooks are shell commands the daemon runs on a change, under `hooks` at the top of `eq.json`:

```json
"hooks": {
  "device": "say \"$EQ_DEVICE, $EQ_RATE hertz\"",
  "preset": "/Users/me/bin/on-preset.sh"
}
```

`device` runs when the output or its sample rate changes, `preset` when the preset in effect
does; both run once when the daemon starts. A burst of changes runs a hook once, a second after
the last, for the state it settled in. The daemon runs it with `/bin/sh -c`, off the audio
path, with `EQ_DEVICE`, `EQ_PRESET` (empty without one) and `EQ_RATE` in its environment. After
10 s the hook and everything it started are killed. Its output, cut at 4 KB, and its exit
status go to the daemon's log; a failing hook never touches the audio. Other names are logged
and ignored. `eq doctor` warns about a hook whose program is an absolute path that is missing
or not executable.

## The meter socket

`eq stream`, `eq watch` and `eq tui` read their frames from this socket; `eq events` subscribes to it.

Any meter client can ask for a solo by writing `{"solo":{"low":L,"high":H}}` to the socket,
one JSON object per line, with `0 ≤ L < H ≤ 100000` Hz; any other line is ignored. The last
accepted range wins and its sender owns it. Only the owner clears it: with `{"solo":null}`,
with a range the daemon refuses at the current sample rate, or by disconnecting. A `null` from
any other client is ignored, so a second `eq watch` cannot switch off the first one's solo.
The socket takes at most eight clients at once, meter and events clients together, and closes
any beyond that.
