# Roadmap

All phases have a first version. Each one still needs testing and fixes on a device.

| Phase | Scope |
|---|---|
| 1. Player | Fullscreen, rotation, session refresh, background audio, lock screen controls, quality, speed, captions, audio routes |
| 2. App structure | Tab bar, search with suggestions, Subs, filters, paging, accent colors, floating miniplayer |
| 3. Video page | Description, related videos, likes, subscribe, Watch Later, channels, comments, replies, comment likes |
| 4. Library | History, Watch Later, Liked, playlists |
| 5. Home feed | Videos, Shorts shelves, community posts, playlists, long press menu |
| 6. Notifications | Inbox with sections and an unread badge |

## Known gaps

- [ ] Picture-in-picture: mpv draws with Metal, and Apple's API needs its own player or a sample buffer layer.
- [ ] AirPlay video: the route button moves audio only.
- [ ] Verify signed-in comment posting, comment likes, notifications and the mixed Home feed. Their response shapes were only checked signed out.
- [ ] Download videos from the long press menu.
- [ ] Like, comment on and vote in community posts.
