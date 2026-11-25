#!/usr/bin/env bash
# Taulun näkymä terminaaliin. Käyttö: board.sh            (avoimet kortit; valmiit piilossa)
#                                      board.sh --all      (myös valmiit)
#                                      board.sh --sync     (PR-korttien tila PR:stä: mergetty -> valmis jne.)
#                                      board.sh --web [portti]  (selainnäkymä board.html, oletusportti 8765)
#                                      board.sh --watch    (päivittyy 10 s välein)
#                                      board.sh K-0001     (yhden kortin tiedot ja loki)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

if [ "${1:-}" = "--web" ]; then
  # Sivu lukee cards.json:n 10 s välein, joten palvelin ajetaan taulun hakemistosta (vain localhost).
  PORT="${2:-8765}"
  write_web_config
  if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    (cd "$BOARD" && nohup python3 -m http.server "$PORT" --bind 127.0.0.1 > "$BOARD/log/web.out" 2>&1 &)
    sleep 1
  fi
  # Sync-silmukka: PR-tilat 3 min välein niin kauan kuin palvelin on pystyssä (yksi silmukka kerrallaan)
  if [ "${PR_PROVIDER:-none}" != "none" ] && ! pgrep -f "board-sync-loop-$PORT" >/dev/null 2>&1; then
    (exec -a "board-sync-loop-$PORT" bash -c "while lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; do '$BOARD/board.sh' --sync >> '$BOARD/log/sync.out' 2>&1; sleep 180; done" >/dev/null 2>&1 &)
  fi
  url="http://127.0.0.1:$PORT/board.html"
  (command -v open >/dev/null && open "$url") || (command -v xdg-open >/dev/null && xdg-open "$url") || true
  echo "$url"; exit 0
fi

if [ "${1:-}" = "--sync" ]; then
  # PR-korttien tila ja "odottaa" päätellään PR:stä, ei käsin. Ei LLM-kustannusta.
  # Säännöt: mergetty -> valmis | suljettu -> omistaja | konflikti -> omistaja | ei katselmoijaa -> omistaja
  #          muutospyyntö -> omistaja (paitsi jos korjaus pushattu sen jälkeen -> katselmoija)
  #          kaikki hyväksyneet -> omistaja (merge) | muuten -> katselmoija
  [ "${PR_PROVIDER:-none}" = "none" ] && { echo "PR_PROVIDER=none, ei synkkaa"; exit 0; }
  for id in $(jq -r '.cards[] | select(.tila=="pr" and .pr!=null) | .id' "$CARDS"); do
    pr=$(jq -r --arg id "$id" '.cards[] | select(.id==$id) | .pr' "$CARDS")
    case "$PR_PROVIDER" in
      github)
        info=$(cd "$REPO" && gh pr view "$pr" --json state,mergeable,reviewRequests,latestReviews,commits 2>/dev/null) || { echo "$id: PR #$pr ei luettavissa"; continue; }
        st=$(echo "$info" | jq -r '.state | if .=="MERGED" then "completed" elif .=="CLOSED" then "abandoned" else "active" end')
        ms=$(echo "$info" | jq -r 'if .mergeable=="CONFLICTING" then "conflicts" else "ok" end')
        # Katselmoijat: pyydetyt (ääni 0) + viimeisimmät arviot (APPROVED 10, CHANGES_REQUESTED -10, muut 0)
        rev=$(echo "$info" | jq -c '[(.reviewRequests[]? | {n:(.login // .name // "?"), v:0, t:""}),
              (.latestReviews[]? | {n:.author.login, v:(if .state=="APPROVED" then 10 elif .state=="CHANGES_REQUESTED" then -10 else 0 end), t:.submittedAt})]')
        head_ts=$(echo "$info" | jq -r '.commits | last | .committedDate // ""')
        last_neg=$(echo "$rev" | jq -r '[.[] | select(.v<0) | .t] | max // ""') ;;
      azure)
        info=$(az repos pr show --id "$pr" --org "$AZ_ORG_URL" -o json 2>/dev/null) || { echo "$id: PR !$pr ei luettavissa"; continue; }
        st=$(echo "$info" | jq -r .status); ms=$(echo "$info" | jq -r .mergeStatus)
        rev=$(echo "$info" | jq -c '[.reviewers[] | select(.isContainer!=true) | {n:.displayName, v:.vote}]')
        head_ts=""; last_neg=""
        if [ "$(echo "$rev" | jq '[.[] | select(.v<0)] | length')" -gt 0 ]; then
          # Ääni ei nollaudu pushista: verrataan haaran kärjen aikaa kielteisen katselmoijan viimeisimpään kommenttiin
          head_sha=$(echo "$info" | jq -r .lastMergeSourceCommit.commitId); head_ts=$(git -C "$REPO" show -s --format=%cI "$head_sha" 2>/dev/null || echo "")
          neg_names=$(echo "$rev" | jq -r '[.[] | select(.v<0) | .n] | join("|")')
          last_neg=$(az rest --method get --url "$AZ_ORG_URL/$AZ_PROJECT/_apis/git/repositories/$AZ_REPO/pullRequests/$pr/threads?api-version=7.1" --resource 499b84ac-1321-427f-aa17-267ca6975798 -o json 2>/dev/null \
            | jq -r --arg n "$neg_names" '[.value[].comments[] | select(.commentType!="system") | select(.author.displayName|test($n)) | .publishedDate] | max // ""')
        fi ;;
      *) echo "tuntematon PR_PROVIDER=$PR_PROVIDER"; exit 1 ;;
    esac
    nrev=$(echo "$rev" | jq 'length'); neg=$(echo "$rev" | jq '[.[] | select(.v<0)] | length')
    appr=$(echo "$rev" | jq '[.[] | select(.v>0)] | length'); names=$(echo "$rev" | jq -r '[.[] | "\(.n|split(" ")[0]) \(.v)"] | join(", ")')
    cur_od=$(jq -r --arg id "$id" '.cards[] | select(.id==$id) | .odottaa // ""' "$CARDS")
    cur_syy=$(jq -r --arg id "$id" '.cards[] | select(.id==$id) | .odottaa_syy // ""' "$CARDS")
    if [ "$st" = "completed" ]; then od="-"; syy="PR $pr mergetty"; tila=valmis
    elif [ "$st" = "abandoned" ]; then od="omistaja"; syy="PR $pr suljettu ilman mergeä, tarkista"; tila=pr
    elif [ "$ms" = "conflicts" ]; then od="omistaja"; syy="merge-konflikti"; tila=pr
    elif [ "$nrev" = 0 ]; then od="omistaja"; syy="lisää katselmoija"; tila=pr
    elif [ "$neg" -gt 0 ]; then
      if [ -n "$head_ts" ] && [ -n "$last_neg" ] && [ "$(to_epoch "$head_ts")" -gt "$(to_epoch "$last_neg")" ]; then
        od="katselmoija"; syy="korjaus pushattu muutospyynnön jälkeen, odottaa uutta ääntä ($names)"; tila=pr
      else od="omistaja"; syy="katselmoija pyytää muutoksia ($names)"; tila=pr; fi
    elif [ "$appr" = "$nrev" ]; then od="omistaja"; syy="kaikki hyväksyneet ($names), merge"; tila=pr
    else od="katselmoija"; syy="ääni puuttuu ($names)"; tila=pr; fi
    if [ "$od" != "$cur_od" ] || [ "$syy" != "$cur_syy" ]; then
      tmp=$(mktemp); jq --arg id "$id" --arg ts "$(date -u +%FT%TZ)" --arg od "$od" --arg syy "$syy" --arg tila "$tila" \
        '(.cards[] | select(.id==$id)) |= (.tila=$tila | .odottaa=(if $od=="-" then null else $od end) | .odottaa_syy=$syy | .historia += [{aika:$ts, tila:$tila, huomio:"sync: \($syy)"}])' \
        "$CARDS" > "$tmp" && mv "$tmp" "$CARDS"
      echo "$id: PR $pr -> $tila, odottaa $od: $syy"
    else echo "$id: PR $pr ennallaan ($od: $syy)"; fi
  done; exit 0
