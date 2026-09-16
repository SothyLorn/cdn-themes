# Mobile App Theme Hosting — cdn.sothy.site

Seasonal theme bundles served as static files from nginx. The app polls a
single small `manifest.json` and downloads a versioned, hash-pinned zip when
the active theme changes.

Build machine and web server are the same host, so `publish.sh` copies into
the local docroot rather than rsyncing over SSH.

## URLs

```
https://cdn.sothy.site/manifest.json                              # mutable, 60s TTL
https://cdn.sothy.site/bundles/khmer-new-year-2027.1/theme.zip    # immutable, 1y
https://cdn.sothy.site/bundles/khmer-new-year-2027.1/preview.png
https://cdn.sothy.site/healthz
```

Docroot is `/var/www/themes`, served at the domain root — no `/themes/` path
prefix, since the subdomain is dedicated to this.

## Layout

```
themes/
├── src/                        # designers work here, committed to git
│   ├── default/
│   │   ├── theme.json          # colors, gradients, asset map, strings
│   │   ├── preview.png         # picker thumbnail, NOT packed into the zip
│   │   └── images/*.png
│   ├── khmer-new-year/
│   │   ├── theme.json
│   │   ├── preview.png
│   │   ├── images/*.png
│   │   └── lottie/splash.json
│   └── pchum-ben/
│
├── dist/                       # build output, gitignored
│   ├── manifest.json           # THE ONLY MUTABLE FILE
│   └── bundles/
│       ├── default-1.0/
│       │   ├── theme.zip
│       │   ├── preview.png
│       │   └── bundle.meta.json
│       └── khmer-new-year-2027.1/
│
├── nginx/cdn.sothy.site.conf
├── build-bundle.sh
├── update-manifest.sh
├── publish.sh
├── gen-placeholders.sh
└── check-assets.sh
```

`dist/` maps onto `/var/www/themes/` on the server.

## First-time server setup

```bash
sudo mkdir -p /var/www/themes/bundles /var/www/certbot
sudo cp nginx/cdn.sothy.site.conf /etc/nginx/conf.d/
sudo nginx -t && sudo systemctl reload nginx

# TLS (rewrites the ssl_certificate lines in place)
sudo certbot --nginx -d cdn.sothy.site
```

Point an A record for `cdn.sothy.site` at the server before running certbot,
or the HTTP-01 challenge fails.

## Release workflow

```bash
./check-assets.sh khmer-new-year               # what's missing
./gen-placeholders.sh khmer-new-year           # optional, until real art lands

./build-bundle.sh khmer-new-year 2027.1
./build-bundle.sh default 1.0                  # fallback must exist

./update-manifest.sh --active khmer-new-year-2027.1 --rollout 25

DRY_RUN=1 ./publish.sh                         # preview
sudo ./publish.sh
```

Widen the rollout once error rates look clean:

```bash
./update-manifest.sh --active khmer-new-year-2027.1 --rollout 100
sudo ./publish.sh
```

### Rollback

```bash
./update-manifest.sh --active default-1.0
sudo ./publish.sh
```

Propagates at the manifest TTL (60s) plus the client poll interval. Devices
holding the old bundle re-apply it with no download.

## Why versioned directories

`bundles/<theme>-<version>/` never changes content, so nginx can send
`Cache-Control: immutable, max-age=31536000` and each device downloads a given
bundle exactly once. To ship a fix you cut `2027.2` — `build-bundle.sh`
refuses to overwrite an existing bundle for exactly this reason.

## manifest.json fields

| Field | Purpose |
|---|---|
| `active` | Bundle to apply if in window and in rollout |
| `fallback` | Applied when `active` fails validation or is out of window |
| `poll_interval_seconds` | How often the app re-checks (6h) |
| `themes[].sha256` | Client MUST verify before extracting |
| `themes[].size` | Cheap pre-flight check |
| `themes[].min_app_version` | Older builds ignore the bundle |
| `themes[].active_from/to` | ICT activation window |
| `themes[].rollout_percent` | Bucket on a stable device hash, not `random()` |

## Client contract

1. GET `manifest.json` on cold start, and on resume once the poll interval elapsed.
2. Skip if app version < `min_app_version`, if now is outside the window, or if
   the device bucket exceeds `rollout_percent`.
3. Download `theme.zip`; check `size`, then `sha256`. Discard on mismatch.
4. Extract to a staging directory, then rename into place atomically.
5. On any failure — network, hash, parse, missing asset — apply `fallback` and
   carry on. **A theme failure must never block login or transactions.**

Bucket with something stable like `sha256(device_id + bundle_id) % 100` so a
device doesn't flip in and out of the canary on every poll.

## Security notes

- Bundles are unauthenticated public files. Ship **theme assets only** — no
  config, no endpoint URLs, no keys, no feature flags.
- The zip is attacker-relevant input on the client. Cap the uncompressed size,
  reject entries containing `..` or absolute paths (zip-slip), and reject
  unexpected file extensions.
- `sha256` in the manifest is an integrity check, not a signature. Anyone who
  can write to `/var/www/themes` can change both the zip and its hash. If you
  need provenance, sign the manifest with a key pinned in the app.
- Unreleased campaign artwork is public the moment it's in `bundles/`. Keep it
  out of `dist/` until launch, and consider a private git repo.
