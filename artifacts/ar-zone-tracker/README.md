# AR Zone Tracker

Capacitor iOS app that anchors a `20 × 10 × 5 m` volume in ARKit space and
reports the phone position as `outside`, `partial`, or `inside`.

## Sideload on iPhone from Windows

This repository includes a GitHub Actions workflow at
`.github/workflows/build-ar-zone-tracker-ios.yml`. It uses a hosted macOS
runner to compile the native iOS project, so a physical Mac is not required.

### Build the IPA

1. Push the repository to GitHub. To use GitHub's free public macOS runner,
   the repository must be public.
2. On GitHub, open **Actions → Build AR Zone Tracker iOS IPA**.
3. Choose **Run workflow** and start the workflow from the default branch.
4. When it finishes, open the workflow run and download the
   `ar-zone-tracker-ios` artifact.
5. Extract `ARZoneTracker-unsigned.ipa` on Windows.

The workflow deliberately creates an unsigned IPA. AltStore signs it with
your own Apple ID on Windows, so no Apple Developer Program membership is
required for personal testing.

### Install with AltStore

1. Install AltServer on Windows and install iCloud for Windows from Apple's
   installer. Avoid the Microsoft Store versions if AltServer does not detect
   them.
2. Start AltServer, sign in locally with your Apple ID, and keep the iPhone
   connected or available through the same Wi-Fi network.
3. Enable **Developer Mode** on the iPhone and restart it if iOS requests this.
4. In AltStore on the iPhone, choose **My Apps → +**, select the downloaded
   `ARZoneTracker-unsigned.ipa`, and complete the Apple ID signing prompt.
5. Trust the developer profile in **Settings → General → VPN & Device
   Management** if iOS asks for it, then open AR Zone Tracker and allow camera
   access.

With a free Apple ID, the sideloaded app normally needs to be refreshed about
every 7 days. Keep AltServer running on Windows to renew it. The number of
simultaneously signed apps is also limited by Apple's free provisioning rules.

LiDAR is enabled automatically on devices that expose `ARFrame.sceneDepth`;
other iPhones use regular ARKit world tracking. The app has no simulator or
mock position mode: the browser only says that the native iPhone app is
required, and all coordinates and zone states come from ARKit frames.

### Local Mac build (optional)

If a Mac becomes available later, the original direct workflow still works:

```bash
pnpm install
pnpm --filter @workspace/ar-zone-tracker run cap:sync
pnpm --filter @workspace/ar-zone-tracker run cap:open
```

## Native bridge

`src/native/arZone.ts` is the TypeScript interface. The iOS implementation is
`ios/App/App/ARZoneNative.swift`. The native detector measures the overlap
between a small phone volume and the placed zone, which makes the boundary
state meaningful instead of treating the phone as an infinitely small point.
