---
name: Windows iOS delivery
description: Distribution constraint and signing approach for AR Zone Tracker
---

The project is intended to be usable by a Windows-only owner without a paid Apple Developer membership. Native iOS compilation happens on a hosted macOS runner; the resulting unsigned IPA is signed locally with the owner's Apple ID through AltStore.

**Why:** ARKit requires a native iOS build, while the owner does not have macOS. The free Apple ID route is suitable for personal testing but requires periodic re-signing and is not App Store distribution.

**How to apply:** Keep the macOS workflow manual and avoid putting Apple credentials in GitHub or Replit secrets. Treat the 7-day free provisioning period and public-repository/runner availability as explicit user-facing limitations.