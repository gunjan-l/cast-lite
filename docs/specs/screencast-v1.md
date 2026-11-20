# Spec: Cast-Lite v1 — screencast to Android TV and browser

Status: ready-for-agent
Supersedes: `android-tv-screen-mirroring.md` (this spec keeps its root-cause analysis and pipeline design, and records the v1 pivot decisions on top of it)

## Problem Statement

Cast-Lite tries to do four things at once: screen mirroring, camera-roll casting, a web video caster, and a subscription paywall. None of it works end to end. A user picks their Android TV, the app says "Streaming Active", and the TV shows nothing. Sometimes the app sits on "Connecting..." forever, and sometimes the same TV appears twice in the device list and one entry never works. The app reports success even when the TV rejected the stream, so the user can't tell what went wrong.

Underneath, nothing the TV receives is playable. The broadcast extension sends a placeholder instead of encoded video. The stream server serves hand-written H.264 bytes that no decoder accepts. And the server lives in the main app, which iOS suspends as soon as the user switches to the app they want to show.

The developer has no Mac and installs the app by sideloading, so when mirroring fails on the phone there is no console to look at and no way to find out why.

## Solution

Cast-Lite v1 does one thing: mirror the iPhone screen.

The user opens the app, picks their Android TV (or no TV), and taps the system broadcast button. Within a few seconds the iPhone screen appears on the TV, and the same stream can be watched in any web browser on the same Wi-Fi at the address the app shows. The mirror keeps running while the user switches to other apps. When something fails, the app shows a specific reason (TV unreachable, Local Network permission missing, TV rejected the stream, TV session ended from the remote) instead of claiming success. Each TV appears once in the device list.

The whole live pipeline runs inside the broadcast extension, which iOS keeps alive for the broadcast: screen capture, H.264 encoding, HLS segmenting, the HTTP server, and the Cast session with the TV. The main app handles discovery, device selection, and status, and hands the selected TV to the extension through shared storage. That handoff still works after the app is sideloaded and re-signed. If it breaks, the mirror falls back instead of failing.

Camera-roll casting, the web video caster, and the paywall are hidden for v1. Their code stays and keeps compiling.

## User Stories

### Picking a target
1. As an iPhone user, I want my Android TV to appear in the device list, so that I can pick it as a mirroring target.
2. As an iPhone user, I want each TV to appear only once, so that I don't pick an entry that can't mirror.
3. As an iPhone user, I want the device list to show the TV's friendly name (for example "Living Room TV"), so that I can tell my TVs apart.
4. As an iPhone user, I want TVs that have left the network to disappear from the list, so that I don't select a dead entry.
5. As an iPhone user, I want the currently selected TV highlighted, so that I never stream to the wrong room.
6. As an iPhone user, I want selecting the same TV again to do nothing disruptive, so that an accidental tap doesn't break a running mirror.
7. As an iPhone user, I want to switch to a different TV without restarting the app, so that I can move the mirror between rooms.
8. As an iPhone user, I want to start mirroring without picking any TV, so that I can show my screen in a browser only.

### Starting and running the mirror
9. As an iPhone user, I want to start mirroring with the system broadcast button inside the app, so that I use the familiar iOS screen-recording flow.
10. As an iPhone user, I want selecting a TV to only prepare the mirror, not start it, so that nothing is broadcast until I tap the broadcast button.
11. As an iPhone user, I want my screen to appear on the TV within a few seconds of starting the broadcast, so that mirroring feels responsive.
12. As an iPhone user, I want the mirror to keep running when I switch to another app, so that I can show any app on the TV.
13. As an iPhone user, I want the picture to stay steady when I rotate the phone, so that the TV never freezes or goes black on rotation.
14. As an iPhone user, I want landscape content to fill the TV and portrait content to show with black bars at the sides, so that both orientations display correctly.
15. As an iPhone user, I want the picture on the TV to be sharp enough to read text, so that presentations and documents are usable.
16. As an iPhone user, I want to choose between a higher-quality mode and a lower-bandwidth mode, so that I can trade sharpness for reliability on a weak network.
17. As an iPhone user, I want mirroring to stop on the TV when I stop the broadcast, so that the TV doesn't keep showing a frozen frame.
18. As an iPhone user, I want the mirror to recover by itself from a brief Wi-Fi drop, so that a momentary blip doesn't end my session.
19. As an iPhone user, I want mirroring not to drain the battery or overheat the phone excessively, so that I can mirror for a whole movie or meeting.
20. As an iPhone user, I want the broadcast never to crash from memory pressure, so that the mirror doesn't silently die mid-session.

