# Spec: Cast-Lite iOS Screencast & Media Streaming App

## Problem Statement

Users with iOS devices (iPhones and iPads) who own non-Apple smart televisions or streaming devices (such as Samsung Tizen, LG webOS, Roku, Chromecast, Fire TV, and modern PC/Mac web browsers) cannot easily cast their screens or personal media without buying an Apple TV hardware unit. Built-in iOS AirPlay does not natively reach the majority of smart TVs. Existing third-party casting apps on the App Store are often bloated, unstable, crash due to extension memory limits, or fail to connect across mixed local network topologies. Furthermore, users lack a single unified app that seamlessly handles both low-latency full-system screen mirroring and high-quality web/camera-roll media casting.

## Solution

Cast-Lite is a native iOS application built with Swift and SwiftUI that enables universal screen mirroring and media casting to any smart TV or browser on the local Wi-Fi network.

Key user capabilities:
1. **Universal Screen Mirroring**: Low-latency screen streaming to Chromecast, Roku, DLNA-compatible TVs (Samsung, LG, Sony), and web browsers via an optimized ReplayKit Broadcast Extension and local streaming server.
2. **Direct Media Casting**: High-resolution playback of camera roll photos and 4K videos directly to smart TVs without compression artifacts or mirroring lag.
3. **In-App Web Video Caster**: Integrated web browser that automatically sniffs HTML5 web videos and routes them directly to the big screen with one tap.
4. **Transparent Freemium & Monetization**: Clear, friction-free onboarding with weekly, annual, and lifetime subscription options powered by StoreKit 2, offering a 3-day free trial before locking premium casting capabilities.

## User Stories

1. As an iPhone user with a Roku TV, I want to mirror my iPhone screen to my TV, so that I can show presentation slides or demo mobile apps to a group.
2. As an iPhone user with a Samsung smart TV, I want to cast personal photos and home videos from my Camera Roll, so that my family can view them together in full resolution.
3. As an iPhone user with an LG TV, I want the app to discover my TV automatically on the Wi-Fi network without entering IP addresses manually.
4. As an iPhone user with a Chromecast or Google TV device, I want to cast live screen content and videos directly to the Default Media Receiver, so that I don't need additional receiver apps.
5. As an iPhone user with a PC or Mac, I want to open a local web link in Chrome or Safari to view my mirrored phone screen, so that I can present without any TV hardware.
6. As a user watching web videos on my phone, I want the in-app browser to detect streaming video links, so that I can cast online videos to my TV with a single tap.
7. As a user casting videos to my TV, I want playback controls (play, pause, seek, volume), so that I can manage playback without touching the TV remote.
8. As a user initiating screen mirroring, I want a clear educational explanation before iOS requests local network permissions, so that I understand why the permission is required and do not accidentally deny it.
9. As a user launching screen mirror, I want the system broadcast picker to launch within the app, so that starting and stopping the broadcast is intuitive and fast.
10. As a user experiencing network fluctuations, I want the app to gracefully handle reconnection and notify me if the TV disconnects, so that I am not left looking at a frozen screen.
11. As a new user, I want to see a 3-day free trial subscription option during onboarding, so that I can test TV compatibility before paying.
12. As an annual subscriber, I want a deeply discounted yearly plan, so that I get maximum value for long-term use.
13. As a user who dislikes subscriptions, I want a lifetime purchase option, so that I can unlock the app permanently with a single payment.
14. As an existing subscriber who reinstalled the app or switched devices, I want a "Restore Purchases" button, so that I can regain full access immediately without paying twice.
15. As a privacy-conscious user, I want clear links to the Terms of Service and Privacy Policy within the paywall and settings, so that I know my data is handled securely.
16. As a user browsing media, I want fast thumbnail loading of my local photo library, so that I can quickly pick the exact photo or video I wish to project.
17. As a user casting 4K videos, I want smooth seeking support via byte-range HTTP requests, so that scrubbing forward and backward is instant.
18. As a user with multiple smart TVs at home, I want a device selector list that highlights the currently active receiver, so that I never stream to the wrong room.
19. As a user mirroring games or fast-action content, I want high frame rate and low latency, so that on-screen actions feel responsive.
20. As a user in low-light environments, I want full support for iOS Dark Mode, so that the app interface does not cause eye strain.

## Implementation Decisions

### 1. Architectural Topology & Process Boundaries
- **Two-Process Model**: Main Application (UI, discovery, web server, device controllers, media player, StoreKit 2) and `BroadcastUploadExtension` (ReplayKit capture and hardware video compression).
- **50MB Memory Guard**: Broadcast Extension memory footprint is strictly capped under iOS limits by running zero network servers or buffers inside the extension. The extension captures `CMSampleBuffer` frames, compresses them via `VTCompressionSession` into lightweight H.264 NAL units, and pipes them over a local TCP socket to the Main App.

