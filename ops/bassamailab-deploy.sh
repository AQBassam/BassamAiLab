#!/usr/bin/env bash
# BassamAI Lab — server-side deploy script.
#
# Installed on the VPS as /usr/local/bin/bassamailab-deploy and run ONLY through
# the forced command of the GitHub Actions deploy key:
#   restrict,command="/usr/local/bin/bassamailab-deploy" ssh-ed25519 AAAA... github-actions-bassamailab
#
# The client sends one argument: the 40-char commit SHA to deploy (arrives as
# $SSH_ORIGINAL_COMMAND). Anything else is rejected.
#
# What it does, mirroring the manual procedure in the handover document:
#   1. fetch exactly that commit from the public repo
#   2. check every required file exists and is non-empty
#   3. copy index.html + assets/ into a new timestamped release
#   4. atomically switch `current` to the new release
#   5. verify the live site through nginx on this machine
#   6. if verification fails, switch `current` back and exit non-zero
# Old releases are never deleted.

set -euo pipefail

SITE="${BASSAMAILAB_SITE:-/var/www/bassamailab}"
REPO="https://github.com/AQBassam/BassamAiLab.git"
HOST="bassamailab.xyz"
REQUIRED=(index.html assets/fursan-preview.webp assets/dinner-preview.webp assets/og-image.jpg assets/favicon.svg)
CHECK_PATHS=(/ /assets/og-image.jpg /assets/favicon.svg /assets/fursan-preview.webp /assets/dinner-preview.webp)
LOG="$SITE/deploy.log"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

SHA="${SSH_ORIGINAL_COMMAND:-${1:-}}"
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "rejected: expected a 40-character commit SHA" >&2
  exit 2
fi

exec 9>"$SITE/.deploy.lock"
if ! flock -n 9; then
  echo "rejected: another deploy is running" >&2
  exit 3
fi

TS="$(date +%Y%m%d%H%M%S)"
RELEASE="$SITE/releases/$TS"
WORK="$(mktemp -d /tmp/bassamailab-deploy.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

log "start $TS commit $SHA"

git init -q "$WORK/repo"
git -C "$WORK/repo" fetch -q --depth 1 "$REPO" "$SHA"
git -C "$WORK/repo" checkout -q FETCH_HEAD

for f in "${REQUIRED[@]}"; do
  if [ ! -s "$WORK/repo/$f" ]; then
    log "abort: missing $f — current left unchanged"
    exit 4
  fi
done

mkdir -p "$RELEASE"
cp -a "$WORK/repo/index.html" "$WORK/repo/assets" "$RELEASE/"
rm -f "$RELEASE/assets/.gitkeep"

PREV="$(readlink -f "$SITE/current" 2>/dev/null || true)"
ln -s "$RELEASE" "$SITE/current.new.$TS"
mv -Tf "$SITE/current.new.$TS" "$SITE/current"
log "switched current -> $RELEASE (previous: ${PREV:-none})"

fail=0
for u in "${CHECK_PATHS[@]}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
          --resolve "$HOST:443:127.0.0.1" "https://$HOST$u" || true)"
  log "check $code $u"
  [ "$code" = 200 ] || fail=1
done
if ! curl -s --max-time 10 --resolve "$HOST:443:127.0.0.1" "https://$HOST/" | grep -q 'og:image'; then
  log "check failed: og:image not found in served page"
  fail=1
fi

if [ "$fail" = 1 ]; then
  if [ -n "$PREV" ] && [ -s "$PREV/index.html" ]; then
    ln -s "$PREV" "$SITE/current.rollback.$TS"
    mv -Tf "$SITE/current.rollback.$TS" "$SITE/current"
    log "ROLLED BACK to $PREV — release $TS kept for inspection"
  else
    log "verification failed and no previous release to roll back to"
  fi
  exit 1
fi

log "done $TS commit $SHA"