### Browser viewer
21. As an iPhone user with a PC or Mac, I want to open a local web address in Chrome, Edge, or Safari and see my iPhone screen, so that I can present without any TV.
22. As an iPhone user, I want the app to show the browser address while mirroring, so that I know what to type on the computer.
23. As an iPhone user, I want the browser viewer to work on a Wi-Fi network without internet access, so that I can present in places with a closed LAN.
24. As an iPhone user, I want the browser viewer and the TV to show the same stream at the same time, so that I can mirror to both.
25. As an iPhone user, I want the browser page to show a clear "waiting for stream" state before the first video arrives, so that I know it isn't broken.

### Errors and status
26. As an iPhone user, I want the status indicator to reflect what the TV is actually doing (connecting, launching, loading, buffering, playing, ended, failed), so that I can trust it.
27. As an iPhone user, I want a clear error if my iPhone and TV aren't on the same network, so that I know what to fix.
28. As an iPhone user, I want to be asked for Local Network permission when I first open the app, with an explanation beforehand, so that I don't hit the prompt mid-broadcast.
29. As an iPhone user, I want a clear error if Local Network permission is denied, with a way to open Settings, so that I can grant it.
30. As an iPhone user, I want connecting to give up with a message after a reasonable time, so that the app never hangs on "Connecting...".
31. As an iPhone user, I want a clear error if the TV refuses to play the stream, so that I don't stare at a blank TV while the app says "Streaming Active".
32. As an iPhone user, I want the app to tell me when the TV session was ended from the TV (for example someone pressed Back on the remote), so that I know why mirroring stopped.
33. As an iPhone user whose iPhone has no Wi-Fi address, I want an explicit error instead of a broken address sent to the TV, so that I understand mirroring can't work.
34. As an iPhone user, I want errors to stay visible until something actually fixes them, so that an unrelated success doesn't hide the reason the mirror failed.

### Sideloaded installs
35. As a user who sideloads the app with AltStore or SideStore, I want the app and the broadcast to share the selected TV even though re-signing renamed the shared storage, so that mirroring works after install.
36. As a user whose shared storage could not be opened, I want the broadcast to find my TV on its own when there is exactly one, so that the mirror still reaches the TV.
37. As a user whose shared storage could not be opened and who has several TVs, I want the broadcast to run browser-only and say why, so that I still get a mirror and know what to fix.

### Scope for v1
38. As an iPhone user, I want the app to show only what works in v1 (mirroring and settings), so that I'm not led into unfinished camera-roll or web casting features.
39. As an iPhone user, I want mirroring to be free for now, so that I can try it before a paywall exists.

### Developer and QA
40. As a developer, I want to run the whole stream pipeline on Linux in podman (encoded frames in, browser page, HLS over HTTP, and Cast messages out), so that I can verify it without a Mac or a TV.
41. As a developer, I want an automated check that decodes the served HLS stream with ffmpeg and fails on any decode error, so that a regression to unplayable output is caught.
42. As a developer, I want the Cast session tested against a scripted Android TV receiver, so that connect, launch, load, failure, remote stop, and disconnect paths are covered without hardware.
43. As a developer, I want the handoff fallback rules (selected TV, one discovered TV, several or none) tested without a device, so that the sideload path doesn't regress.
44. As a developer, I want failures typed and propagated instead of swallowed, so that I can diagnose problems from logs and tests.
45. As a developer, I want one type that owns the mirror session lifecycle, so that I don't have to trace state across the app, the coordinator, and the extension.
46. As a developer without a Mac, I want a debug endpoint on the phone that I can open from a PC browser during a broadcast, so that I can see the phase, stream address, segment count, last error, and handoff source while the main app is suspended.
47. As a developer without a Mac, I want the extension to keep a rolling log file that the app can show and export through the share sheet, so that I can read what happened after a failed broadcast.
48. As a QA tester, I want a debug view in the app showing the stream address and current segment count, so that I can confirm the server is producing segments while testing on the device.

## Implementation Decisions

