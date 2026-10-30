#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"

ROOT="$(git rev-parse --show-toplevel)"
LOCAL_DIR="${ROOT}/site/"

if [[ -x /opt/homebrew/bin/rsync ]]; then
  RSYNC_BIN="/opt/homebrew/bin/rsync"
else
  RSYNC_BIN="$(command -v rsync)"
fi

DRY_RUN=0
if [[ $# -eq 1 ]]; then
  if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=1
  else
    echo "Использование: scripts/deploy.sh [--dry-run]" >&2
    exit 1
  fi
elif [[ $# -gt 1 ]]; then
  echo "Использование: scripts/deploy.sh [--dry-run]" >&2
  exit 1
fi

if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
  echo "site/index.html отсутствует, доставка отменена" >&2
  exit 1
fi

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "В репозитории есть незафиксированные изменения, доставка отменена" >&2
  exit 1
fi

RSYNC_ARGS=(-avz --delete --chmod=D755,F644
  -e "ssh -o BatchMode=yes -o ConnectTimeout=5")
if [[ "$DRY_RUN" -eq 1 ]]; then
  RSYNC_ARGS+=(--dry-run)
fi

"$RSYNC_BIN" "${RSYNC_ARGS[@]}" "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

if ! curl -fsS --cacert "$CA_CERT" -o /dev/null "$SITE_URL"; then
  echo "ресурс недоступен, доставка не подтверждена" >&2
  exit 1
fi

echo "deployed $(git -C "$ROOT" rev-parse --short HEAD)"
exit 0
