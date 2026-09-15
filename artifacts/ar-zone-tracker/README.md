# AR Zone Tracker

Capacitor iOS app that anchors a `20 × 10 × 5 m` volume in ARKit space and
reports the phone position as `outside`, `partial`, or `inside`.

## Sideload on iPhone

1. On a Mac with Xcode installed, run `pnpm install` and then
   `pnpm --filter @workspace/ar-zone-tracker run cap:sync`.
2. Open the native project with
   `pnpm --filter @workspace/ar-zone-tracker run cap:open`.
3. In Xcode, choose a personal Apple Development team, connect the iPhone,
   enable Developer Mode on the phone, and select the iPhone as the run target.
4. Press Run. Xcode signs and installs the app directly on the device.

The first launch asks for camera access. LiDAR is enabled automatically on
devices that expose `ARFrame.sceneDepth`; other iPhones use regular ARKit
world tracking.

## Native bridge

`src/native/arZone.ts` is the TypeScript interface. The iOS implementation is
`ios/App/App/ARZoneNative.swift`. The native detector measures the overlap
between a small phone volume and the placed zone, which makes the boundary
state meaningful instead of treating the phone as an infinitely small point.

The browser preview intentionally includes a simulator so the interface can
be reviewed without a LiDAR-capable iPhone.