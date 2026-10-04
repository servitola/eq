# Install

```sh
brew install --cask servitola/tap/eq
```

That is all. Homebrew wants third-party taps named in full; the line above trusts this one
cask, no more. The cask also carries the audio driver for [driver mode](driver-mode.md),
inside EQ.app; nothing goes into `/Library` until you turn driver mode on.

The first `eq` you run registers the daemon as a login item named **EQ**: macOS says "Background Items Added", and it is listed under System Settings →
General → Login Items → Allow in the Background, where it can be switched off. From then on
it starts at login and restarts if it dies. `eq agent uninstall` removes it for good: no later
`eq` command registers it again until `eq agent install`.

Its first start asks once for **System Audio Recording**. Grant it to *EQ*, and `eq status`
says `running`. Until then `eq` says on stderr that it is not equalising and where to allow it.

No config file is needed: every command works on the default curve until you change
something, and that first change writes `~/.config/eq/eq.json`. `eq init` writes it right away
if you want a file to edit by hand.

If you started eq with a hand-made `~/Library/LaunchAgents/com.servitola.eq.plist` before the
app carried its own, that plist keeps working and eq never registers a second daemon beside
it; `eq doctor` names it as `legacy`. `eq agent install --replace-legacy` boots it out, moves
the plist to the Trash and starts the bundled login item instead.

## Uninstall

```sh
brew uninstall --cask eq          # --zap also removes the config, cache, log and login items
```

If driver mode ever installed the driver, this takes it out too: eq switches to tap mode, which
moves the default output back to a real device, then asks once for an administrator password to
remove `/Library/Audio/Plug-Ins/HAL/EQDriver.driver` and restart coreaudiod. `brew upgrade` and
`brew reinstall` run the same cask step, and there the driver stays: Homebrew passes the step
nothing that tells them apart, so eq reads the command line of the `brew` process above it and
removes the driver only under `brew uninstall` (`rm`, `remove`). Without Homebrew, or to drop the
driver and keep eq: `eq driver uninstall`.

coreaudiod keeps the curves the driver stored, a few kilobytes under `Plug-In.com.servitola.eq.driver`
in `/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist`. eq leaves them: that file is
coreaudiod's own, rewritten while it runs, and nothing reads the entry once the driver is gone.
