# Security and privacy

Bilibili NEXT is an unofficial client. Use only your own account and content you
are authorized to access. Account credentials are stored in macOS Keychain;
no credentials or media cache are part of this repository.

Playback uses signed media URLs supplied by Bilibili. Alternate CDN nodes are
accepted only after verifying initialization/index bytes and media length.
Temporary playback pages are session-scoped and are removed when changing video
or exiting; stale sessions are cleaned on the next launch after a crash.
Manually saved offline videos are separate and are not removed automatically.

The bundled app is Apple Development signed, not Developer ID notarized.
The first release targets Apple silicon and macOS 26 or later. Build from source
using your own signing identity if that better fits your deployment.

Please do not post cookies, signed media URLs, private messages, or Keychain
exports in issues. Redact those values when reporting a problem.
