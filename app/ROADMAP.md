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

## Missing compared to YouTube

Home feed:

- [ ] Verify community posts on the signed-in Home feed.
- [ ] Vertical Shorts cards in the correct size, with a "More" entry.
- [ ] Live, upcoming and premiere badges, and watch progress on thumbnails.
- [ ] Movies, mixes, courses and sponsored-free shelves.
- [ ] Hide and "Don't recommend channel" feedback on Shorts and posts.

Shorts:

- [ ] Channel avatar, Subscribe, dislike, counts and description sheet.
- [ ] Scrubbable progress bar, sound page, captions and a menu.

Player:

- [ ] Double-tap to seek, chapters, seek-bar previews and SponsorBlock.
- [ ] Audio track picker, caption translation and resume position.

Video page:

- [ ] Per-creator Subscribe on videos with several creators.
- [ ] Live chat, playlists in the queue, clips and thanks.

Account and library:

- [ ] Edit, create and reorder playlists, channels list, and history search and removal.
- [ ] Profile page content, account switching and notification settings.
- [ ] Offline downloads and Cast.
