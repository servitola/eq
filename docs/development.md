# Development

Swift 5.10 or newer on macOS 14.4 or newer. No dependencies outside the SDK.

```sh
swift test                  # the daemon, CLI, formats, DSP and TUI, against fakes
Driver/test.sh              # the plug-in's core: ring, clock servo, settings, EQ, writer checks
Driver/test.sh --host-idle  # also loads the built plug-in into a fake host that never starts IO
scripts/build-app.sh        # build/EQ.app, ad-hoc signed, with the driver inside
scripts/smoke.sh            # the built daemon against a scratch config; play something first
make lint                   # zsh -n on the scripts, plutil on the plists
```

`Driver/build.sh` and `Driver/README.md` cover the plug-in on its own.

## Rules

- Tests never touch the real setup: no `~/.config/eq`, no running daemon, no launchd, no
  default output, no Core Audio tap. They run on fakes and on scratch files named by
  `EQ_CONFIG`, `EQ_STATUS` and `EQ_CACHE`.
- `scripts/smoke.sh` and `scripts/measure-latency.sh` start a real daemon and refuse to run
  beside one: two taps on one device stack. Stop yours first:
  `launchctl bootout gui/$UID/com.servitola.eq.daemon`, and `eq agent install` after.
- The IO callbacks run in real time. Anything that can block, disk, a lock, an allocation, a
  log line, a hook, stays off the audio thread.
- The driver runs inside coreaudiod. Installing one (`sudo Driver/dev-install.sh`, or
  `eq mode driver`) restarts coreaudiod and drops every app's sound for about a second;
  [driver mode](driver-mode.md#back-to-tap-mode-and-recovery) has the way back.
- A change people notice goes into `CHANGELOG.md`, in their words, under the version it ships
  in. That section becomes the release notes.
- Commit subjects are `Area: statement`, in English, without a full stop.

## Golden files and screenshots

```sh
EQ_UPDATE_GOLDEN=1 swift test --filter TUILookTests     # rewrite Tests/eqTests/Fixtures/tui
EQ_UPDATE_GOLDEN=1 swift test --filter KeyTableTests    # rewrite the key table in docs/tui.md
EQ_WRITE_SCREENSHOTS=<dir> swift test --filter TUILookTests
```

The last writes every screen as `.ans` into `<dir>/actual` and fills `<dir>/preview.template.html`
into a page that shows them, if that template is there.

## Measuring

```sh
scripts/measure-latency.sh                          # what eq adds, end to end, with clicks
swift test -c release -Xswiftc -enable-testing --filter DynamicsTests/testCost
```

Keep every other sound off while `measure-latency.sh` runs: audio in the silence before a click
hides its onset.
