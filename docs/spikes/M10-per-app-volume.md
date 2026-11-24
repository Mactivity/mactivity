# M10 spike: per-app volume with Core Audio process taps

2026-09-25 · MacBook Pro M5 Pro (Mac17,9), macOS 27.0, Xcode 27.0, Swift 6.4 · built-in speakers at 48 kHz

## Recommendation

**Ship behind a flag, off by default** ("Per-app volume (beta)" in Settings), and don't count it toward M10's done-when until one manual pass in the signed app with consent granted (checklist at the end).

Why not a plain ship:

- I couldn't verify the path that matters: consent granted, the app muted, and its audio played back at the gain. Tests run under Claude Code, which has no `NSAudioCaptureUsageDescription`, so TCC refused audio capture without showing a prompt. Every other path was verified live (list below).
- A tap without consent is dangerous. It still mutes the app, but it delivers exact zeros, so a naive implementation would silence the app instead of turning it down. The design handles this (below), but the handling depends on a behavior I saw only on the denied side.
- It costs something while it's on. Mactivity itself stays under the budget (about 0.09% of a core per active tap), but coreaudiod does more work, between +0.5% and +3.5% of a core per tap.

Why not a documented no: everything uses public API, the Core Audio object lifecycle works and is tested live, and nothing needs admin rights or a HAL plug-in. The HAL plug-in alternative in spec 6.11 isn't worth its weight unless the consent path fails in the signed app.

## How it works

`CoreAudioSource` (actor, `Sources/Audio/`) implements `AudioSource`. Each process turned below 1.0 gets a `TapRig`:

1. A **private process tap**: `CATapDescription(stereoMixdownOfProcesses: [processObject])`, `isPrivate = true`.
2. A **private aggregate device**. The default output device is its main sub-device and clock, the tap is its only input (`kAudioAggregateDeviceTapListKey`, drift compensation on, `tapautostart` on).
3. An **IOProc**, a C function pointer (`AudioDeviceCreateIOProcID`, not the block variant) that gets a heap-allocated `RenderState` as client data. Each cycle it copies the tap's input × gain to the output. The gain is ramped across one buffer, so slider moves don't click.

Real-time safety: the IOProc does no allocation, takes no locks, and uses no Swift concurrency, ARC, or logging. `RenderState` is a `~Copyable` struct of `Synchronization.Atomic`s (target gain as `Float` bits, current gain, active flag, heard-signal flag, cycle count), all read and written with relaxed ordering. `Atomic` compiles for macOS 26. `GainKernel` handles interleaved and deinterleaved Float32 on both sides and maps stereo to mono (L+R average), mono to stereo (duplicate), and stereo to more than two channels (the extra channels are silent). The rig refuses to build if the aggregate's output streams aren't 32-bit float linear PCM.

### Consent

This was the spike's main finding. The Core Audio log from the first live run showed two things:

- `tccd` checked `kTCCServiceAudioCapture` when the tap was created and again when IO started. It then refused the request, because the responsible app (Claude Code) has no `NSAudioCaptureUsageDescription`.
- `coreaudiod` still ran `HALS_Client::AddMuter: Process afplay muted by probe`, and the tap delivered exact zeros (peak 0.0 over 468 cycles).

So **a denied tap mutes the app and hands back silence.** There is no public API that says whether consent is granted. TCC's preflight SPI is private (see "Private API" below). So `CoreAudioSource` proves consent from the audio itself:

- Until any tap has heard real audio this session, a new tap is built **unmuted** (`.unmuted`). Its IOProc writes silence, so the app keeps playing as normal. The IOProc sets `heardSignal` the first time it sees a non-zero input sample.
- If signal arrives within `probeWindow` (1.5 s), consent is confirmed. The rig is **rebuilt** with `.mutedWhenTapped` and the gain applies. The new tap starts reading before the old one is destroyed, so there's no gap and no doubled audio. After that, new taps mute from the start.
- If nothing arrives within the window while the process still reports `IsRunningOutput`, the tap is torn down and `setVolume` throws `AudioVolumeError.permissionDenied`. If the app stopped playing during the window, IO stops and probing resumes when it plays again.

The false-positive case: an app that keeps its output running but sends pure digital zeros for the whole window, such as a paused browser tab. That case reports `.permissionDenied`. The UI copy should cover both causes. Suggested: "Mactivity can't hear *App*. Allow Mactivity under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then try again while it's playing."

Undetermined consent: the first tap triggers the system prompt. The probe will probably time out while the prompt is up and throw `.permissionDenied`. After the user allows, the next slider move works. Not verified; see the checklist.