fi

FILTER='select(.tila!="valmis")'; [ "${1:-}" = "--all" ] && { FILTER='.'; shift; }
if [ "${1:-}" = "--watch" ]; then while true; do clear; "$0"; printf "\n%s  (päivittyy 10 s välein, lopeta Ctrl-C)\n" "$(date +%H:%M:%S)"; sleep 10; done; fi
if [ -n "${1:-}" ]; then
  jq -r --arg id "$1" '.cards[] | select(.id==$id) | "\(.id)  #\(.tiketti // "-")  \(.otsikko)\nTila: \(.tila)\nValmis kun: \(.done)", (if (.kierrokset // [])|length>0 then "\nKierrokset (korjaukset samaan korttiin):", (.kierrokset[] | "  \(.nro)  \(.otsikko)\n       valmis kun: \(.done)") else empty end), "\nHistoria:", (.historia[] | "  \(.aika)  \(.tila)  \(.huomio)"), "\nPäätettävää:", (if ((.paatokset // [])|length)==0 then "  -" else (.paatokset[] | "  \(.)") end)' "$CARDS"
  # Lokit viimeisimmän kierroksen hakemistosta (log/<ID>/k<N>/), ilman kierroksia log/<ID>/
  N=$(jq -r --arg id "$1" '.cards[] | select(.id==$id) | (.kierrokset // [])|length' "$CARDS"); L="$BOARD/log/$1"; [ "${N:-0}" != "0" ] && L="$L/k$((N+1))"
  for f in build review; do [ -f "$L/$f.md" ] && printf '\n--- %s/%s.md (alku) ---\n' "${L#$BOARD/}" "$f" && head -15 "$L/$f.md"; done
  exit 0
fi
printf '%-7s %-8s %-7s %-55s %s\n' ID TILA TIKETTI OTSIKKO VIIMEISIN
jq -r '.cards[] | '"$FILTER"' | [.id, (if .tila=="pr" then "pr\(if .pr then " \(.pr)" else "" end) odottaa: \(.odottaa // "?")" else .tila end), "#\(.tiketti // "-")", (.otsikko|.[0:55]), (((.historia // [])|last|.aika) // "" | sub("T";" ") | .[0:16])] | @tsv' "$CARDS" \
  | awk -F'\t' '{printf "%-7s %-8s %-7s %-55s %s\n", $1, $2, $3, $4, $5}'
printf '\nBlokatut ja päätöksiä odottavat:\n'
jq -r '.cards[] | '"$FILTER"' | select(.tila=="blocked" or ((.paatokset // [])|length)>0) | "  \(.id)  \(.tila)  \(if .tila=="blocked" then (.historia|last|.huomio) else "" end)", ((.paatokset // [])[] | "      ? \(.[0:150])")' "$CARDS" | grep . || echo "  ei yhtään"