### Scope and app shell
- The tab bar shows Mirror and Settings only. The Cast tab (camera roll, web browser, web video detector) is removed from the tab bar. Its views, the web video detector, and byte-range media serving stay in the build and their tests keep running.
- The entitlement check is removed from the mirror path. The paywall modal and the Settings premium and restore entry points are hidden. The subscription manager and its tests stay.
- Auto-starting the mirror when a device is selected is removed. Selecting a device only writes the handoff. The user starts mirroring with the broadcast button.
- Errors are cleared only by the event that resolves them, not by an unrelated successful step. Silent `try?` on the mirror path is replaced with surfaced, typed errors.
- On launch the app browses for `_googlecast._tcp`, so the Local Network prompt appears (after the existing explanation modal) before the first broadcast. App extensions share the containing app's Local Network permission (Apple TN3179). The usage description and Bonjour services keys belong to the app, not the extension.

### Process ownership
- The broadcast extension owns the live pipeline for the whole broadcast: capture, encoding, segmenting, the HTTP server, and the Cast session. Nothing on the live path depends on the main app, which iOS suspends.
- The main app owns discovery, device selection, the handoff write, and the status display.
- The loopback IPC channel between the extension and the main app is deleted, together with the most recent commit that started its server, hard-coded H.264 parameter sets, and auto-started mirroring. That commit is reverted first.

### MirrorSession (new, platform-neutral, the single test seam)
- One type, `MirrorSession`, owns the lifecycle of a broadcast. It builds on `MirrorStream` and the Cast session coordinator. The broadcast extension holds one `MirrorSession` and stays thin: sample buffer in, access unit out, forwarded to the session.
- Inputs:
  - a handoff value: a selected device (id, name, IP, port, type), or none, plus the quality mode
  - a discovery fallback, injected, that returns the Chromecast devices currently visible on the network
  - a Cast transport factory, injected (the existing coordinator already takes one)
  - access units, appended as they come out of the encoder
- Outputs a person or a TV could observe:
  - HTTP routes on the bound port: `/view`, `/hls.js`, `/stream.m3u8`, segment files, `/debug`
  - Cast V2 messages sent to the receiver
  - a status snapshot: phase, stream URL, segment count, last error, handoff source
- Target resolution rules, applied at start:
  - a selected device in the handoff means cast to it
  - "none selected" in the handoff means browser-only
  - no handoff readable at all means: if the discovery fallback returns exactly one TV, cast to it; otherwise run browser-only with handoff source "no handoff"
- The HTTP server and stream start before the Cast session and stay up whatever the Cast outcome is, so a Cast failure never takes down the browser viewer.
- Stop sends STOP to the media session, closes the receiver app the session launched, stops the server, and moves to ended.

### Stream pipeline (`MirrorStream`, platform-neutral)
- `MirrorStream` replaces the current stream controller for live mirroring. Interface: start (returns the bound port), append access unit, stop, status snapshot. It owns the TS muxer, the segmenter, and the stream HTTP routes.
- An access unit is a value type: Annex-B data, PTS in 90 kHz ticks, and a keyframe flag. The 90 kHz unit is part of the type, so microseconds and 90 kHz ticks can't be mixed up.
- TS muxer: an AUD NAL on each access unit, PCR on keyframe packets, PAT and PMT at the start of every segment, a video-only PMT, and continuity counters that carry across segments.
- Segmenter: cuts only at keyframes, segment duration comes from PTS deltas, target duration is the ceiling of the longest segment, a 6-segment window, and segments older than the window are released.
- The playlist is not served until the first complete segment exists.
- `/view` serves a small HTML page. It plays `/stream.m3u8` natively where the browser supports HLS, and otherwise uses `hls.js` served from `/hls.js`, a copy bundled with the extension, so no internet is needed. The page shows "waiting for stream" until the playlist is available.
- The fake MJPEG `/stream` and `/frame` routes and the test-pattern viewer are removed from the live path. A test pattern may stay only in the Linux demo server, and only if a real encoder generated it.
- HTTP server: per-connection handling moves off the actor, so a slow request can't stall other requests or block stop. CORS stays `*`.
- Stream URL resolution fails with a typed error when there is no Wi-Fi IPv4 address, instead of falling back to `localhost`.