I first tried promoting the live tap by setting `kAudioTapPropertyDescription` (the header says it's settable, and `AudioObjectIsPropertySettable` returns true). It failed with `'!hog'` (`kAudioDevicePermissionsError`), both running and stopped. That may be another effect of missing consent. Rebuilding avoids the question.

### Lifecycle

- **1.0** tears the tap down. **0** mutes (gain 0).
- **Default output changes**: a listener on `kAudioHardwarePropertyDefaultOutputDevice` rebuilds every rig on the new device, keeping gain and mute state.
- **Process exits**: a listener on `kAudioHardwarePropertyProcessObjectList` tears its rig down. `clients()` also reconciles.
- **App goes quiet**: a listener on the process's `kAudioProcessPropertyIsRunningOutput` stops the aggregate's IO, so the output device can idle, and restarts it when the app plays again.
- **`reset()`** (call on quit) destroys every IOProc, aggregate device, and tap, and removes every listener. `RigTable.deinit` does the same if the source is dropped without `reset()`. Taps and aggregates are private, so the HAL also destroys them if Mactivity crashes, and no app is left muted.
- Destruction is asynchronous in the HAL. The tap and aggregate leave `kAudioHardwarePropertyTapList` / `kAudioHardwarePropertyDevices` within 0–60 ms of the destroy calls.

## Verified live vs. only built

| Behavior | Status |
|---|---|
| `clients()` on this Mac: process list, PID, bundle ID, `IsRunningOutput`; Mactivity excluded | **Live** (runs in the default test pass) |
| Unknown pid and own pid → `.processNotFound`, nothing created | **Live** (default test pass) |
| Tap + aggregate + IOProc build and start; IOProc runs (42 cycles in the first 0.5 s; 512 frames at 48 kHz is 94/s) | **Live** (`MACTIVITY_AUDIO_LIVE=1`) |
| Tap format: 48 kHz, 2 ch, Float32, packed interleaved (flags 9); output buffers stereo interleaved | **Live** |
| No consent → probe times out → `.permissionDenied`, tap torn down, app not left muted | **Live** |
| Unmuted probe tap reports `.unmuted`; promotion rebuild reports `.mutedWhenTapped` (read back from `kAudioTapPropertyDescription`) | **Live** |
| Gain update in place on a running tap | **Live** (target gain in `RenderState`) |
| Rebuild on an output-device change (forced on the same device, keeps gain and mute) | **Live**, via `moveTaps(to:force:)` |
| Process exit → the process-list listener tears the rig down, no `clients()` call needed | **Live** (afplay ends on its own) |
| `reset()` removes the tap and aggregate from the HAL | **Live** |
| Gain math over interleaved/deinterleaved fixtures, at 0, 0.5, 1, and clamped values; channel mapping; ramp | Unit tests (fixtures) |
| **With consent:** signal detected, app muted, audio played back at the gain, other apps unaffected | **Not verified.** Needs the signed app (checklist) |
| The real default-output-device listener firing (switching to headphones or AirPlay) | Built only. Changing the output device is the user's setting, and I didn't touch it |
| `IsRunningOutput` stop/restart on pause and resume | Built only |
| Undetermined → prompt → allow | Not verified |

## Cost and latency

Measured with the live test (`swift test -c release -Xswiftc -enable-testing`, one active tap on afplay playing a 48 kHz tone) and a scratch probe for 10 s coreaudiod windows:

| | CPU (% of one core) |
|---|---|
| Mactivity, one active tap, release build | **0.088–0.099%** (three runs; one outlier at 0.36%) |
| Mactivity, one active tap, debug build | 2.5–2.7% (unoptimized per-sample loop; don't judge by this) |
| Scratch probe (same IOProc work, `-O`) | 0.077–0.16% |
| coreaudiod, afplay alone, 10 s | 4.9–5.0% |
| coreaudiod, afplay + one tap, 10 s (the window includes 1 s before the tap) | 8.2–8.4%, so about **+3.3%** |
| coreaudiod, 2 s windows in the live test | +0.5 to +2.5% (`ps` resolution is 10 ms, so noisy) |

Drift compensation off made no measurable difference to coreaudiod (8.2% vs 8.4%). Per-tap cost is paid only while that app is playing, because IO stops when it goes quiet. An app left at 1.0 costs nothing. Before shipping, measure in Instruments with real consent and a real app (Music, a browser).

**Latency.** The aggregate device's figures: buffer 512 frames, input latency 33 + safety offset 48, output latency 60 + safety offset 48, all at 48 kHz. The tapped audio arrives on the aggregate's input side and goes out one IO buffer later. The output device's own latency applies either way, so the added latency ≈ input latency + input safety offset + one buffer = **593 frames ≈ 12.4 ms**. That's fine for music and video. It can matter for games and rhythm apps, and A/V sync is off by the same 12 ms. Lowering `kAudioDevicePropertyBufferFrameSize` on the aggregate to 256 would take about 5 ms off at some CPU cost. Not tried.

## Known limits

- **Consent can't be preflighted with public API**, and a denied tap mutes the app. This is handled by the unmuted probe. If consent is revoked mid-session after a tap has proven it, later taps would mute straight to silence until relaunch. That's rare, but real.
- **Digital silence reads as no consent** during the probe window (above).
- **Hog / exclusive mode**: an app that hogs the output device (`kAudioDevicePropertyHogMode`, some pro audio apps) blocks the aggregate from using that device. The rig build or start fails and surfaces as `.coreAudio(status)`. Not tested.
- **Apps that pick their own output device** (DAWs, Zoom or Teams set to a headset, Music with AirPlay): the stereo mixdown tap captures the process's audio from every device, but Mactivity plays it on the *default* output. Turning such an app down moves its audio to the default device. A fix would read `kAudioProcessPropertyDevices` (output scope) and use that device as the aggregate's main sub-device.
- **AirPlay and Bluetooth outputs**: the aggregate follows the default device, including AirPlay, which adds its own ~2 s latency. The added 12 ms still applies on top. Rebuilding on a device switch causes a brief full-volume blip for tapped apps, because the old tap stops reading before the new one starts. Not tested live.
- **Multichannel apps** are mixed down to stereo (`stereoMixdownOfProcesses`). 5.1 content loses its surround channels while turned down.
- **Resume blip**: when a quiet, tapped app starts playing again, the first few milliseconds (until the `IsRunningOutput` listener restarts IO) play at full volume.
- **Helpers**: browsers play audio from a helper process (`com.apple.WebKit.GPU`, `com.google.Chrome.helper`). The client list returns helpers by pid and bundle ID, and the app maps them to the parent app. One app can have several audio pids; the UI should set them all together.
- **Sample-rate or format changes** on the output device mid-stream aren't listened for. The kernel reads buffer sizes and channel counts every cycle, so it stays correct, but a non-Float32 virtual format after a change isn't detected until the next rebuild.

## Private API

None used. The one symbol that would help is **`TCCAccessPreflight(kTCCServiceAudioCapture, nil)`** in the private `TCC.framework`. It answers granted, denied, or undetermined without making any audio. If we want it, it goes in `Sources/PrivateAPIs` behind a wrapper, with the signal probe as the public fallback (CLAUDE.md rule 2). It would stop the digital-silence false positive, and it would let the UI show "Allow in Settings" before the user moves a slider. I don't think it's needed for the beta.

## Toolchain issues found (Swift 6.4)

- A stored `UUID` field in `TapRig` made the compiler-generated value witness trap (`storeEnumTagSinglePayload for TapRig`, `brk #1`) whenever an `Optional<TapRig>` was set to `nil`. I saw it first in an `isolated deinit` and then in `rigs.removeValue(forKey:)`. Workaround: `TapRig.token` is the tap UUID as a `String`. The render state is also stored as `UnsafeMutableRawPointer` rather than `UnsafeMutablePointer<RenderState>` (a `~Copyable` pointee). Cleanup lives in a plain class's `deinit` (`RigTable`) because a nonisolated actor `deinit` can't touch non-Sendable storage. I didn't isolate whether `isolated deinit` works on its own once the UUID is gone. Worth a minimal repro and a Feedback.

## What the app needs

- **Info.plist**: `NSAudioCaptureUsageDescription` = "Mactivity listens to an app's audio only to change its volume when you move its slider. Nothing is recorded or stored."
- **Entitlements**: none known for a non-sandboxed Developer ID app. Process taps need TCC consent, not an entitlement, and Mactivity never opens the microphone, so `com.apple.security.device.audio-input` shouldn't be needed. Confirm in the first signed, hardened-runtime build.
- **AppModel**: create one `CoreAudioSource()` (Audio target) in place of `SimulatedAudioSource`, and `await reset()` in `applicationWillTerminate`. Map `AudioClient.app` (a bundle ID or `"other:<pid>"`) to identities through the process tree, and group helper pids under their app.
- **UI**: a slider per app. `.permissionDenied` shows the copy above with a button that opens the privacy pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`). `.processNotFound` just drops the row.
- **Package.swift / project.yml**: no change. Audio already depends on Core only, and the new `Synchronization` import is part of the toolchain.

## Manual check with consent (for Kade, signed app)

1. Add the Info.plist key, build and run Mactivity from Xcode, and start music in Music and a video in Safari.
2. Drag Music to 50%. Expect the system prompt. Allow it. Drag again. Music should get quieter and Safari should stay the same (that's M10's done-when).
3. Drag Music to 0: silent. Drag it to 100%: back to normal, and the tap is gone (`log stream --predicate 'subsystem == "app.mactivity.audio"' --info`).
4. Switch output to headphones while Music is at 50%: it should stay at 50% on the headphones.
5. Pause and resume Music: note any blip at resume.
6. Quit Mactivity while Music is at 50%: Music goes back to full volume right away.
7. Deny consent in System Settings, relaunch, and drag a slider: the app keeps playing at full volume and the UI shows the permission message.
