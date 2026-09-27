#!/bin/bash
# Opens a shell in the sandboxed inspection container (uid 2000, no network, no capabilities, media read-only).
# The one way the non-root VM user reaches Docker: `sudo /opt/jellyfin/inspect.sh` (see /etc/sudoers.d/jellyfin in terraform).
# Takes no arguments on purpose - `docker compose run` flags like -v, -u or --entrypoint would hand out root.
set -euo pipefail
cd /opt/jellyfin
exec /usr/bin/docker compose -f /opt/jellyfin/compose.yaml run --rm inspection