### Encoder (extension, iOS only)
- VideoToolbox real-time H.264, Main profile, no B-frames, a keyframe every second.
- The output is always 1280x720 landscape. Portrait frames are scaled to fit, with black bars at the sides. The output size never changes during a broadcast, so the stream never needs a discontinuity.
- About 4 Mbps in the higher-quality mode and about 2 Mbps in the lower-bandwidth mode. This maps onto the existing quality picker.
- On keyframes the encoder emits Annex-B access units with SPS and PPS prepended, taken from the encoder's format description. PTS comes from the sample buffer timestamp, converted to 90 kHz.
- The existing memory guard stays and drops frames above 45 MB.

### Handoff (app and extension, iOS only)
- Shared storage is an App Group. Its identifier is read at runtime from the `ALTAppGroups` Info.plist key, which AltStore and SideStore write after renaming the group to `<group>.<teamID>`. The build-time identifier is the fallback.
- Before a broadcast the app writes the handoff: the selected device or none, and the quality mode. The extension writes its status (phase, stream URL, segment count, last error, handoff source) back, and posts a Darwin notification so the app refreshes.
- The extension appends to a rolling log file in the same group, capped in size. The app shows it and can export it through the share sheet. If the group isn't available, `/debug` is the only diagnostic, and it says so.
- Reading and writing the group is thin glue around `MirrorSession`. All decisions about what to do with the handoff live inside `MirrorSession`.

### Cast session (Android TV / Chromecast built-in)
- The coordinator becomes an explicit state machine. Phases: idle, connecting, launching, loading, buffering, playing, ended(reason), failed(error). The app's status UI and `/debug` are rendered from this phase.
- Connect times out after about 8 seconds. The transport treats `.waiting` as a failure with its underlying reason, so missing Local Network permission becomes a typed error instead of a hang.
- The DIAL fallbacks are removed. A Cast V2 failure shows up as a failure, never as success.
- LOAD uses the Default Media Receiver with streamType `LIVE`, contentType `application/x-mpegURL`, and `hlsVideoSegmentFormat` `mpeg2_ts`. `LOAD_FAILED`, `INVALID_REQUEST`, and a MEDIA_STATUS with idleReason `ERROR` all become failed, carrying the receiver's reason.
- Unsolicited MEDIA_STATUS updates move the phase (buffering, playing, idle). A CLOSE from the receiver on the connection namespace ends the session with reason "stopped on TV".
- Reconnecting after an unexpected disconnect stays, with a bounded number of attempts.

### Discovery
- Device identity is the stable id only. Equality and hashing use `id`, not `lastSeen` or `name`.
- An SSDP entry whose IP matches a Chromecast entry is suppressed, so an Android TV appears once, as Chromecast.
- Chromecast entries are removed when Bonjour removes the service, and are pruned by staleness like other devices.
- Re-selecting the same device does nothing. Selecting several devices quickly cancels the earlier in-flight work.

## Testing Decisions

### What makes a good test
A good test drives the system through `MirrorSession`'s public interface and checks what a person or the TV would see:
- bytes served over HTTP decode into video
- `/view` loads, and references the playlist and `/hls.js`
- the receiver got a LOAD for the right URL
- the session reached failed with the receiver's reason
- the status snapshot reports the handoff source

Tests don't check internal fields, the order of calls inside a module, or the output of private helpers.

### The seam: `MirrorSession`
This is the only test seam. It is platform-neutral and runs on Linux in podman. Everything below the VideoToolbox encoder and above the network goes through it.

- **Decode harness (local script, podman):**
  - ffmpeg generates a real H.264 elementary stream: 1-second GOP, no B-frames, 1280x720, a few seconds of test source.
  - A small CLI splits it into access units with 90 kHz PTS and feeds them to `MirrorSession` (no handoff, so browser-only) at real-time pace.
  - A sibling ffmpeg container fetches the playlist and segments over the container network and decodes them.
  - The check fails on any decoder error, on a frame count far below what was expected, or on PTS that ever goes backwards.
  - The script is in the repo so a reviewer can rerun it. It runs locally only; there is no CI job until the work is pushed.
- **Stream behaviour (XCTest in podman):**
  - the playlist isn't served before the first segment
  - segments are cut only at keyframes
  - target duration matches the longest segment
  - the window slides and old segments disappear
  - `/view` and `/hls.js` are served with the right content types
  - `/debug` reports the segment count and phase
  - the fake MJPEG and frame routes are gone
