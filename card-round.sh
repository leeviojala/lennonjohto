#!/usr/bin/env bash
# Lisää korttiin korjauskierroksen (sama haara, sama PR) ja käynnistää sen taustalle.
# Käyttö: card-round.sh K-0002 "otsikko" "muutos" "valmis kun" [tiedosto ...]
# Sääntö: katselmoinnin löydös tai jatkokorjaus menee samaan korttiin kierroksena, ei uutta korttia.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ID="${1:?kortin id}"; OTSIKKO="${2:?otsikko}"; MUUTOS="${3:?muutos}"; DONE="${4:?valmis kun}"; shift 4
jq -e --arg id "$ID" '.cards[] | select(.id==$id)' "$CARDS" >/dev/null || { echo "ei korttia $ID"; exit 1; }
FILES=$(if [ $# -gt 0 ]; then printf '%s\n' "$@" | jq -R . | jq -s .; else echo '[]'; fi)
N=$(jq -r --arg id "$ID" '.cards[] | select(.id==$id) | (.kierrokset // []) | length' "$CARDS")
NRO=$((N + 2))   # kierros 1 on kortin alkuperäinen tehtävä
ts=$(date -u +%FT%TZ); tmp=$(mktemp)
jq --arg id "$ID" --arg o "$OTSIKKO" --arg m "$MUUTOS" --arg d "$DONE" --argjson f "$FILES" --argjson nro "$NRO" --arg ts "$ts" '
  (.cards[] | select(.id==$id)) |= (
    .kierrokset = ((.kierrokset // []) + [{nro:$nro, otsikko:$o, muutos:$m, done:$d, tiedostot:$f, aika:$ts}])
    | .tila = "todo" | .odottaa = null
    | .historia += [{aika:$ts, tila:"todo", huomio:"kierros \($nro): \($o)"}])' "$CARDS" > "$tmp" && mv "$tmp" "$CARDS"
echo "[$ID] kierros $NRO lisätty: $OTSIKKO"
cd "$BOARD" && nohup ./card-run.sh "$ID" > "log/$ID-run.out" 2>&1 &
echo "käynnistetty, loki log/$ID-run.out"
