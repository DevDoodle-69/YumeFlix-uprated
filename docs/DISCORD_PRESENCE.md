# Discord presence in YumeFlix

## What this build publishes

When watching activity is enabled, YumeFlix publishes a **Watching YumeFlix** activity associated with the YumeFlix Discord application. It contains the title, episode label (when available), playback timestamps, and the deterministic uploaded application asset key `yumeflix_logo` as `assets.large_image`. This avoids Discord media-proxy failures and makes the YumeFlix icon render for every title. The player still resolves extension artwork first (episode poster, parent poster, banner/background, then exact-title TMDB fallback) for the in-app experience.

The `yumeflix_logo` asset key must exist under Rich Presence Art Assets in Discord Developer Portal application `1322319281819488256`; upload the YumeFlix icon with that exact key once. Poster URL normalization remains covered for in-app and future integrations.

TMDB artwork lookup uses the app's saved TMDB key from Settings, or the build-time `TMDB_API_KEY` Dart define. The source archive does not embed the key. Discord's Gateway documentation accepts public external URLs for activity image assets; the client receives a media-proxy image identifier after processing.

The settings row reports the Gateway connection state and, after Discord's `READY` response, the account's display name, username, and avatar. Animated Discord avatars are rendered as GIFs. Credentials remain in the existing platform secure storage; this change does not add password collection or change the existing authentication flow.

## Authentication and policy note

This project inherited a direct Discord Gateway connection using a user-provided account token. That is **not** Discord's documented OAuth2 authorization flow or the official Discord Social SDK integration. Discord's OAuth2 documentation currently lists `activities.write` as unavailable to apps, while its Rich Presence documentation points developers to the Social SDK for native integrations. A user-account token must be treated as a highly sensitive credential; users should never share it or enter their Discord password into YumeFlix. Before distributing this integration broadly, replace the inherited token-based account connection with an approach explicitly approved and supported by Discord. A successful connection in a particular client/version does not guarantee ongoing support or policy compliance.

- [Discord OAuth2 scopes](https://docs.discord.com/developers/topics/oauth2#shared-resources-oauth2-scopes)
- [Discord Rich Presence overview](https://docs.discord.com/developers/platform/rich-presence)
- [Discord Social SDK](https://docs.discord.com/developers/discord-social-sdk/overview)
- [Discord activity image assets](https://docs.discord.com/developers/events/gateway-events#activity-object-activity-asset-image)