### 2. Device Polymorphism & Protocol Abstraction
- All smart TV platforms implement a unified protocol interface:
  - Discovery: Multi-protocol engine running `NWBrowser` for mDNS/Bonjour (Chromecast) and custom UDP SSDP socket (DLNA, Roku).
  - DLNA / UPnP Adapter: Formats SOAP XML `AVTransport` commands (`SetAVTransportURI`, `Play`, `Pause`, `Seek`, `Stop`) targeting Port 1400/8080.
  - Roku Adapter: Interacts with Roku External Control Protocol (ECP) REST endpoints over Port 8060 (`/query/apps`, `/launch/15985?streamformat=hls&url=...`).
  - Chromecast Adapter: Connects over TLS to Port 8009 using the Google Cast V2 channel framing, launching Default Media Receiver (`CC1AD845`).
  - Web Receiver Adapter: Generates a lightweight HTML5 player hosted on the embedded HTTP server accessible via local Wi-Fi IP (`http://<phone-ip>:8080/view`).

### 3. Streaming & Multiplexing Engine
- **MPEG-TS Muxer**: Custom Swift packetizer transforms incoming H.264 NAL units and AAC audio frames into standard 188-byte MPEG-TS packets with Program Association Tables (PAT) and Program Map Tables (PMT).
- **Dual-Mode HTTP Server**: Built on `Network.framework` (`NWListener`):
  - Mode 1: Low-Latency HLS playlist (`stream.m3u8`) serving rolling 1-second `.ts` segments for Smart TVs (Roku, DLNA, Chromecast).
  - Mode 2: MJPEG multipart stream (`multipart/x-mixed-replace`) for zero-latency web browser streaming.
  - Mode 3: Byte-range HTTP file server (`206 Partial Content`) for native Camera Roll MP4 video streaming and seeking.

### 4. In-App Web Video Detection
- In-app browser powered by `WKWebView`.
- Injects a lightweight `WKUserScript` that hooks HTML5 `<video>` elements, observing `src` mutations and interception of `canPlayType` requests. When a valid `.mp4`, `.m3u8`, or streaming URL is detected, the script posts a message back to the native coordinator to present a floating "Cast Video to TV" banner.

### 5. Monetization & Entitlement Enforcement
- Built purely on Apple StoreKit 2 (`Transaction.currentEntitlements`, `Product.SubscriptionInfo`).
- Three SKUs:
  - `com.castlite.subscription.weekly` ($4.99/week with 3-day free trial)
  - `com.castlite.subscription.annual` ($39.99/year)
  - `com.castlite.lifetime` ($59.99 one-time non-consumable)
- Centralized `SubscriptionManager` actor maintains reactive entitlement state.
- Gating policy: Free users can discover devices and browse media; initiating screen mirror or casting video prompts the paywall modal.

### 6. App Navigation & Visual Layout
- Modern SwiftUI 3-tab layout:
  - **Tab 1: Mirror**: Device connection bar, connection status, latency/resolution toggles, and system broadcast trigger button.
  - **Tab 2: Cast**: Segmented picker between "Camera Roll" (Photos & Videos grid) and "Web Browser" (integrated browser with video sniffer).
  - **Tab 3: Settings**: Premium status / Paywall trigger, TV connection setup guide, Restore Purchases button, EULA and Privacy Policy links.

## Testing Decisions

### What Makes a Good Test
Tests must verify external observable behavior and protocol compliance without coupling to internal private state. Streaming tests must verify valid HTTP protocol responses, correct MIME headers, byte ranges, and valid MPEG-TS packet sync bytes. Device adapters must verify that specific protocol calls emit the exact network packets expected by smart TVs.

### Modules Under Test
1. **`CastSessionCoordinator` Integration Tests (Primary Seam)**:
   - Verifies end-to-end flow: mock video frames fed into session coordinator produce an HTTP endpoint returning valid `.m3u8` playlists and MPEG-TS byte chunks.
   - Verifies that calling `castMedia(url:)` triggers the expected UPnP SOAP payload or Roku ECP POST request.
   - Verifies entitlement enforcement: session refuses to stream when subscription is inactive.
2. **`MPEGTSPacketizer` Tests**:
   - Asserts each output chunk starts with sync byte `0x47`.
   - Asserts PAT (PID 0) and PMT (PID 4096) tables precede video/audio PES packets.
   - Verifies continuity counter incrementing.
3. **`LocalHTTPServer` Tests**:
   - Asserts `GET /stream.m3u8` returns `application/vnd.apple.mpegurl` with live sliding window tags.
   - Asserts `GET /media.mp4` with `Range: bytes=0-1024` returns HTTP `206 Partial Content` with accurate `Content-Range`.
4. **`SubscriptionManager` Tests**:
   - Uses Xcode StoreKit test environment (`.storekit`) to simulate purchase flows, active trial entitlements, expired subscriptions, and purchase restoration.

## Out of Scope

- Remote cloud relaying (casting outside the local Wi-Fi network).
- DRM-protected video casting (e.g., Netflix, Hulu, Disney+ protected content cannot be mirrored due to FairPlay DRM restrictions imposed by iOS).
- Native tvOS or Android TV client apps (using standard built-in TV protocols instead).
- AirPlay receiver implementation (AirPlay is a proprietary Apple-to-Apple protocol).

## Further Notes

- The project relies exclusively on modern native Apple frameworks (`Network.framework`, `VideoToolbox`, `ReplayKit`, `StoreKit 2`, `PhotosUI`, `WebKit`, `SwiftUI`) with zero heavy third-party dependencies, guaranteeing minimal binary size and future iOS compatibility.
- Deployment target is set to iOS 16.0+, allowing clean Swift Concurrency (`async/await`, `actor`) and modern NavigationStack across the entire app.
