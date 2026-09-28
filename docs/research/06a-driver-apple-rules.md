# Design A under Apple's rules: what an AudioServerPlugIn may and may not do

Date: 2026-09-28. Machine: macOS 26.6.2 (25G83), Xcode SDK `macosx26.6`.

Scope: design A, an output-only virtual AudioServerPlugIn (ASP) that applies the EQ inside
`coreaudiod`'s plug-in host and then plays the result to the real output device from inside
the plug-in. The question here is what Apple's rules say about that, what the plug-in host
actually looks like on macOS 26, and whether any sanctioned route to a real (especially
Bluetooth) output exists. Other slices cover engineering (`06c`).

Method: primary sources first (the SDK header, Apple Technical Q&A, Apple sample-code
pages, WWDC, Apple Developer Forums replies from Apple staff), then first-hand inspection
of this machine, read-only: `ps`, `codesign`, `plutil`, the sandbox profile on disk,
`log show`, `strings` over the dyld shared cache, and `sandbox_check()` against running
PIDs. Nothing was installed, loaded, restarted or signalled.

Each claim is marked either **[Apple]**, a direct Apple statement, **[observed]**, seen on
this machine, or **[inferred]**, reasoned from the first two and not documented anywhere.

---

## TL;DR

1. **Apple forbids it, in writing, twice, and DTS restated it.** The SDK header says
   *"an AudioServerPlugIn may not make any calls to the client HAL API in the
   CoreAudio.framework. This will result in undefined (but generally bad) behavior."*
   A DTS engineer said on the forums in 2021: *"an ASP cannot itself output to any real
   audio devices."* Design A's core act is opening a real device and running an IOProc on
   it from the plug-in. That is exactly the forbidden call class.
2. **Host model on macOS 11 through 26:** third-party `.driver` bundles in
   `/Library/Audio/Plug-Ins/HAL` do not run inside `coreaudiod`. Each one runs in its own
   XPC helper, `Core Audio Driver (<Name>.driver)`
   (`CoreAudio.framework/XPCServices/com.apple.audio.Core-Audio-Driver-Service.helper.xpc`),
   owned by `_coreaudiod`. It talks to `coreaudiod` over NSXPC. Apple's own plug-ins in
   `/System/Library/Audio/Plug-Ins/HAL`, including `BTAudioHALPlugin.driver`, still run
   in-process. The header wording changed in the macOS 11.0 SDK, from *"operates in a
   limited environment"* to *"operates in its own process separate from the system
   daemon"*.
3. **Why the rule exists [inferred]:** the plug-in serves synchronous requests from
   `coreaudiod`. Property gets, `StartIO`, and config changes are XPC calls with `reply:`
   blocks, serialised behind `HALB_Mutex` locks. A HAL client call from the plug-in
   (`AudioObjectGetPropertyData`, `AudioDeviceStart`, and so on) is another IPC into the
   same `coreaudiod`, and it may need those same locks. That forms a cycle. Before macOS 11
   the cycle was inside one process. Now it spans two processes, which only changes where
   the hang shows up. Proxy Audio Device's workaround is a separate dispatch thread and a
   1-second delayed init. It shrinks the window but does not remove it. Its author calls it
   "breaking some rules", and it has an open, never-root-caused drift/silence bug.
4. **Sanctioned routes to a real device from a plug-in: none for our case.**
   - A plug-in may reach **hardware it owns**, through IOKit user clients or a DriverKit
     dext.
   - It may reach **its own transport**, through network or Mach services, which is the
     AirPlay/AVB pattern.
   - It may not reach **another driver's device**. Aggregate, multi-output and
     `kAudioPlugInCreateAggregateDevice` are *client* APIs, so using them from a plug-in
     is the same forbidden act.
   - **Bluetooth output is itself an Apple ASP** (`BTAudioHALPlugin`), fed by a private
     XPC protocol to `bluetoothd`. There is no public or DriverKit Bluetooth-audio path
     for a third party.
   - Apple's own recommended answer for "process the system's output" is the Core Audio
     **process tap**, which is what `eq` uses today. That route carries the Privacy
     indicator.
5. **Watchdog and crashes:** `coreaudiod` logs *"NOT registering with watchdog - platform
   behaviors says not to"* on this Mac. That means no hang watchdog on macOS. Out-of-process
   hosting means a crashing plug-in takes down its helper. `coreaudiod` then runs a
   "driver service undertaker", not a full audio outage. A plug-in that **hangs** while
   `coreaudiod` waits on a reply has no documented timeout. Community reports of silence
   that only `killall coreaudiod` fixes fit that failure mode.

---

## 1. Every Apple statement found

