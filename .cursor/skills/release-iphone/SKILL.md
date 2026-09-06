---
name: release-iphone
description: >-
  Builds and runs the Dominar telemetry Flutter app in release mode on a
  physical iPhone. Use when the user asks to release, deploy, or install
  changes on an iPhone (e.g. "release these changes on this iPhone",
  "realease on iPhone XR", "run release on my iPhone").
---

# Release to iPhone

When the user wants to release app changes to a physical iPhone, follow this workflow.

## 1. Identify the target iPhone

Parse the iPhone model from the user's message (e.g. "iPhone XR", "iphone 15 pro").

If no model is given, ask which iPhone to use before continuing.

## 2. Find the device ID

From the repo root, run:

```bash
cd mobile/dominar_telemetry
flutter devices
```

Match the requested model in the output (case-insensitive). Example line:

```
iPhone XR (mobile) • 00008020-001231991ABB002E • ios • iOS 17.6.1 • ...
```

Use the middle token as `<device-id>` (the UDID between the bullet separators).

If multiple devices match, list them and ask the user to pick one.
If none match, show the full `flutter devices` output and ask the user to clarify.

If `flutter` is not found, try:

```bash
export PATH="$HOME/Downloads/flutter/bin:$PATH"
```

## 3. Release build and deploy

Run these commands in order, substituting the matched `<device-id>`:

```bash
cd mobile/dominar_telemetry
flutter clean && flutter pub get
cd ios && pod install && cd ..
flutter run --release -d <device-id>
```

Run from the repository root (adjust `cd` if already inside `mobile/dominar_telemetry`).

`flutter run --release` is long-running — run it in the background and monitor output until the app launches or an error appears.

## 4. Report back

Tell the user:
- Which iPhone model and device ID were used
- Whether the release build succeeded or failed
- Any errors from `pod install` or `flutter run`

## Examples

**User:** "Release these changes on iPhone XR"

1. Run `flutter devices`, find a line containing "iPhone XR", extract UDID.
2. Run clean → pub get → pod install → `flutter run --release -d <udid>`.

**User:** "Realease on this iphone" (no model)

Ask: "Which iPhone should I deploy to? (e.g. iPhone XR, iPhone 15)"
