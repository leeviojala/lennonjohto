#!/usr/bin/env bash
# Ajaa yhden kortin silmukan: worktree -> toteuttaja -> testit -> katselmoija -> tila.
# Käyttö: card-run.sh K-0001            (koko silmukka)
#         card-run.sh K-0001 --resume   (toteuttaja on jo valmis: testit, katselmointi, tila)
# Skripti ajaa itsensä kopiosta, jotta tiedoston muokkaus kesken ajon ei riko käynnissä olevaa korttia.
set -euo pipefail
if [ -z "${CARD_RUN_COPY:-}" ]; then
  BOARD="$(cd "$(dirname "$0")" && pwd)"; export BOARD
  _c=$(mktemp); cp "$0" "$_c"; CARD_RUN_COPY=1 exec bash "$_c" "$@"
fi
. "$BOARD/lib.sh"
ID="${1:?kortin id}"; MODE="${2:-}"

CLI="${CLAUDE_BIN:-}"; [ -n "$CLI" ] || CLI="$(command -v claude || true)"
[ -n "$CLI" ] && [ -x "$CLI" ] || { echo "claude-binääriä ei löydy: aseta CLAUDE_BIN lennonjohto.confiin" >&2; exit 1; }
# Toteuttaja ja katselmoija voivat käyttää eri mallia. Ympäristömuuttuja ohittaa asetuksen.
MODELARG=(--model "${CARD_MODEL:-${IMPL_MODEL:-sonnet}}")
REVIEWMODELARG=(--model "${CARD_REVIEW_MODEL:-${REVIEW_MODEL:-opus}}")
LOG="$BOARD/log/$ID"; mkdir -p "$LOG"

card() { jq -r --arg id "$ID" '.cards[] | select(.id==$id) | '"$1" "$CARDS"; }
set_state() {
  local tila="$1" note="${2:-}" ts tmp; ts=$(date -u +%FT%TZ)
  tmp=$(mktemp)
  jq --arg id "$ID" --arg tila "$tila" --arg note "$note" --arg ts "$ts" --arg wt "${WT:-}" '
    (.cards[] | select(.id==$id)) |= (.tila=$tila | .worktree=(if $wt=="" then .worktree else $wt end)
      | .historia += [{aika:$ts, tila:$tila, huomio:$note}])' "$CARDS" > "$tmp" && mv "$tmp" "$CARDS"
  echo "[$ID] $tila ${note:+- $note}"
}
# Kortti PR-vaiheessa: tila "pr", kenttä pr (numero) ja odottaa = omistaja | katselmoija. "valmis" vasta kun PR on mergetty.
set_odottaa() { local tmp; tmp=$(mktemp); jq --arg id "$ID" --arg od "$1" '(.cards[] | select(.id==$id)) |= (.odottaa=$od)' "$CARDS" > "$tmp" && mv "$tmp" "$CARDS"; }

jq -e --arg id "$ID" '.cards[] | select(.id==$id)' "$CARDS" >/dev/null || { echo "ei korttia $ID" >&2; exit 1; }
TITLE=$(card .otsikko); MUUTOS=$(card .muutos); DONE=$(card .done)
FILES=$(card '(.tiedostot // []) | join(", ")'); BASE=$(card ".base // \"$BASE_BRANCH\""); RO=$(card '.readonly // false'); TIK=$(card '.tiketti // ""')
KONTEKSTI=$(card '.konteksti // ""')
# Katselmoija saa saman tausta-aineiston (esim. tiketin teksti) absoluuttisena polkuna; ilman sitä se ei voi tarkistaa ehtoja, jotka viittaavat aineistoon
KONTEKSTI_REVIEW=$(card '.konteksti // ""'); [ -n "$KONTEKSTI_REVIEW" ] && [ -e "$BOARD/$KONTEKSTI_REVIEW" ] && KONTEKSTI_REVIEW="$BOARD/$KONTEKSTI_REVIEW"
WT=$(card '.worktree // ""'); [ -z "$WT" ] && WT="${WT_PREFIX}$ID"

