## 0.1.0-dev.1

- Pilot release. `BugCapsuleShorebird` implements `HotfixProvider` (`EmergencyConfig.hotfixProvider`) with `shorebird_code_push`: `checkAvailability`, `downloadAvailablePatch` and `getStatus` report the running and the downloaded patch, an optional `UpdateTrack`, and `restart_required` after a download. Builds not made with `shorebird release` report `available: false`. Never restarts the app.
