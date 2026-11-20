# Spec: iPhone screen mirroring to Android TV

Status: in-progress (screencast-v1, steps 0–3)
Scope: iOS app (sender) mirroring the iPhone screen to Android TV / Google TV devices with Chromecast built-in, and to a web browser on the same LAN. This is v1 of Cast-Lite: the app ships as screen mirroring only.

## v1 pivot decisions (2026-11-18)

These override the sections below where they conflict.

- **Scope.** Screen mirroring only. The Cast tab (camera roll, web browser, web video detector, byte-range serving) is hidden from the tab bar; its code keeps compiling and its tests keep running.
- **Browser viewer.** The extension's HTTP server always runs during a broadcast and serves `/view`, an HTML page that plays the same HLS stream. Safari plays it natively; other browsers use an `hls.js` copy bundled in the extension and served at `/hls.js`, so no internet access is needed. Starting a broadcast with no TV selected is allowed and means browser-only (replaces user story 21).
- **No entitlement gate.** Monetization waits until mirroring works. The mirror path does not check the subscription, and the paywall and Settings premium/restore entry points are hidden. `SubscriptionManager` and its tests stay (replaces user story 20).
- **Fixed output geometry.** The encoder always produces 1280x720 landscape. Portrait screens show with black bars at the sides. The resolution never changes mid-stream (replaces user story 8's rotation handling).
- **Sideload-safe handoff.** The app is installed by sideloading with AltStore or SideStore, which rename the App Group to `<group>.<teamID>` and record the real name in Info.plist under `ALTAppGroups`. The app and the extension read the group ID from `ALTAppGroups` at runtime and fall back to the hardcoded ID. If the group can't be opened, the extension browses `_googlecast._tcp` itself and casts if it finds exactly one TV; otherwise it runs browser-only and reports "no handoff".
- **Local Network prompt.** The app browses `_googlecast._tcp` on launch so the permission is decided before the first broadcast; extensions share the app's permission (Apple TN3179). `NSLocalNetworkUsageDescription` and `NSBonjourServices` go in the app's Info.plist.
- **Observability without a Mac.** The extension serves `/debug` (phase, stream URL, segment count, last error, handoff source) and writes a rolling log file to the App Group, which the app shows and can export through the share sheet.
- **Stream routes.** The live path serves `/view`, `/hls.js`, `/stream.m3u8`, segments, and `/debug`. The fake MJPEG `/stream` and `/frame` routes are removed from it.
- **Harness.** `scripts/verify-stream.ps1` drives podman locally. No CI job until work is pushed.

## Problem Statement

A user picks their Android TV in Cast-Lite, the app says "Streaming Active", and the TV shows nothing. Sometimes the app sits on "Connecting..." forever. Sometimes the same TV appears twice in the device list and one of the two entries never works. The user cannot tell what went wrong, because the app reports success even when the TV rejected the stream.

Underneath, nothing the TV receives is playable. The broadcast extension sends a 5-byte placeholder instead of encoded video, the stream server pads the playlist with fabricated H.264 bytes that no decoder accepts (confirmed with ffmpeg: `decode_slice_header error`, `Could not find codec parameters`), and the server lives in the main app, which iOS suspends as soon as the user leaves it to show something else on screen.

## Solution

The user selects their Android TV, taps the system broadcast button, and within a few seconds sees their iPhone screen on the TV. The mirror keeps running while they use other apps. When something fails (TV unreachable, local network permission missing, TV rejected the stream), the app shows a specific message instead of claiming success. Each physical TV appears once in the device list.

The live pipeline (screen capture, H.264 encoding, HLS segmenting, HTTP serving, and the Cast session that tells the TV to play) runs entirely inside the broadcast upload extension, which iOS keeps alive for the whole broadcast. The main app handles discovery, device selection, entitlement, and status display, and hands the selected device to the extension through a shared App Group.

## User Stories

1. As an iPhone user, I want my Android TV to appear in the device list, so that I can pick it as a mirroring target.
2. As an iPhone user, I want each TV to appear only once, so that I don't pick an entry that can't mirror.
3. As an iPhone user, I want the device list to show the TV's friendly name (e.g. "Living Room TV"), so that I can tell my TVs apart.
4. As an iPhone user, I want TVs that have left the network to disappear from the list, so that I don't select a dead entry.
5. As an iPhone user, I want to select a TV and start mirroring with the system broadcast button, so that I use the familiar iOS screen-recording flow.
6. As an iPhone user, I want my live screen to appear on the TV within a few seconds of starting the broadcast, so that mirroring feels responsive.
7. As an iPhone user, I want the mirror to keep running when I switch to another app, so that I can show any app on the TV.
8. As an iPhone user, I want the mirror to keep running when the iPhone screen rotates, so that landscape content (videos, games, slides) shows correctly.
9. As an iPhone user, I want the picture on the TV to be sharp enough to read text, so that presentations and documents are usable.
10. As an iPhone user, I want mirroring to stop on the TV when I stop the broadcast, so that the TV doesn't keep showing a frozen frame.
11. As an iPhone user, I want a clear error if my iPhone and TV aren't on the same network, so that I know what to fix.
12. As an iPhone user, I want a clear error if Local Network permission is denied, with a way to open Settings, so that I can grant it.
13. As an iPhone user, I want connecting to give up with a message after a reasonable time, so that the app never hangs on "Connecting...".
14. As an iPhone user, I want a clear error if the TV refuses to play the stream, so that I don't stare at a blank TV while the app says "Streaming Active".
15. As an iPhone user, I want the status indicator to reflect what the TV is actually doing (connecting, buffering, playing, stopped, failed), so that I can trust it.
16. As an iPhone user, I want the app to tell me when the TV session was ended from the TV side (e.g. someone pressed Back on the remote), so that I know why mirroring stopped.
17. As an iPhone user, I want the mirror to recover automatically from a brief Wi-Fi blip, so that a momentary drop doesn't end my session.
18. As an iPhone user, I want to switch to a different TV without restarting the app, so that I can move the mirror between rooms.
19. As an iPhone user, I want selecting the same TV again to do nothing disruptive, so that an accidental tap doesn't break a running mirror.
20. As an iPhone user, I want mirroring to require an active subscription, consistent with the paywall, so that the business model is applied uniformly.
21. As an iPhone user, I want the broadcast to stop gracefully if no TV has been selected, with a message telling me to pick one, so that I don't broadcast into nothing.
22. As an iPhone user, I want the app to not drain the battery or overheat the phone excessively during a mirror, so that I can mirror for a whole movie or meeting.
23. As an iPhone user, I want the broadcast extension to never crash from memory pressure, so that mirroring doesn't silently die mid-session.
24. As an iPhone user on a network where my iPhone has no Wi-Fi address, I want an explicit error rather than a localhost URL sent to the TV, so that I understand mirroring can't work.
25. As a developer, I want to run the full stream pipeline (encoded frames in, HLS over HTTP out) on Linux in podman, so that I can verify playable output without a Mac or a TV.
26. As a developer, I want an automated check that decodes the served HLS stream with ffmpeg and fails on any decode error, so that a regression to unplayable output is caught.
27. As a developer, I want the Cast session to be testable against a scripted Android TV receiver, so that connect, launch, load, failure, and disconnect paths are covered without hardware.
28. As a developer, I want failures typed and propagated instead of swallowed, so that I can diagnose problems from logs and tests.
29. As a developer, I want one place that owns the mirror session lifecycle, so that I don't have to trace state across the app, the coordinator, and the extension.
30. As a QA tester, I want a debug view of the stream URL and current segment count, so that I can confirm the server is producing segments while testing on device.

## Implementation Decisions

**Process ownership.**
- The broadcast upload extension owns the live pipeline for the duration of a broadcast: sample capture, encoding, segmenting, the HTTP server, and the Cast V2 session with the TV. The main app is suspended while the user is in other apps, so nothing on the live path may depend on it.
- The main app owns discovery, device selection, entitlement checks, and status UI.
- The loopback IPC channel between extension and main app (the IPC server/client and IPC packet framing) is removed from the video path. Subtract it rather than keep it alongside.
- Handoff uses an App Group. The app writes the selected device (id, name, IP, port, type) and entitlement state to shared defaults before the broadcast. The extension reads it at broadcast start, and writes session status (phase, error message, stream URL, segment count) back for the app to display. A Darwin notification signals status changes.
- If no device is selected or the user is not entitled, the extension finishes the broadcast immediately with a user-facing error via the ReplayKit finish-with-error API.

**Encoder.**
- New module in the extension wrapping VideoToolbox: real-time H.264, Main profile, no B-frames, keyframe every 1 second, target bitrate around 4 Mbps for the HD mode and around 2 Mbps for the low-latency mode (maps to the existing quality picker).
- Output is downscaled to at most 1280x720 (or 720x1280 in portrait) to stay well inside the extension's 50 MB memory ceiling.
- The encoder emits Annex-B access units. On keyframes it prepends SPS and PPS taken from the encoder's format description. Each unit carries a 90 kHz PTS derived from the sample buffer timestamp, and a keyframe flag.
- The hard-coded SPS, PPS, and IDR constants and the test-pattern segment loop are deleted from the live path. The test pattern may survive only behind the Linux demo server, not in the app.

**Stream pipeline (CastCore, platform-neutral).**
- One `MirrorStream` type replaces the current stream controller for live mirroring. Interface: start (returns bound port), append access unit (Annex-B bytes, 90 kHz PTS, keyframe flag), stop, and a status snapshot. It owns the TS muxer, the segmenter, and the HTTP routes for the playlist and segments.
- Access unit is a value type: Annex-B data, PTS in 90 kHz ticks, keyframe flag. The 90 kHz unit is encoded in the type, not in a comment, so the microsecond/90 kHz mixup cannot recur.
- TS muxer fixes: each access unit gets an AUD NAL. PCR is written on keyframe packets. PAT and PMT go at the start of every segment. The PMT declares video only (audio PID removed until audio is in scope). Continuity counters persist across segments.
- Segmenter cuts only at keyframes. Segment duration is computed from PTS deltas, not hard-coded. Target duration is the ceiling of the longest segment. Window of 6 segments. Segments older than the window are released.
- The playlist is not served until the first complete segment exists, so the TV never loads an empty or fabricated playlist.
- HTTP server: per-connection handling moves off the actor so blocking reads never hold actor isolation, and one slow TV request can't stall others or block stop. CORS header stays `*`.
- Stream URL resolution fails with a typed error when no Wi-Fi IPv4 address exists, instead of falling back to `localhost`.

**Cast session (Android TV / Chromecast built-in).**
- The coordinator becomes an explicit state machine with phases: idle, connecting, launching, loading, buffering, playing, ended(reason), failed(error). The app status UI renders from the phase.
- Connect has a timeout (about 8 s). The transport treats the `.waiting` state as a failure with the underlying reason, so missing local network permission becomes a typed error instead of a hang.
- The DIAL fallbacks in connect and cast are removed. A Cast V2 failure surfaces as a failure, never as success.
- LOAD uses streamType `LIVE`, contentType `application/x-mpegURL`, and `hlsVideoSegmentFormat` `mpeg2_ts`. `LOAD_FAILED`, `INVALID_REQUEST`, and a MEDIA_STATUS with idleReason `ERROR` all become a failed phase with the receiver's reason.
- Unsolicited MEDIA_STATUS broadcasts update the phase (buffering, playing, idle). A connection-namespace CLOSE from the receiver ends the session with reason "stopped on TV".
- Reconnect on unexpected disconnect stays, with a bounded number of attempts.
- Stopping the broadcast sends STOP to the media session and closes the receiver app the extension launched.

**Discovery.**
- Device identity is the stable id only. `DiscoveredDevice` equality and hashing use `id`, not `lastSeen` or `name`.
- An SSDP-discovered entry whose IP matches a Chromecast-discovered entry is suppressed, so an Android TV appears once, as Chromecast.
- Chromecast entries are removed on Bonjour service removal and pruned by staleness like other devices.
- Selecting the same device again is a no-op. Rapid successive selections cancel the previous in-flight connect.

**App.**
- Auto-start of mirroring on device selection is removed. Selection prepares the handoff, and the user starts mirroring with the broadcast button. This also closes the paywall bypass.
- Errors are no longer cleared on success of an unrelated step, and `try?` on the cast path is replaced with surfaced errors.

## Testing Decisions

A good test drives the system through its public interface and asserts what a user or the TV would observe: bytes served over HTTP decode into video, the receiver got a LOAD for the right URL, the app reached a failed phase with the receiver's reason. Tests do not assert on internal fields, call order inside a module, or private helper output.

**Seam 1 (primary): `MirrorStream`, access units in, HLS over HTTP out.**
- Highest seam that runs on Linux. Everything below the VideoToolbox encoder is exercised.
- Podman harness: a swift container runs a small CLI that reads an Annex-B H.264 elementary stream produced by ffmpeg (real encoder output, 1 s GOP, no B-frames, 720p, a few seconds of test source), splits it into access units with 90 kHz PTS, and feeds them into `MirrorStream` at real-time pace. A sibling ffmpeg container fetches the playlist and segments over the container network and decodes them. The check fails on any decoder error, on a frame count far below expected, or on non-monotonic PTS.
- This harness is a script in the repo so a reviewer can rerun it. It replaces the current state where 142 unit tests pass while the served stream cannot be decoded.
- Unit tests at the same seam (XCTest, run in podman): playlist not served before the first segment, segments cut at keyframes, target duration matches the longest segment, window slides and drops old segments.

**Seam 2: Cast session against a scripted receiver.**
- Uses the existing mock Cast transport and the coordinator's injected transport factory. A scripted Android TV receiver replies to CONNECT, LAUNCH, and LOAD with recorded-shape RECEIVER_STATUS and MEDIA_STATUS messages.
- Cases: happy path reaches playing. `LOAD_FAILED` reaches failed with the reason. MEDIA_STATUS idleReason `ERROR` reaches failed. Receiver CLOSE reaches ended. Connect timeout reaches failed within the timeout. Transport `.waiting` reaches failed with a permission-flavoured error. Re-selecting the same device sends no new CONNECT or LOAD.
- Prior art: the existing coordinator, Cast V2 client, and Cast transport tests already script the mock transport this way. Extend them, and delete tests that assert the DIAL fallback.

**Not testable on Linux, verified on device.**
- The VideoToolbox encoder and the ReplayKit extension lifecycle compile only on iOS. They stay thin: sample buffer in, access unit out. Verification is a device run via the existing Codemagic / GitHub iOS build, with the status written to the App Group (segment count rising, phase reaching playing) as the observable.

## Out of Scope

- Audio mirroring. The PMT carries video only for this cut.
- Sub-second latency. HLS gives roughly 3 to 6 seconds of delay. Low-latency HLS, WebRTC, or a custom Cast receiver are follow-ups.
- Roku, DLNA, Samsung, and LG targets. Their existing code paths are left alone except where shared types change (device equality).
- An Android phone sender app or an Android TV receiver app.
- The Cast tab (photo and video casting) and the web video detector.
- Adding the multicast networking entitlement for SSDP. Android TV is reached through Bonjour, which works without it.
- Replacing the self-signed certificate bypass on the Cast TLS connection.

## Further Notes

- Evidence for the current failure: running the existing server in podman and decoding a served segment with ffmpeg gives `Overread SPS by 4 bits`, `QP 4294966235 out of range`, `decode_slice_header error`, and `Conversion failed!`. The SPS parses as 640x1450.
- Assumption to verify on device (guess, not measured): the Default Media Receiver keeps playing HLS while the sender's TLS connection stays open from the extension. Keeping the Cast session inside the extension avoids depending on the main app staying alive.
- Extension memory budget: encoder, a 6-segment window at 2 to 4 Mbps (roughly 3 to 6 MB), and the Cast client should fit well under 50 MB. The existing memory guard stays and drops frames above 45 MB.
- The Linux demo server can keep serving a test pattern, but it must be generated by a real encoder (ffmpeg at harness time), not by hand-written NAL bytes.