# Kierrokset: viimeisin kierros on ajettava tehtävä, alkuperäinen muutos/done on taustaa.
# Lokit kierroksen omaan hakemistoon log/<ID>/k<N>/. Lisäys: card-round.sh.
N=$(card '.kierrokset // [] | length')
if [ "$N" != "0" ]; then
  KIERROS=$((N + 1))
  TAUSTA="Tämä on kortin kierros $KIERROS. Aiemmat kierrokset on jo toteutettu samassa haarassa; älä tee niitä uudelleen.
Alkuperäinen tehtävä (kierros 1): $MUUTOS
Alkuperäinen valmiusehto: $DONE
$(card '.kierrokset[:-1][] | "Kierros \(.nro): \(.otsikko) — valmis kun: \(.done)"')"
  TITLE="$TITLE — kierros $KIERROS: $(card '.kierrokset[-1].otsikko')"
  MUUTOS=$(card '.kierrokset[-1].muutos'); DONE=$(card '.kierrokset[-1].done')
  FILES=$(card '((.tiedostot // []) + (.kierrokset[-1].tiedostot // [])) | unique | join(", ")')
  KONTEKSTI="${KONTEKSTI:+$KONTEKSTI
}$TAUSTA"
  LOG="$BOARD/log/$ID/k$KIERROS"; mkdir -p "$LOG"
fi

if [ "$MODE" != "--resume" ]; then
  # 1. Worktree: lukukortti irrallisena origin/<base>:sta, koodikortti uuteen haaraan origin/<base>:sta
  git -C "$REPO" fetch -q origin
  if [ ! -d "$WT" ]; then
    REF="$BASE"; git -C "$REPO" rev-parse -q --verify "origin/$BASE" >/dev/null && REF="origin/$BASE"
    if [ "$RO" = "true" ]; then
      git -C "$REPO" worktree add --detach "$WT" "$REF" >/dev/null
    else
      BR=$(card ".haara // \"${BRANCH_PREFIX}\(.tiketti // \"x\")-\(.id)\"")
      git -C "$REPO" worktree add "$WT" -b "$BR" "$REF" >/dev/null
    fi
  fi
  set_state build "worktree $WT"

  # 2. Toteuttaja
  # Huom: VAR="...$(cmd)" palauttaa cmd:n paluuarvon; set -e kaataa skriptin, jos ehdollinen echo ei aja -> aina '|| true'.
  BRIEF="Olet työntekijä kortille $ID. Lue ensin repon CLAUDE.md / agents.md (jos on) ja noudata niitä.
