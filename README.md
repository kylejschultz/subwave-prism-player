# SUB/WAVE Prism Player

Small deployment wrapper for Kyle's Prism-flavored SUB/WAVE player.

This repo does not own the player implementation. It builds the SUB/WAVE web frontend from a pinned git ref, applies Kyle's Prism skin patches from `subwave-skins`, applies a tiny Prism-default patch, points the client at the live station, and packages the result as a standalone container.

## Shape

- `radio.kjho.me` remains the real SUB/WAVE station, API, admin, and stream.
- This container runs the full SUB/WAVE web frontend as a player-first surface.
- The browser client is built with `NEXT_PUBLIC_API_URL=https://radio.kjho.me/api`.
- The browser stream URL is built with `NEXT_PUBLIC_STREAM_URL=https://radio.kjho.me/stream.mp3`.
- `https://github.com/kylejschultz/subwave-skins` supplies the Prism patch series and skin files.
- `patches/prism-default.patch` changes the fallback player skin from `classic` to `prism`.
- `patches/player-only.patch` redirects `/` to Prism and sends `/admin` and `/setup` back to the player.
- `patches/prism-only.patch` hides upstream skins and filters the theme picker to Kyle's Prism theme allowlist.

## Required Source Ref

The default `SUBWAVE_REF` is pinned to the upstream commit the `subwave-skins` patch series was created against:

```text
90db93086945eacd07d9a2b5fe607c41a5ec2fe6
```

The build then clones:

```text
https://github.com/kylejschultz/subwave-skins.git
```

and applies every patch in `patches/*.patch`, followed by the local Prism-default patch.

## Local Compose

```bash
cp .env.example .env
docker compose --env-file .env up -d --build
```

The app listens on `PLAYER_PORT`, defaulting to:

```text
http://localhost:7703/
```

## Unraid Stack

Add this as a separate service alongside the media/SUB/WAVE stack, or run this compose project independently and put it behind the existing Cloudflare tunnel.

The service only needs HTTP access to:

- `https://radio.kjho.me/api`
- `https://radio.kjho.me/stream.mp3`

Suggested public hostname:

```text
https://player.kjho.me
```

The live Unraid media stack is compose-managed at:

```text
/boot/config/plugins/compose.manager/projects/mediaStack/
```

Ready-to-merge snippets live in:

- `unraid/mediaStack.service.yml`
- `unraid/mediaStack.override.yml`

## Container Publishing

The GitHub Actions workflow publishes on every push to `main`, can be run manually, and accepts a `subwave-skins-updated` repository dispatch event for cross-repo rebuilds from the skin source repo:

```text
ghcr.io/kylejschultz/subwave-prism-player:latest
ghcr.io/kylejschultz/subwave-prism-player:<commit-sha>
```

Repository variables can override the defaults:

- `SUBWAVE_REPO`
- `SUBWAVE_REF`
- `SUBWAVE_SKINS_REPO`
- `SUBWAVE_SKINS_REF`
- `APPLY_SUBWAVE_SKINS_PATCHES`
- `APPLY_PRISM_DEFAULT_PATCH`
- `APPLY_PLAYER_ONLY_PATCH`
- `APPLY_PRISM_ONLY_PATCH`
- `PLAYER_SITE_URL`
- `SUBWAVE_PUBLIC_API_URL`
- `SUBWAVE_PUBLIC_STREAM_URL`
- `PRISM_THEME_IDS` — comma-separated theme IDs visible in the Prism player; defaults to `cyan-gloom`
- `NEXT_PUBLIC_GA_ID`
- `SUBWAVE_BUILD_VERSION`

## macOS Wrapper

The macOS wrapper is a thin shell that opens the deployed player URL:

```text
https://player.kjho.me/?skin=prism
```

That lets the web deploy carry Prism changes without rebuilding the app bundle.
