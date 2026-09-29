# Media stack: what needs what, from where

One-time setup for the request/download stack in `docker/compose.yaml`. All settings live on the NFS share
(`/mnt/jellyfin/config` for Jellyfin, `/mnt/jellyfin/appdata/<app>` for the rest), so they survive the nightly VM rebuild.

## How it fits together

```
 Seerr ──request──▶ Radarr (movies) ──▶ qBittorrent ──▶ media/downloads ──hardlink──▶ media/movies ──▶ Jellyfin
   │               Sonarr (shows)  ──▶      ▲                                        media/shows
   │                    ▲                   │
   │                    └── indexers ── Prowlarr
   └── sign-in, "already have it?" ──▶ Jellyfin
```

## Addresses

Apps talk to each other over Docker's network by **service name** — never `localhost` or `192.168.1.61` in an app's connection settings.
Your browser reaches the admin UIs through SSH tunnels (`ssh jellyfin` on the desktop, `ssh desktop` on the Mac).

| App | App-to-app (in settings) | Browser, desktop / Mac | Browser, LAN |
|---|---|---|---|
| Jellyfin | `jellyfin` : `8096` | `localhost:8096` | `192.168.1.61:8096` |
| Seerr | `seerr` : `5055` | — | `192.168.1.61:5055` |
| Radarr | `radarr` : `7878` | `localhost:7878` | — |
| Sonarr | `sonarr` : `8989` | `localhost:8989` | — |
| Prowlarr | `prowlarr` : `9696` | `localhost:19696` | — |
| qBittorrent | `qbittorrent` : `8080` | `localhost:18080` | — |
| FlareSolverr | `flaresolverr` : `8191` | — (no UI) | — |

Prowlarr and qBittorrent use 19696 / 18080 in the browser because the Fedora desktop's SELinux blocks SSH
forwarding to 9696 and 8080 (labelled ports). Inside the VM they're still 9696 and 8080.

In every connection form: **Use SSL off, URL Base empty.**

## Credentials: where each one comes from

| Credential | Get it from | Used by |
|---|---|---|
| Radarr API key | Radarr → Settings → General → Security | Seerr, Prowlarr |
| Sonarr API key | Sonarr → Settings → General → Security | Seerr, Prowlarr |
| qBittorrent API key | qBittorrent → Tools → Options → WebUI → API Key → *Generate* | Radarr, Sonarr |
| qBittorrent WebUI password | qBittorrent → Tools → Options → WebUI → Authentication (first login: temporary password in `sudo docker logs jellyfin-qbittorrent-1 \| grep -i "temporary password"`) | you, in the browser |
| Jellyfin API key | Jellyfin → Dashboard → API Keys → + | Radarr, Sonarr (Connect) |
| Jellyfin username/password | your Jellyfin account | Seerr sign-in |
| Prowlarr/Radarr/Sonarr logins | set on first visit (Forms login) | you, in the browser |

Prowlarr's own API key isn't needed anywhere in this setup.

## Per app

### qBittorrent — `localhost:18080`
Needs nothing from the other apps.

- **WebUI → Authentication:** set a permanent password (the temporary one changes on every restart).
- **WebUI → API Key:** generate, copy (for Radarr/Sonarr), Save.
- **Downloads:** Default Torrent Management Mode = *Automatic*; tick *Excluded file names*:
  `*.exe` `*.scr` `*.lnk` `*.bat` `*.cmd` `*.zip` `*.rar`.
  Save path `/data/downloads/` and *Append .!qB extension* are pre-set by `docker/qbittorrent.conf`.
- **BitTorrent → Seeding Limits:** e.g. ratio 1.0 or 7 days, then *Stop torrent*.
- **Connection:** untick *Use UPnP / NAT-PMP*.