### 1.1 The SDK header: `CoreAudio/AudioServerPlugIn.h` (macOS 26.6 SDK)

Path: `$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Headers/AudioServerPlugIn.h`,
overview block, lines 21–103. Quoted verbatim.

**Host model and the prohibition (lines 34–36):**

> An AudioServerPlugIn operates in its own process separate from the system daemon. First and
> foremost, an AudioServerPlugIn may not make any calls to the client HAL API in the
> CoreAudio.framework. This will result in undefined (but generally bad) behavior.

**Sandbox, file system (lines 38–42):**

> Further, the host process is sandboxed. As such, an AudioServerPlugIn may only read files in its
> bundle in addition to the system libraries and frameworks. It may not access user documents or
> write to any filesystem locations other than the system's cache and temporary directories as
> derived through Apple API. The host provides a means for the plug-in to store and retrieve data
> from persistent storage.

**Mach services (lines 44–47):**

> An AudioServerPlugIn may communicate with other processes on the system. However, the plug-in
> must list the name of the mach services to be accessed in the plug-in bundle's info.plist in a
> key named "AudioServerPlugIn_MachServices". The value of this key is an array of the names of
> the mach services that need to be accessed.

**IOKit (lines 49–53):**

> An AudioServerPlugIn may create user-clients via IOServiceOpen() for standard IOKit objects
> without restriction. However, if a plug-in needs to create a custom user-client, it must list
> the name of the class of the user-client in the plug-in bundle's info.plist in a key named
> "AudioServerPlugIn_IOKitUserClients". The value of this key is an array of the names of the
> classes.

**Network (lines 55–57):**

> An AudioServerPlugIn may also use network resources. However, the plug-in must declare this in
> its bundle's info.plist with the key named, "AudioServerPlugIn_Network". The value of this key
> is a boolean and must be set to true if the key is present.

**Host controls IO and structure (lines 65–82):**

> When the state of an AudioObject implemented by the plug-in changes, it notifies the host using
> the host routine, PropertiesChanged(). The only exception to this is for AudioDevice objects.
> AudioDevices may call the host's PropertiesChanged() routine only for state changes that don't
> have any effect on IO or on the structure of the AudioDevice, such as a change to the value of a
> volume control.
>
> For changes to an AudioDevice's state that will affect IO or its structure, the change may not
> be made without first making a call to the host's RequestDeviceConfigurationChange() routine.
> This allows the host an opportunity to stop any outstanding IO and otherwise return the device
> to its ground state. […]
>
> The host is in control of IO. It tells the plug-in's AudioDevice when to start and when to stop
> the hardware. The host drives its timing using the timestamps provided by the AudioDevice's
> implementation of GetZeroTimeStamp().

**Where processing is *allowed* (lines 84–89).** This is the sanctioned DSP hook, and it
applies only to the plug-in's *own* device:

> The host provides the plug-in's device access to several tap points into the system's mix engine
> to allow for a variety of features, including adding processing to the signal. The host breaks
> these tap points down into IO operations that the host asks the plug-in to perform at the
> appropriate time. […] Note that the IO operations are performed on a real time thread on a
> deadline. As such the plug-in must avoid avoid blocking and return as quickly as possible.

