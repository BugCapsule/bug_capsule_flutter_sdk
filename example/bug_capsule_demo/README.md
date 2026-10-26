# BugCapsule Shop (demo)

A small shop app with six planted bugs that only happen with certain server data, response timing, or device storage. See "Try the demo" in the [root README](../../README.md).

The sixth is in **Live quotes**: a WebSocket feed whose server restarts every
few quotes. After a reconnect it repeats the last quote, and the screen throws
`Quote went stale`. The capsule records the socket traffic (spec v2), so
`bugcapsule replay` reproduces it with the server switched off, and
`bugcapsule verify` passes once `QuoteBook.onQuote` ignores quotes it has
already seen.
