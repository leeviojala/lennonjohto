#!/usr/bin/env bash
# Yhteiset asetukset kaikille skripteille. Lähde: . "$(dirname "$0")/lib.sh"
BOARD="${BOARD:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONF="$BOARD/lennonjohto.conf"
[ -f "$CONF" ] || { echo "Puuttuu $CONF: kopioi lennonjohto.conf.example ja muokkaa" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONF"
CARDS="$BOARD/cards.json"
[ -f "$CARDS" ] || echo '{"cards": []}' > "$CARDS"
mkdir -p "$BOARD/log"
[ -n "${EXTRA_PATH:-}" ] && export PATH="$EXTRA_PATH:$PATH"

# Taulun selainnäkymä lukee linkkien osoitteet ja omistajan nimen tästä tiedostosta
write_web_config() {
  local pr_url="" wi_url=""
  case "${PR_PROVIDER:-none}" in
    github)
      local slug; slug=$(cd "$REPO" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
      [ -n "$slug" ] && { pr_url="https://github.com/$slug/pull/"; wi_url="https://github.com/$slug/issues/"; } ;;
    azure)
      pr_url="$AZ_ORG_URL/$AZ_PROJECT/_git/$AZ_REPO/pullrequest/"; wi_url="$AZ_ORG_URL/$AZ_PROJECT/_workitems/edit/" ;;
  esac
  jq -n --arg o "${OWNER_NAME:-minä}" --arg p "$pr_url" --arg w "$wi_url" '{owner:$o, pr_url:$p, ticket_url:$w}' > "$BOARD/config.json"
}

# ISO-aikaleima -> epoch (macOS ja Linux)
to_epoch() {
  local t="${1%%.*}"; t="${t%Z}"; t="${t%%+*}"
  date -u -j -f %Y-%m-%dT%H:%M:%S "$t" +%s 2>/dev/null || date -u -d "${t}Z" +%s 2>/dev/null || echo 0
}
