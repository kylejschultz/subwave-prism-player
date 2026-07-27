# SUB/WAVE Prism Player

Small deployment wrapper for Kyle's Prism-flavored SUB/WAVE player.

This repo does not own the player implementation. It builds the SUB/WAVE web frontend from a pinned git ref, applies a tiny Prism-default patch, points the client at the live station, and packages the result as a standalone container.

## Shape

- `radio.kjho.me` remains the real SUB/WAVE station, API, admin, and stream.
- This container runs the full SUB/WAVE web frontend as a player-first surface.
- The browser client is built with `NEXT_PUBLIC_API_URL=https://radio.kjho.me/api`.
- The browser stream URL is built with `NEXT_PUBLIC_STREAM_URL=https://radio.kjho.me/stream.mp3`.
- `patches/prism-default.patch` changes the fallback player skin from `classic` to `prism`.

## Required Source Ref

`SUBWAVE_REF` must point at a SUB/WAVE branch, tag, or commit that contains the Prism skin.

Current local Prism work was observed at:

```text
dee6d4ae52ec4d0915f6670d935a71add8360e8a
```

That commit needs to live in a GitHub-accessible SUB/WAVE source repo before GitHub Actions or an Unraid build can fetch it.

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

The GitHub Actions workflow publishes:

```text
ghcr.io/kylejschultz/subwave-prism-player:latest
ghcr.io/kylejschultz/subwave-prism-player:<commit-sha>
```

Repository variables can override the defaults:

- `SUBWAVE_REPO`
- `SUBWAVE_REF`
- `APPLY_PRISM_DEFAULT_PATCH`
- `PLAYER_SITE_URL`
- `SUBWAVE_PUBLIC_API_URL`
- `SUBWAVE_PUBLIC_STREAM_URL`
- `NEXT_PUBLIC_GA_ID`
- `SUBWAVE_BUILD_VERSION`

## macOS Wrapper

The planned macOS wrapper should remain a thin shell that opens the deployed player URL. That lets the web deploy carry Prism changes without rebuilding the app bundle.