- **Cast behaviour (XCTest, scripted receiver through the existing mock Cast transport):**
  - the happy path reaches playing
  - `LOAD_FAILED` reaches failed with the reason
  - MEDIA_STATUS with idleReason `ERROR` reaches failed
  - a receiver CLOSE reaches ended("stopped on TV")
  - a connect timeout reaches failed within the timeout
  - transport `.waiting` reaches failed with a permission error
  - a Cast failure leaves the HTTP routes serving
  - stop sends STOP and closes the receiver app
- **Handoff behaviour (XCTest, injected discovery fallback):**
  - a selected device casts to it
  - "none selected" is browser-only and sends no CONNECT
  - no handoff plus exactly one discovered TV casts to it
  - no handoff plus zero or several TVs is browser-only, with handoff source "no handoff"
- **Prior art:** the existing coordinator, Cast V2 client, and Cast transport tests already script the mock transport this way, and the coordinator already takes an injected transport factory. The HTTP server tests already hit routes over real loopback sockets. Extend these, and delete the tests that assert the DIAL fallback or IPC behaviour.

### Discovery
Discovery identity and dedup rules stay covered by the existing discovery tests, which are updated for id-based equality and the SSDP-over-Chromecast suppression. This isn't a new seam.

### Verified on the device only
The VideoToolbox encoder, ReplayKit lifecycle, App Group identifier lookup, and Local Network prompt only compile or behave on iOS. They stay thin.

Checks on the device, in order:
1. A PC browser shows the live iPhone screen at `/view`, and `/debug` shows the segment count rising.
2. The Android TV shows the mirror, and the app's status reaches playing.
3. Stopping the broadcast stops the TV.
4. With the shared storage removed, the single-TV fallback still mirrors.

## Out of Scope

- Audio. The PMT carries video only.
- Sub-second latency. HLS gives roughly 3 to 6 seconds of delay. Low-latency HLS, WebRTC, and a custom Cast receiver are follow-ups.
- Following the phone's orientation, and changing resolution mid-stream.
- Roku, DLNA, Samsung, and LG targets. Their code stays and is changed only where shared types change (device equality).
- Camera-roll photo and video casting, the in-app web browser, and the web video detector. They're hidden, not deleted.
- The paywall, StoreKit purchase flows, and gating mirroring behind a subscription.
- Signed CI builds, TestFlight, and App Store distribution. Installs are sideloaded with AltStore or SideStore. Sideloadly's handling of App Groups is unverified and isn't supported.
- A CI job for the decode harness.
- The multicast networking entitlement for SSDP.
- Replacing the self-signed certificate bypass on the Cast TLS connection.
- An Android sender app or an Android TV receiver app.

## Further Notes

- Evidence for the current failure: decoding a segment from the existing server with ffmpeg gives `Overread SPS by 4 bits`, `QP 4294966235 out of range`, `decode_slice_header error`, and `Conversion failed!`. The SPS parses as 640x1450.
- Sideload facts:
  - AltStore's source renames each App Group to `<group>.<teamID>` and writes the result into Info.plist under `ALTAppGroups`, for the app and every extension. Free Apple IDs get this too.
  - SideStore is a fork of AltStore and is assumed to behave the same. This is unverified.
  - With a free Apple ID, the app plus the extension use 2 of the 10 App IDs allowed per week, and installs expire after 7 days.
- An assumption to check on the device: the Default Media Receiver keeps playing HLS while the sender's TLS connection stays open from the extension.
- Extension memory budget: the encoder, a 6-segment window at 2 to 4 Mbps (roughly 3 to 6 MB), the bundled `hls.js` read from disk on request, and the Cast client should all fit well under 50 MB.
- Delivery: all work stays on the local branch `screencast-v1` and is never pushed. The order:
  1. Track this spec.
  2. Revert the IPC/auto-start commit.
  3. Hide the Cast tab and the paywall.
  4. `MirrorStream` fixes, `MirrorSession`, and the decode harness. These can be checked on Linux.
  5. Stop and decide how iOS builds get made. CI only builds pushed commits, and there is no Mac.
  6. Then: the encoder and the extension hosting the session, the handoff and logs, the Cast state machine, discovery fixes, and deleting the IPC code.
