# Site coverage

Which engine handles which kind of link.

## Videos → yt-dlp (~1800 sites)

YouTube · TikTok · Vimeo · Twitch · Instagram Reels/TV · Facebook · X/Twitter (video) · Dailymotion · Streamable · SoundCloud · Bandcamp · Twitch clips · plus everything on [yt-dlp's supported sites list](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md).

## Image galleries → gallery-dl (~400 sites)

Pinterest · ArtStation · DeviantArt · Imgur · Flickr · Reddit galleries · Tumblr · Behance · Unsplash · Pixiv · Danbooru · Gelbooru · MangaDex · Mangapark · Webtoons · Tapas · Instagram posts/profiles · X/Twitter media · plus everything on [gallery-dl's supported sites](https://github.com/mikf/gallery-dl/blob/master/docs/supportedsites.md).

## Special routing

| URL pattern | Chosen tool | Why |
|---|---|---|
| `instagram.com/reel/` `/tv/` | yt-dlp | Single video |
| `instagram.com/<profile>/` | gallery-dl | Whole feed as images |
| `twitter.com/*` `x.com/*` | gallery-dl | Handles both media types cleanly |
| `youtube.com/*` `youtu.be/*` | yt-dlp | Native |

## Not covered

- **DRM streaming** (Netflix, Prime, Disney+, Kindle, Audible, Comixology) — no free tool beats DRM
- **Piracy movie sites** (bingebox etc.) — intentional anti-scraping, use browser extensions like Video DownloadHelper
- **Private Discord attachments** — needs manual auth flow
- **Some Indian comic sites** — no plugin yet; candidates for custom scrapers (Phase 3)
