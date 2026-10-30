# Roadmap

All phases have a first version. Each one still needs testing and fixes on a device.

| Phase | Scope |
|---|---|
| 1. Player | Fullscreen, rotation, session refresh, background audio, lock screen controls, quality, speed, captions, audio routes |
| 2. App structure | Tab bar, search with suggestions, Subscriptions, filters, paging |
| 3. Video page | Description, related videos, likes, subscribe, Watch Later, channels, comments, replies, comment likes |
| 4. You | Account, History, Watch Later, Liked, playlists, settings |
| 5. Shorts | Vertical swipe player with likes and comments |
| 6. Notifications | Inbox opened from the bell |

## Known gaps

- [ ] Picture-in-picture: mpv draws with Metal, and Apple's API needs its own player or a sample buffer layer.
- [ ] AirPlay video: the route button moves audio only.
- [ ] Verify signed-in comment posting, comment likes and notifications. Their response shapes were only checked signed out.