${KONTEKSTI:+Tausta-aineisto (lue ensin): $KONTEKSTI}
${TIK:+Tiketti: #$TIK}
Tehtävä: $TITLE
Muutos: $MUUTOS
${FILES:+Saat koskea vain näihin polkuihin työpuussa $WT: $FILES}
Älä kirjoita mitään työpuun ulkopuolelle (ei ~/.claude, ei taulun hakemistoon, ei muihin worktreihin). Tilapäistiedostot vain /tmp:iin.
Valmis kun: $DONE
Älä commitoi äläkä pushaa. Dokumentaatio kuuluu muutokseen: päivitä repon ohjeet samassa työssä, tai kirjaa raporttiin miksi ei ollut dokumentoitavaa. Aja testit ja lint itse ennen raporttia.
$([ "$(card '.ui // false')" = "true" ] && echo "UI-muutos: koordinaattori ottaa ennen/jälkeen-kuvakaappaukset erikseen (log/$ID/kuvat/ennen ja jalkeen). Kirjaa raporttiin, mitkä näkymät muuttuivat." || true)
Älä kysy kysymyksiä: jos jokin on epäselvää, tee perusteltu oletus ja kirjaa se raportin loppuun otsikon 'Päätettävää' alle (kysymys + suosituksesi).
Päätä vastauksesi raporttiin, joka vastaa suoraan 'Valmis kun' -riviin.$([ "$RO" = "true" ] && echo " Lukukortti: raportti on vastauksesi KOKONAISUUDESSAAN (ei lyhennelmä), ja skripti tallentaa sen itse tiedostoon ${LOG#$BOARD/}/build.md. Älä yritä kirjoittaa raporttia tiedostoon." || true)"
  if [ "$RO" = "true" ]; then TOOLS=(Read Grep Glob "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)")
  else TOOLS=(Read Grep Glob Edit Write "Bash(git diff:*)" "Bash(git status:*)" "Bash(git log:*)" "Bash(git show:*)"); fi
  # Testikomentojen ohjelmat sallitaan toteuttajalle automaattisesti (esim. "npm test" -> Bash(npm:*))
  # (git ei: toteuttaja ei saa commitoida, lukevat git-komennot on jo sallittu)
  while IFS= read -r t; do p="${t%% *}"; [ -n "$p" ] && [ "$p" != git ] && TOOLS+=("Bash($p:*)"); done < <(card ".testit // [\"$DEFAULT_TEST\"] | .[] | sub(\"^cd [^&]*&& *\"; \"\")")
  # Kortti voi antaa oman työkalulistan kentässä tyokalut: se KORVAA oletuslistan kokonaan (lukukortilla anna lukutyökalut mukaan)
  if [ "$(card '.tyokalut // [] | length')" != "0" ]; then TOOLS=(); while IFS= read -r t; do TOOLS+=("$t"); done < <(card '.tyokalut[]'); fi
  MAXT=60; [ "$RO" = "true" ] || MAXT=200
  ( cd "$WT" && "$CLI" "${MODELARG[@]}" -p "$BRIEF" --output-format json --max-turns $MAXT --add-dir "$BOARD/log" --allowedTools "${TOOLS[@]}" ) > "$LOG/build.json" || true
  jq -r '.result // "EI TULOSTA"' "$LOG/build.json" > "$LOG/build.md" 2>/dev/null || echo "EI TULOSTA" > "$LOG/build.md"
  set_state review "toteuttaja valmis, $(jq -r '.num_turns // "?"' "$LOG/build.json" 2>/dev/null || echo '?') kierrosta"
else
  [ -s "$LOG/build.md" ] || { echo "ei build.md"; exit 1; }
  set_state review "jatketaan: testit ja katselmointi"
fi

# 3. Testit ennen katselmointia (koodikortilla), jotta katselmoija saa skriptin ajaman tuloksen eikä toteuttajan väitettä
TESTSUMMARY="(lukukortti, testejä ei ajeta)"
if [ "$RO" != "true" ]; then
  set_state test
  TESTS=$(card ".testit // [\"$DEFAULT_TEST\"] | join(\" && \")")
  TESTOK=1; : > "$LOG/test.log"
  while IFS= read -r t; do
    echo "### $t" >> "$LOG/test.log"
    if ! ( cd "$WT" && bash -c "$t" ) >> "$LOG/test.log" 2>&1; then TESTOK=0; echo "### EPÄONNISTUI: $t" >> "$LOG/test.log"; fi
  done < <(card ".testit // [\"$DEFAULT_TEST\"] | .[]")
  TESTSUMMARY="Skriptin ajamat testikomennot: $TESTS
Tulos: $([ "$TESTOK" = 1 ] && echo VIHREÄ || echo PUNAINEN)
$(tail -15 "$LOG/test.log" || true)"
fi

# 4. Katselmoija: näkee valmiusehdon, tuotoksen (koodikortilla diffin) ja skriptin testituloksen
if [ "$RO" = "true" ]; then OUTPUT=$(cat "$LOG/build.md"); else OUTPUT=$(cd "$WT" && git add -A -N . && git diff)
  # Valmiusehto vaatii usein raportin osia (syy, mittaukset). Ilman raporttia katselmoija hylkää ne puuttuvina.
  OUTPUT="$OUTPUT
--- TOTEUTTAJAN RAPORTTI (${LOG#$BOARD/}/build.md; väitteitä, joita ei ole varmistettu: tarkista ne diffistä ja reposta) ---
$(cat "$LOG/build.md" 2>/dev/null || echo 'ei raporttia')"
fi
REVIEW="Olet riippumaton katselmoija. Et ole kirjoittanut tätä työtä. Tarkista vastaako tuotos TÄSMÄLLEEN tähän valmiusehtoon, ja yritä löytää puute:
Valmis kun: $DONE$([ "$RO" = "true" ] && echo " (Lukukortti: tuotos alla ON tiedosto ${LOG#$BOARD/}/build.md, skripti on tallentanut sen.)" || true)
Voit lukea repoa tarkistaaksesi väitteet.${KONTEKSTI_REVIEW:+ Tausta-aineisto, jota valmiusehto voi koskea (lue se, kun ehto viittaa tikettiin tai aineistoon): $KONTEKSTI_REVIEW} Buildia ja testejä et voi ajaa; ajoskripti on ajanut ne ja tulos on alla, luota siihen.
$TESTSUMMARY
Vastaa ensimmäisellä rivillä täsmälleen HYVÄKSYTTY tai HYLÄTTY, sen jälkeen perustelu ja hylätessä lista puutteista.
--- TUOTOS ---
$OUTPUT"
( cd "$WT" && "$CLI" "${REVIEWMODELARG[@]}" -p "$REVIEW" --output-format json --max-turns 80 --add-dir "$BOARD/log" --allowedTools Read Grep Glob "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" ) > "$LOG/review.json" || true
jq -r '.result // "EI TULOSTA"' "$LOG/review.json" > "$LOG/review.md" 2>/dev/null || echo "EI TULOSTA" > "$LOG/review.md"
VERDICT=$(head -1 "$LOG/review.md" | tr -d ' *')
[ "${TESTOK:-1}" = 1 ] || VERDICT="TESTIT_KAATUI"

# 5. Tila ja ilmoitus
case "$VERDICT" in
  HYVÄKSYTTY) if [ "$RO" = "true" ]; then set_state valmis "katselmoija hyväksyi"; else set_state pr "katselmoija ja testit ok, odottaa commit-lupaa"; set_odottaa omistaja; fi ;;
  HYLÄTTY)    set_state blocked "katselmoija hylkäsi, ks. ${LOG#$BOARD/}/review.md" ;;
  TESTIT_KAATUI) set_state blocked "testit punaiset, ks. ${LOG#$BOARD/}/test.log (katselmoija: $(head -1 "$LOG/review.md"))" ;;
  *)          set_state blocked "tulos: $VERDICT, ks. ${LOG#$BOARD/}" ;;