### Radarr — `localhost:7878`
| Where | Field | Value |
|---|---|---|
| Media Management → Root Folders | path | `/data/movies` (only root folder — not `/data/downloads`, not `/data`) |
| Media Management | Rename Movies / Use Hardlinks | on / on |
| Download Clients → + qBittorrent | Host / Port | `qbittorrent` / `8080` |
| | API Key | **qBittorrent API key** (leave Username + Password empty) |
| | Category | `radarr` |
| Download Clients | Remote Path Mappings | none |
| Connect → + Jellyfin (optional) | Host / Port / API Key | `jellyfin` / `8096` / **Jellyfin API key** |
| Indexers | — | don't add here; Prowlarr pushes them |

### Sonarr — `localhost:8989`
Same as Radarr, except:

| Field | Value |
|---|---|
| Root folder | `/data/shows` |
| Rename | Rename Episodes: on |
| qBittorrent category | `tv-sonarr` |

### Prowlarr — `localhost:19696`
| Where | Field | Value |
|---|---|---|
| Indexers → Add Indexer | — | the sites you want; Test, Save |
| Settings → Apps → + Radarr | Sync Level | Full Sync |
| | Prowlarr Server | `http://prowlarr:9696` |
| | Radarr Server | `http://radarr:7878` |
| | API Key | **Radarr API key** |
| Settings → Apps → + Sonarr | Prowlarr Server / Sonarr Server | `http://prowlarr:9696` / `http://sonarr:8989` |
| | API Key | **Sonarr API key** |
| Indexers | — | *Sync App Indexers*, then check they appear in Radarr/Sonarr → Settings → Indexers |

**FlareSolverr** (for indexers that fail *Test* with a Cloudflare error): Settings → Indexers → + FlareSolverr,
Host `http://flaresolverr:8191`, Tags `flaresolverr`. Then add the `flaresolverr` tag to just the indexers that need it —
untagged indexers don't use it.

### Seerr — `192.168.1.61:5055`
| Where | Field | Value |
|---|---|---|
| Setup → Jellyfin | Hostname / Port | `jellyfin` / `8096` |
| | External URL | `http://192.168.1.61:8096` |
| | Email | anything (label only, not verified) |
| | Username / Password | **your Jellyfin account** |
| Settings → Jellyfin | Libraries | sync, enable Movies + Shows |
| Settings → Services → + Radarr | Hostname / Port | `radarr` / `7878` |
| | API Key | **Radarr API key** |
| | Root Folder / Min. Availability | `/data/movies` / Released |
| | Default Server, Enable Scan | on |
| Settings → Services → + Sonarr | Hostname / Port | `sonarr` / `8989` |
| | API Key | **Sonarr API key** |
| | Root Folder / Season Folders | `/data/shows` / on |

### Jellyfin — `localhost:8096`
- **Libraries:** Movies → `/media/movies`, Shows → `/media/shows`. (`/media/downloads` is deliberately in no library.)
- **Dashboard → API Keys:** create one for Radarr/Sonarr *Connect* (optional — makes new imports show up immediately).
- **Branding → Login disclaimer (optional):** link to Seerr, `http://192.168.1.61:5055`.

## Setup order

1. qBittorrent — password, API key, Downloads/Seeding/Connection settings
2. Radarr + Sonarr — root folders, qBittorrent client (Test)
3. Prowlarr — indexers, then Apps → Radarr + Sonarr, Sync
4. Seerr — Jellyfin sign-in, libraries, Radarr + Sonarr
5. Jellyfin — Shows library; optional API key → Radarr/Sonarr Connect
6. Test: request something small in Seerr → Radarr/Sonarr *Activity → Queue* → qBittorrent → appears in Jellyfin

## Paths

| On the NFS share | Radarr / Sonarr | qBittorrent | Jellyfin |
|---|---|---|---|
| `media/movies` | `/data/movies` | — | `/media/movies` (read-only) |
| `media/shows` | `/data/shows` | — | `/media/shows` (read-only) |
| `media/downloads` | `/data/downloads` | `/data/downloads` | `/media/downloads` (in no library) |
| `appdata/<app>` | `/config` | `/config` | — |
| `config` | — | — | `/config` |
