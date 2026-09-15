---
name: Capacitor native AR
description: Native Capacitor plugin conventions for ARKit integrations in this workspace
---

For Capacitor 8, a local Swift plugin registered with `registerPluginInstance` must conform to `CAPBridgedPlugin`, expose `identifier`, `jsName`, and `pluginMethods`, and be added to the Xcode target's Sources phase. A TypeScript `registerPlugin` wrapper can then receive native events through `addListener`.

**Why:** Capacitor 8 validates plugin instances at registration time; an `@objc` class alone is not enough, and a file on disk is not compiled unless the Xcode project includes it.

**How to apply:** When adding native capabilities to a Capacitor app, define the JS contract first, register the Swift plugin from the bridge view controller, add required privacy usage strings, and keep a browser fallback for preview-only environments.