esac
# Kuvat: log/<ID>/kuvat/ennen/*.png ja jalkeen/*.png parit nimen mukaan -> kortin kuvat[] (selainnäkymä näyttää ne)
register_kuvat() {
  local d="$BOARD/log/$ID/kuvat" k tmp; [ -d "$d/ennen" ] || [ -d "$d/jalkeen" ] || return 0
  k=$( (cd "$d" && for f in ennen/*.png jalkeen/*.png; do [ -f "$f" ] && basename "$f"; done) | sort -u | while IFS= read -r n; do
    e="null"; j="null"; [ -f "$d/ennen/$n" ] && e="\"log/$ID/kuvat/ennen/$n\""; [ -f "$d/jalkeen/$n" ] && j="\"log/$ID/kuvat/jalkeen/$n\""
    printf '{"nimi":"%s","ennen":%s,"jalkeen":%s}\n' "${n%.png}" "$e" "$j"; done | jq -s .)
  tmp=$(mktemp); jq --arg id "$ID" --argjson k "$k" '(.cards[] | select(.id==$id)) |= (.kuvat=$k)' "$CARDS" > "$tmp" && mv "$tmp" "$CARDS"
}
register_kuvat
"$BOARD/notify.sh" "Kortti $ID" "$(card .tila): $TITLE"
