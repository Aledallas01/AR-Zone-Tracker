---
name: Capacitor native AR
description: Native Capacitor plugin conventions for ARKit integrations in this workspace
---

For Capacitor 8, a local Swift plugin registered with `registerPluginInstance` must conform to `CAPBridgedPlugin`, expose `identifier`, `jsName`, and `pluginMethods`, and be added to the Xcode target's Sources phase. A TypeScript `registerPlugin` wrapper can then receive native events through `addListener`. For an AR-only product, the web runtime must fail explicitly outside native iOS rather than fall back to simulated positions.

**Why:** Capacitor 8 validates plugin instances at registration time; an `@objc` class alone is not enough, and a file on disk is not compiled unless the Xcode project includes it. A simulator fallback can make an installed build appear functional while hiding a broken native bridge.

**How to apply:** When adding native capabilities to a Capacitor app, define the JS contract first, register the Swift plugin from the bridge view controller, add required privacy usage strings, and keep a browser fallback for preview-only environments.