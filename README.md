# Signal for Subwave

Standalone Subwave player container for Kyle's station surfaces.

This repo owns the Signal player packaging, standalone station setup, PWA/macOS wrapper branding, and bundled theme source. It builds the Subwave web frontend from a pinned git ref, applies local player patches, copies local theme files, and publishes a standalone container.

## Shape

- This container runs the Subwave web frontend as a Signal player surface.
- The default bundled skin is `Gatefold`, an album-art-first console theme.
- First launch asks the listener for a Subwave station URL, validates it against `/api/state`, and saves it in browser storage.
- Launch links can preselect a station with `?station=https://radio.example.com`.
- Local theme source lives in `skins/gatefold`.
- Local patches live in `patches`.

## Required Source Ref

The default `SUBWAVE_REF` is pinned to the upstream commit this patch series currently targets:

```text
90db93086945eacd07d9a2b5fe607c41a5ec2fe6
```

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

Add this as a separate service alongside the media/Subwave stack, or run this compose project independently and put it behind the existing Cloudflare tunnel.

The service serves the player shell. Browsers need access to whichever Subwave station URL the listener saves.

Suggested public hostname:

```text
https://signal.gurthyy.xyz
```

The live Unraid media stack is compose-managed at:

```text
/boot/config/plugins/compose.manager/projects/mediaStack/
```

Ready-to-merge snippets live in:

- `unraid/mediaStack.service.yml`
- `unraid/mediaStack.override.yml`

## Container Publishing

The GitHub Actions workflow publishes on every push to `main` and can be run manually:

```text
ghcr.io/kylejschultz/signal-subwave-player:latest
ghcr.io/kylejschultz/signal-subwave-player:<commit-sha>
```

Repository variables can override the defaults:

- `SUBWAVE_REPO`
- `SUBWAVE_REF`
- `APPLY_PLAYER_PREVIEW_SUPPORT_PATCH`
- `APPLY_LYRICS_CLIENT_SUPPORT_PATCH`
- `APPLY_GATEFOLD_SKIN_REGISTRY_PATCH`
- `APPLY_GATEFOLD_DEFAULT_PATCH`
- `APPLY_PLAYER_ONLY_PATCH`
- `APPLY_SIGNAL_ONLY_PATCH`
- `APPLY_STANDALONE_STATION_SETUP_PATCH`
- `APPLY_STANDALONE_STATION_CONTROLS_PATCH`
- `APPLY_SIGNAL_APP_BRANDING_PATCH`
- `PLAYER_SITE_URL`
- `SUBWAVE_PUBLIC_API_URL`
- `SUBWAVE_PUBLIC_STREAM_URL`
- `SIGNAL_THEME_IDS` - comma-separated theme IDs visible in Signal; empty by default, which shows every station theme
- `NEXT_PUBLIC_SUBWAVE_STATION_SETUP` - defaults to `required`
- `NEXT_PUBLIC_GA_ID`
- `SUBWAVE_BUILD_VERSION`

## macOS Wrapper

The macOS wrapper is a thin shell that opens the deployed player URL:

```text
https://signal.gurthyy.xyz/?skin=gatefold
```

That lets the web deploy carry Signal changes without rebuilding the app bundle.
