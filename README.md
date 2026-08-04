# SUB/WAVE Prism Player

Small deployment wrapper for Kyle's Prism-flavored SUB/WAVE player.

This repo does not own the player implementation. It builds the SUB/WAVE web frontend from a pinned git ref, applies Kyle's Prism skin patches from `subwave-skins`, applies Prism standalone-player patches, and packages the result as a standalone container.

## Shape

- This container runs the SUB/WAVE web frontend as a Prism-first player surface.
- First launch asks the listener for a SUB/WAVE station URL, validates it against `/api/state`, and saves it in browser storage.
- Launch links can preselect a station with `?station=https://radio.example.com`.
- `https://github.com/kylejschultz/subwave-skins` supplies the Prism patch series and skin files.
- `patches/prism-default.patch` changes the fallback player skin from `classic` to `prism`.
- `patches/player-only.patch` redirects `/` to Prism and sends `/admin` and `/setup` back to the player.
- `patches/prism-only.patch` hides upstream skins and filters the theme picker to Kyle's Prism theme allowlist.
- `patches/standalone-station-setup.patch` adds first-time station setup.
- `patches/prism-app-branding.patch` gives the installable PWA a Prism identity.

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

The service serves the player shell. Browsers need access to whichever SUB/WAVE station URL the listener saves.

Suggested public hostname:

```text
https://prism.gurthyy.xyz
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
- `APPLY_STANDALONE_STATION_SETUP_PATCH`
- `APPLY_PRISM_APP_BRANDING_PATCH`
- `PLAYER_SITE_URL`
- `SUBWAVE_PUBLIC_API_URL`
- `SUBWAVE_PUBLIC_STREAM_URL`
- `PRISM_THEME_IDS` — comma-separated theme IDs visible in the Prism player; empty by default, which shows every station theme
- `NEXT_PUBLIC_SUBWAVE_STATION_SETUP` — defaults to `required`
- `NEXT_PUBLIC_GA_ID`
- `SUBWAVE_BUILD_VERSION`

## macOS Wrapper

The macOS wrapper is a thin shell that opens the deployed player URL:

```text
https://prism.gurthyy.xyz/?skin=prism
```

That lets the web deploy carry Prism changes without rebuilding the app bundle.