The IO operation list includes `kAudioServerPlugInIOOperationProcessOutput` (*"arbitrary
signal processing on the output data in the canonical format"*) and
`kAudioServerPlugInIOOperationProcessMix` (*"processes the full mix of all clients' data"*).
It also includes `kAudioServerPlugInIOOperationWriteMix`, which *"puts the data into the
device's ring buffer for consumption of the hardware"*. The "hardware" there is the
plug-in's own. Nothing in the IO model hands a plug-in another driver's device.

**DriverKit bridge (lines 91–103).** This is the only documented way down to hardware:

> An AudioServerPlugIn can talk to a DriverKit-based Driver Extension. To do so requires adjusting
> the packaging of the CFPlugIn bundle slightly in order to carry the required entitlements. This
> requires turning the AudioServerPlugIn bundle into an executable. […]
>   - Add the "Load As Application" key with the value of the number 1 to the
>     AudioServerPlugIn's info.plist.
>   - […] Set the "Mach-O Type" build setting for the target to Executable.
>   - Add "-e _AudioServerPlugInMain" to the "Other Linker Flags" […]
>   - Code sign the binary such that it includes the
>     "com.apple.developer.driverkit.userclient-access" entitlements necessary for talking to
>     the Driver Extension.

**Host interface.** `AudioServerPlugInHostInterface` has exactly five callbacks. None of
them opens, reads or writes another device:

| Callback | Apple's description (verbatim, abridged) |
| --- | --- |
| `PropertiesChanged` | *"informs the Host when the state of an plug-in's object changes"*; for devices *"only used for state changes that don't affect IO or the structure of the device"* |
| `CopyFromStorage` | *"fetch the data associated with the named storage key"* |
| `WriteToStorage` | *"any data stored this way is persists beyond the life span of the Host including across rebooting"* |
| `DeleteFromStorage` | *"remove the given key and any associated data from storage"* |
| `RequestDeviceConfigurationChange` | *"the call to PerformDeviceConfigurationChange() may be deferred to another thread at the discretion of the host"* |

**History of the wording [observed].** I diffed the header across SDKs (phracker/MacOSX-SDKs
mirror of Apple SDKs):

| SDK | Line 34 wording | DriverKit block |
| --- | --- | --- |
| 10.9, 10.11, 10.15 | "An AudioServerPlugIn operates in a limited environment." | absent |
| 11.0, 11.1, 11.3, 26.6 | "An AudioServerPlugIn operates in its own process separate from the system daemon." | present |

So the out-of-process host arrived with macOS 11 Big Sur. The HAL-client prohibition
predates it and survived it unchanged. It is not an artefact of in-process hosting. Apple
kept it after moving plug-ins out of process.

### 1.2 Technical Q&A QA1811 (2013-11-19)

<https://developer.apple.com/library/archive/qa/qa1811/_index.html>,
*"Audio Server PlugIn - The AudioServerPlugIn_MachServices plist Key"*:

> Q: How does my user-space plug-in talk to other processes?
>
> A: An AudioServerPlugIn operates in a limited environment. First and foremost, an
> AudioServerPlugIn may not make any calls to the client HAL API in the CoreAudio.framework.
> This will result in undefined (but generally bad) behavior. […]

The same text as the header, published as a standalone DTS answer.

"Client HAL API" means HAL Services. Apple's *Core Audio Overview* defines those as
*"the functions, data types, and constants declared in the following header files in
CoreAudio.framework: AudioDriverPlugin.h, AudioHardware.h, AudioHardwarePlugin.h,
CoreAudioTypes.h […], HostTime.h"*
(<https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/WhatsinCoreAudio/WhatsinCoreAudio.html>).
`AudioObjectGetPropertyData`, `AudioDeviceCreateIOProcID`, `AudioDeviceStart`, and
anything built on them (AUHAL, `AVAudioEngine`, `AudioQueue` output) are all in scope.

### 1.3 Apple Developer Forums: Apple-staff replies

- **DTS Engineer, Sep 2021**, thread 689617, *"How to implement and publish virtual audio
  driver to Apple App Store?"*
  (<https://developer.apple.com/forums/thread/689617>):
  > Generally, if you are not interfacing to hardware of your own, AudioServerPlugin is your
  > only choice, but an ASP cannot itself output to any real audio devices.

  This is the most direct Apple statement against design A.
- **Apple staff, Mar 2025**, thread 775341, *"CoreAudio HAL plugin vs dext"*
  (<https://developer.apple.com/forums/thread/775341>):
  > When creating a virtual device, best practice is to use an Audio Server Driver Plug-in
  > instead […] AudioDriverKit only supports physical audio devices.

  And, on use cases like ours: *"if you are using a virtual device for the sole purpose of
  looping back audio from the system, you might consider using a Core Audio tap instead."*
- **Apple staff, Aug 2023**, thread 736357, *"Entitlements for a virtual audio driver
  including IOUserClient"* (<https://developer.apple.com/forums/thread/736357>):
  > AudioDriverKit currently does not support virtual audio devices and entitlements will not
  > be granted for those types of audio drivers. You will need to use AudioServerPlugIn if you
  > want to implement a virtual audio device, which does require a reboot, or at least needs
  > to restart the coreaudiod process.
- **Apple Media Engineer, Jul 2020**, thread 653571
  (<https://developer.apple.com/forums/thread/653571>). This rules out the
  System-Extension packaging:
  > Usually your installer just needs to install your ASP driver in /Library/Audio/Plug-Ins/HAL.

Searches I ran on the forums: "AudioServerPlugIn HAL client", "HAL plug-in deadlock",
"Core Audio Driver process", and "AudioServerPlugIn crash coreaudiod restart". They found
**no** Apple-staff post that explains the *mechanism* behind the prohibition, and none on
watchdog or timeout behaviour. Thread 129737 (writing to disk from a plug-in) got only a
clarifying question from DTS and never an answer.

### 1.4 WWDC

- **WWDC21 session 10190, "Create audio drivers with DriverKit"**
  (<https://developer.apple.com/videos/play/wwdc2021/10190/>):
  > This will continue to be supported and the AudioServerPlugIn driver interface is not
  > deprecated. […] the sample code presented is purely for demonstration purposes and creates
  > a virtual audio driver that is not associated with a hardware device, and so entitlements
  > will not be granted for that kind of use case. If a virtual audio driver or device is all
  > that is needed, the audio server plug-in driver model should continue to be used.

  So a DriverKit dext is not a way around this for a virtual EQ device. Apple will not
  grant the entitlement.
- I found no WWDC session that introduces AudioServerPlugIns or discusses HAL client calls
  from inside one. The ASP interface shipped around OS X 10.8/10.9 with header docs only.
  The `05-quality-and-core.md` report likewise found no dedicated WWDC session for process
  taps.

### 1.5 Apple sample-code pages

- *Creating an Audio Server Driver Plug-in* (NullAudio,
  <https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in>):
  *"This sample shows how to create a minimal Audio Server plug-in. […] Install the
  sample's `.driver` bundle to `/Library/Audio/Plug-Ins/HAL` and reboot your computer."*
  It publishes a virtual device only and never touches another device.
- *Building an Audio Server Plug-in and Driver Extension* (SimpleAudio + dext,
  <https://developer.apple.com/documentation/coreaudio/building-an-audio-server-plug-in-and-driver-extension>):
  it requires `com.apple.developer.driverkit` plus a **transport** entitlement
  (`com.apple.developer.driverkit.transport.usb`). That means real USB hardware you own.
- The DocC reference pages for `AudioServerPlugInDriverInterface` and
  `AudioServerPlugInHostInterface` are empty stubs, fetched as JSON on 2026-09-28. The
  header is the documentation.

### 1.6 coreaudio-api mailing list: not retrieved

- **Target thread.** BackgroundMusic's `DEVELOPING.md` cites
  <https://lists.apple.com/archives/coreaudio-api/2013/Aug/msg00030.html> as the reason
  AudioHardwarePlugIn was deprecated (*"issues with the OS X sandbox"*).
- **Why it is missing.** `lists.apple.com` returned HTTP 502 on two attempts, and
  web.archive.org is blocked from this environment. The mail-archive.com mirror only
  starts in 2014. I searched it for `AudioServerPlugIn` (45 hits, no `@apple.com` author)
  and for `"Jeff Moore"`, with no relevant result. Jeff Moore has not posted since 2013.
- **Status.** Jeff Moore's or Doug Wyatt's own explanation of *why* is **not captured
  here**. That is a known gap. §2 gives the mechanism as inference from the binaries instead.

---

## 2. Why the rule exists: the host environment on macOS 26

### 2.1 The process model, observed on this Mac

```
$ ps axo pid,user,ppid,comm | grep -i audio
96715 _coreaudiod   1 /usr/sbin/coreaudiod
96724 _coreaudiod   1 Core Audio Driver (ParrotAudioPlugin.driver)
```

`proc_pidpath(96724)` resolves to
`/System/Library/Frameworks/CoreAudio.framework/Versions/A/XPCServices/com.apple.audio.Core-Audio-Driver-Service.helper.xpc/Contents/MacOS/com.apple.audio.Core-Audio-Driver-Service.helper`.

- **One helper per third-party bundle.** `/Library/Audio/Plug-Ins/HAL/` holds exactly one
  bundle, `ParrotAudioPlugin.driver` (Apple-signed), and there is exactly one helper. The
  helper's `Info.plist` sets `XPCService._MultipleInstances = true`, which gives one
  instance per driver.
- **System plug-ins stay in-process.** None of the 12 bundles in
  `/System/Library/Audio/Plug-Ins/HAL/` has a helper: `BTAudioHALPlugin`, `AirPlay`,
  `AppleAVBAudio`, `usbaudiodxpc`, and the rest. They run inside `coreaudiod`.
- **The launch is logged:** `HALS_RemotePlugInRegistrar.mm:421 Creating remote driver
  service: "ParrotAudioPlugin.driver", pid: 96724`.
- **Helper entitlements:** `com.apple.private.audio.driver-host` and
  `com.apple.security.cs.disable-library-validation`. The second one is why a
  third-party-signed bundle can be loaded into an Apple binary.
- **Linked symbols** in the helper: `CFPlugInCreate`, `CFPlugInInstanceCreate`,
  `sandbox_extension_consume`, `sandbox_extension_issue_mach`,
  `sandbox_extension_issue_iokit_registry_entry_class`.
- **Protocol strings in the helper:** `Core_Audio_Driver_Host_Proxy.mm`, `IO_Receiver.mm`,
  `object_properties_changed:properties_data:reply:`,
  `perform_device_configuration_change:action:change:reply:`,
  `request_config_change:change_action:change_token:reply:`, and
  `Driver service is exiting!`.

  The host interface the plug-in sees (`PropertiesChanged`, `RequestDeviceConfigurationChange`)
  is an NSXPC proxy back into `coreaudiod`. IO cycles arrive through an `IO_Receiver`.
- **`coreaudiod` side**, from the dyld shared cache: `HALS_UCRemotePlugIn`,
  `HALS_RemotePlugInRegistrar::LaunchDriverService`, `::LaunchDriverAppService` (the
  "Load As Application" path), `::CreateDriverServiceUndertaker`,
  `::CreateExtrinsicDriverEntryPoint`, `connection to driver service is interrupted`,
  `connection to driver service is invalidated`, `Failed calling start_io on remote driver`,
  and `HALB_Mutex::Lock`.
- **Private registrar.** "Extrinsic" drivers are separate Apple daemons that register
  themselves through the `com.apple.audio.driver-registrar` Mach service. The log shows
  `Registering remote driver with bundle id com.apple.AirPlayXPCHelper`. This path is
  private; the helper checks `valueForEntitlement:` and logs *"Process %d does not have the
  proper entitlements to use this service."*

### 2.2 The mechanism [inferred]

The inference rests on the strings above plus the header's contract. Apple has not
published it.

1. **`coreaudiod` calls the plug-in synchronously.** Property reads, `StartIO`,
   `PerformDeviceConfigurationChange` and `AddDeviceClient` are XPC messages with `reply:`
   blocks. The calling `coreaudiod` thread often holds object locks (`HALB_Mutex`) while
   it waits. A client asking `coreaudiod` about our virtual device parks a `coreaudiod`
   thread until the helper answers.
2. **A HAL client call from the plug-in goes back through the same server.** The helper
   links CoreAudio.framework, so `AudioObjectGetPropertyData` in the helper becomes a HAL
   client connection to `com.apple.audio.audiohald`, and that is `coreaudiod`.
   `sandbox_check()` shows the lookup is not denied; see §3.1.
3. **The two directions can meet.** Examples: `coreaudiod` waits for the plug-in's reply
   while holding the system or device lock, and the plug-in's call needs that lock. Or a
   config change on the real device, such as a Bluetooth route change or rate change,
   notifies our listener, and the listener's handler calls back in. Either way it is a
   lock-order cycle across two processes. Before macOS 11 it was a same-process deadlock.
   That is what Proxy Audio Device's author saw in 2020, on Catalina with in-process
   hosting: *"If something goes wrong then what happens is coreaudiod deadlocks […] I did
   it several times in the course of developing the plugin."*
   (<https://github.com/briankendall/proxy-audio-device/issues/6>)
4. **Two clocks meet inside a real-time callback.** The virtual device's `GetZeroTimeStamp`
   timeline and the real device's hardware clock are different clock domains. Only a
   *client* aggregate device with drift compensation reconciles them. A plug-in that
   bridges them itself needs its own ring buffer and resampler. This is Proxy Audio
   Device's unresolved bug (#14, #19, #43, #62):

   > For some reason the proxied and proxy devices don't read / write to the buffer at
   > precisely the same speed, and it eventually goes too far out of sync and runs out of
   > audio to play on the proxied device.

   That author reports hours of fruitless debugging. The HAL IO thread's real-time
   deadline (*"must avoid blocking"*) forbids waiting on the other device.
5. **Why "undefined" rather than "error".** Nothing in the helper blocks the call. The
   sandbox allows the `audiohald` lookup, which `coreaudiod`'s own profile needs. So the
   failure is not an error return but a hang or glitch that depends on timing. That
   matches the header's wording exactly.

**Proxy Audio Device's workaround** (`ProxyAudioDevice.cpp:4933–4945`):

- It moves every HAL client call to a private serial dispatch queue and delays init by 1 s.
  Its comment reads: *"Any initialization that involves calling CoreAudio APIs must be
  done here in a separate thread from the rest of the driver. Otherwise we'll get
  deadlocks!"*
- This removes the *same-thread* re-entrancy case only. A cross-thread lock cycle is still
  possible whenever a `coreaudiod` thread blocks on a synchronous call into our plug-in
  while the plug-in's queue waits on `coreaudiod`.
- The author's own verdict, in issue #6: *"Proxy Audio Device is breaking some rules and
  doing some hacky things."*

### 2.3 Crash, hang and watchdog

- **No watchdog on macOS [observed].** `coreaudiod` logs at every launch:
  `HALS_System.cpp:5839 NOT registering with watchdog - platform behaviors says not to`.
  It appeared twice on 2026-09-28, at 13:45:22 and 13:45:35, when `coreaudiod` restarted
  outside this session. A hung `coreaudiod`, or a `coreaudiod` stuck waiting on a hung
  plug-in, is not auto-killed on macOS. `sudo killall coreaudiod` or a
  `launchctl kickstart -k system/com.apple.audio.coreaudiod` is the user's only remedy.
  That matches the community workarounds (proxy-audio-device #19 and #62).
- **A crashing plug-in is contained [observed + inferred].** Out-of-process hosting means
  a plug-in crash kills only its `Core Audio Driver (…)` helper. `coreaudiod` has
  `CreateDriverServiceUndertaker` plus interruption/invalidation handlers. So the plug-in's
  devices vanish, the default output presumably falls back, and the rest of system audio
  continues. I did not observe whether the helper is relaunched automatically. Testing
  that would need a crash, which is out of scope.
- **A hanging plug-in is not contained [inferred].** I found no timeout string for driver
  replies. If a synchronous call into the helper never returns, the `coreaudiod` thread
  and any locks it holds stay blocked. Clients of *any* device that need those locks then
  stall. Design A is uniquely exposed here, because its plug-in is simultaneously a server
  (our virtual device) and a client (the real device) of the same daemon.
- **Real-time budget.** A plug-in that blows its IO deadline causes glitches (overloads)
  for everything mixed through its device. Since design A makes our device the default
  output, that is *all* system audio.

---

## 3. Plug-in sandbox, packaging and signing

### 3.1 What the host lets a plug-in touch

| Resource | Apple's rule (header) | What exists on 26 [observed] |
| --- | --- | --- |
| Files | Read own bundle and system libraries; write only system cache/temp; persist through `CopyFromStorage`/`WriteToStorage` | Profile `/System/Library/Sandbox/Profiles/com.apple.audio.coreaudiod.sb`: `(deny default)`, read of `/Library/Audio/Plug-Ins/HAL`, `/System`, `/Library/Preferences/Audio`; write only `/Library/Preferences{,/Audio,/Audio/Data}` |
| Mach services | List them in `AudioServerPlugIn_MachServices` | Profile line 154: `(allow mach-lookup (extension "com.apple.audio.driver-host.mach-service-name"))`. The helper issues that extension per listed name and logs *"The plug-in named %s requires extending the sandbox for the mach service named %s."* |
| IOKit | Standard user clients free; custom ones listed in `AudioServerPlugIn_IOKitUserClients` | Profile line 153: `(allow iokit-open iokit-set-properties (extension "com.apple.audio.driver-host.iokit-user-client-class"))` |
| Network | `AudioServerPlugIn_Network = true` | Profile line 159: `(allow network*)`, unconditional in the daemon profile |
| DriverKit dext | "Load As Application" + `com.apple.developer.driverkit.userclient-access` | `LaunchDriverAppService` path in `coreaudiod` |
| HAL client | **Forbidden** | *Not enforced:* the profile allows `mach-lookup com.apple.audio.audiohald` (line 102), because `coreaudiod` itself needs it |

**Caveat on the sandbox claim [observed].** `sandbox_check(pid, NULL, 0)` with a tiny C
probe (`scratchpad/sbx.c`) reports `coreaudiod` (96715) **sandboxed = 1** and the Parrot
driver helper (96724) **sandboxed = 0**. For the helper it also reports reads of
`~/.zshrc` as *not* denied. So on 26.6, at least for this Apple-signed third-party-path
plug-in, the helper process ran **unsandboxed**, contrary to the header's *"the host
process is sandboxed"*.

- **Undetermined:** whether a Developer ID–signed plug-in gets the same treatment.
  Checking would require installing one.
- **Design consequence:** do not rely on the sandbox to block a HAL client call, and do
  not rely on its absence either. The documented contract is the sandboxed one.

**Bluetooth (§4) is the telling Mach-service case.** Apple's in-process
`BTAudioHALPlugin.driver` lists nine private services in `AudioServerPlugIn_MachServices`:
`com.apple.BTAudioHALPlugin.xpc`, `com.apple.BTServer`, `com.apple.BTServer.le`,
`com.apple.BTLEAudioController.xpc`, `com.apple.AudioAccessoryCommunication.xpc`, and
others. A third-party plug-in *could list the same names*. Nothing documents that the
services on the other end accept a non-Apple peer, though. `bluetoothd`'s entitlements
include `com.apple.bluetoothaudiod`. This is **[inferred]** to be entitlement-gated and
undocumented, not a usable path.

### 3.2 Packaging, installation, code signing

- **Location and restart.** Install to `/Library/Audio/Plug-Ins/HAL/<Name>.driver`.
  Loading needs a `coreaudiod` restart or a reboot (Apple, threads 736357 and 653571). It
  cannot ship as a System Extension (thread 653571), and it cannot go through the Mac App
  Store in practice (thread 689617, where DTS redirects to a DTS incident).
- **Loading conditions.** The only defined key is `AudioServerPlugIn_LoadingConditions` →
  `IOService Matching`, which loads the plug-in only when a matching IOService exists.
- **Signing [observed + inferred].**
  - The host helper carries `com.apple.security.cs.disable-library-validation`, so it
    loads code from any Team ID. On Apple silicon the kernel still requires *some* valid
    signature, ad hoc at minimum.
  - I found no Apple statement requiring notarization *at load time*. `coreaudiod` does
    not run Gatekeeper on `.driver` bundles. Notarization matters for the **installer**
    (`.pkg`) under Gatekeeper, which is how BlackHole and eqMac ship.
  - Not tested: whether an ad-hoc-signed `.driver` loads on 26 with SIP on. The
    Parrot bundle here is Apple-signed, so it does not answer the question.
- **Debugging.** Developers report needing SIP off to attach a debugger to the host
  (thread 775341, ssmith_c). That is consistent with the helper being an Apple platform
  binary.

---

## 4. Is there any *sanctioned* way for a plug-in to deliver audio to another device?

| Candidate | Sanctioned? | Why / why not |
| --- | --- | --- |
| Plug-in opens the real device with `AudioDeviceCreateIOProcID`/AUHAL (design A, Proxy Audio Device) | **No** | Header + QA1811: HAL client API forbidden. DTS 2021: *"an ASP cannot itself output to any real audio devices."* |
| `kAudioPlugInCreateAggregateDevice` / multi-output ("stacked") device | **No, from inside a plug-in** | This is a property on Apple's aggregate plug-in object that a *client* reads through `AudioObjectGetPropertyData` (`AudioHardware.h:691`). Calling it from our plug-in is a HAL client call. A multi-output device made by a *client* sends the same client audio to several devices. It does not pipe our device's output into another device, and it runs no DSP in between. |
| Host interface (`PropertiesChanged`, `RequestDeviceConfigurationChange`, storage) | No | None of the five callbacks moves audio. They are notification, config and persistence only. |
| `ProcessMix`/`ProcessOutput` IO operations | Yes, but only on **our own** device | This is the sanctioned DSP point. It is exactly where an EQ belongs if the EQ *is* the output device, but then something still has to carry the samples to real hardware. |
| Plug-in owns the transport: network (AirPlay-like, `AudioServerPlugIn_Network`) or IOKit/DriverKit to hardware you make | Yes | This is Apple's model for AVB, AirPlay and USB vendors. It does not apply to arbitrary existing outputs such as a third-party BT speaker or USB DAC driven by Apple's driver. |
| A client process (helper/daemon) reads our virtual device's loopback and plays to the real device | Yes, and it is the documented architecture | BackgroundMusic and eqMac's classic design, and DTS's *"your control app would need to manage audio routing"*. But that process *reads audio from a device*, which is what design A wanted to avoid. Whether reading a **virtual** device's input stream shows the macOS 14+ indicator (microphone vs. system-audio-recording) is for another slice. It is an input device, so assume the mic path applies unless measured. |
| Core Audio **process tap** + aggregate (what `eq` does now) | **Yes, Apple's recommendation** | Apple staff, thread 775341: *"you might consider using a Core Audio tap instead."* Requires `NSAudioCaptureUsageDescription`; the system prompts for *"system audio recording permission"* (*Capturing system audio with Core Audio taps* sample). This route carries the Privacy indicator. |
| AudioDriverKit dext for a virtual EQ device | **No** | *"entitlements will not be granted for that kind of use case"* (WWDC21 10190; thread 736357). |

### Bluetooth outputs specifically

- **Bluetooth output is not a kernel device a third party can open.** On macOS 26 every
  BT audio route is published by Apple's own ASP,
  `/System/Library/Audio/Plug-Ins/HAL/BTAudioHALPlugin.driver` [observed]. It runs
  in-process in `coreaudiod`, and it feeds `bluetoothd` over a private XPC protocol
  (`BTAudioXpcConnection::…`, A2DP/HFP/LE-Audio message IDs in its strings).
- **No public or DriverKit hook reaches it.** There is no public API for injecting PCM
  into the A2DP encoder path. DriverKit has no Bluetooth-audio transport family. IOBluetooth
  exposes L2CAP, but `bluetoothd` owns AVDTP/A2DP for paired sinks. **[inferred]**
  Re-implementing A2DP (SBC/AAC encode + AVDTP) in user space against a device macOS is
  already connected to is neither sanctioned nor practical.
- **The only public way to put audio on a BT speaker is to be a HAL client of the BT
  device.** That means an ordinary process: a tap engine, AUHAL, or `AVAudioEngine`. It
  is exactly what a plug-in may not be.

---

## 5. Verdict for design A

- **Rules.** Design A requires the one thing Apple's header, QA1811 and DTS all forbid:
  HAL client calls, specifically real-device IO, from inside an AudioServerPlugIn. Apple
  kept that rule when it moved plug-ins into per-driver helper processes in macOS 11. So
  the rule is about re-entrancy into `coreaudiod`, not about sharing an address space.
- **What we would inherit.**
  - A cross-process lock-order hazard with no watchdog on macOS.
  - A two-clock ring buffer that Proxy Audio Device has not got stable in five years.
  - A kernel-free but `coreaudiod`-wide blast radius when it hangs.
  - A dependency on an unenforced rule staying unenforced.
- **Bluetooth.** For BT speakers there is no lower, sanctioned path. The BT device *is* an
  Apple plug-in behind private XPC.
- **What Apple sanctions for "EQ the system output":** a process tap (today's design, with
  the indicator), or a virtual device plus a separate client process that plays it out
  (also a reading process). There is no sanctioned design in which no process reads audio
  and the output reaches a device that someone else's driver owns.

## Sources

Apple, primary:

- SDK header `CoreAudio.framework/Headers/AudioServerPlugIn.h` (macOS 26.6 SDK, lines
  21–103, 305–345, 460–588); older SDKs via
  <https://github.com/phracker/MacOSX-SDKs> (10.9, 10.11, 10.15, 11.0, 11.1, 11.3)
- `CoreAudio.framework/Headers/AudioHardware.h:691–707` (`kAudioPlugInCreateAggregateDevice`)
- QA1811: <https://developer.apple.com/library/archive/qa/qa1811/_index.html>
- Core Audio Overview, HAL Services:
  <https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/WhatsinCoreAudio/WhatsinCoreAudio.html>
- Creating an Audio Server Driver Plug-in:
  <https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in>
- Building an Audio Server Plug-in and Driver Extension:
  <https://developer.apple.com/documentation/coreaudio/building-an-audio-server-plug-in-and-driver-extension>
- Capturing system audio with Core Audio taps:
  <https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps>
- WWDC21 10190: <https://developer.apple.com/videos/play/wwdc2021/10190/>
- Forums, Apple staff: <https://developer.apple.com/forums/thread/689617>,
  <https://developer.apple.com/forums/thread/775341>,
  <https://developer.apple.com/forums/thread/736357>,
  <https://developer.apple.com/forums/thread/653571>; unanswered:
  <https://developer.apple.com/forums/thread/129737>,
  <https://developer.apple.com/forums/thread/22659>,
  <https://developer.apple.com/forums/thread/666120>

This machine, read-only:

- `/System/Library/Sandbox/Profiles/com.apple.audio.coreaudiod.sb`
- `CoreAudio.framework/Versions/A/XPCServices/com.apple.audio.Core-Audio-Driver-Service{,.helper}.xpc`
  (Info.plist, entitlements, symbols, strings)
- `/System/Library/Audio/Plug-Ins/HAL/BTAudioHALPlugin.driver/Contents/Info.plist`
- `log show` for `coreaudiod` (`HALS_RemotePlugInRegistrar`, `HALS_System.cpp:5839`)
- strings from `dyld_shared_cache_arm64e.01` (`HALS_*` symbols)
- `sandbox_check()` probe against PIDs 96715 and 96724

Third party:

- Proxy Audio Device: <https://github.com/briankendall/proxy-audio-device>
  (`ProxyAudioDevice.cpp:4933–4945`; issues
  [#6](https://github.com/briankendall/proxy-audio-device/issues/6),
  [#14](https://github.com/briankendall/proxy-audio-device/issues/14),
  [#19](https://github.com/briankendall/proxy-audio-device/issues/19),
  [#62](https://github.com/briankendall/proxy-audio-device/issues/62))
- BackgroundMusic `DEVELOPING.md` and `BGM_Object.h`; libASPL `README.md` §Sandboxing

Not retrieved (gap): lists.apple.com coreaudio-api 2013/Aug/msg00030 (HTTP 502) and any
Jeff Moore or Doug Wyatt explanation of the rationale.
