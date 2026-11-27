# Lennonjohto

Tapa käyttää Claude Codea niin, että keskusteluistunto toimii **lennonjohtona** eikä kirjoita itse koodia. Lennonjohto pilkkoo työn **korteiksi**. Jokainen kortti ajetaan taustalla omassa git-worktreessään:

1. **Toteuttaja-agentti** tekee muutoksen.
2. **Skripti ajaa testit**.
3. **Riippumaton katselmoija-agentti** tarkistaa tuloksen kortin valmiusehtoa vasten.

Sinä näet taulun, päätät ja annat luvat. Commit, push ja PR tehdään vain sinun luvallasi.

```
sinä ──► lennonjohto (Claude-istunto) ──► cards.json ──► card-run.sh K-0001 (taustalla)
                                                           ├─ git worktree, oma haara
                                                           ├─ toteuttaja (claude -p)
                                                           ├─ testit (skripti ajaa itse)
                                                           └─ katselmoija (claude -p, eri malli)
                                                                → pr / blocked → ilmoitus
```

Miksi näin:
- **Keskustelu pysyy vapaana.** Voit jutella, suunnitella ja ottaa uusia asioita, kun kortit pyörivät taustalla.
- **Katselmoija ei näe toteuttajan perusteluja.** Se näkee vain valmiusehdon, diffin ja skriptin ajaman testituloksen, joten "testit menivät läpi" -väitteeseen ei voi nojata.
- **Korjaukset tehdään kierroksina samaan korttiin** (`card-round.sh`). Historia pysyy yhdessä paikassa, eikä synny uusia haaroja.

## Vaatimukset

- [Claude Code](https://claude.com/claude-code) -CLI (`claude`), `git`, `jq`, `python3`, `bash`
- PR-synkkaan `gh` (GitHub) tai `az` + `azure-devops`-laajennus (Azure DevOps). Synkka ei ole pakollinen.
- macOS tai Linux

## Asennus

```bash
git clone <tämä repo> ~/lennonjohto
cd ~/lennonjohto
cp lennonjohto.conf.example lennonjohto.conf   # muokkaa: REPO, WT_PREFIX, BASE_BRANCH, PR_PROVIDER ...
cp cards.example.json cards.json               # tai aloita tyhjästä: echo '{"cards": []}' > cards.json
./board.sh                                     # taulu terminaaliin
./board.sh --web                               # taulu selaimeen (http://127.0.0.1:8765/board.html)
```

`cards.json`, `lennonjohto.conf`, `config.json` ja `log/` ovat `.gitignore`ssa. Ne sisältävät oman työsi tietoja, eikä niitä kannata jakaa.

Tämän jälkeen lisää alla oleva lennonjohtajan ohje sen **koodirepon** `CLAUDE.md`:hen, jossa avaat lennonjohtoistunnon, tai omaan `~/.claude/CLAUDE.md`:hesi.

## Komennot

| Komento | Mitä tekee |
|---|---|
| `./card-run.sh K-0001` | Ajaa kortin koko silmukan. Käynnistä taustalle: `nohup ./card-run.sh K-0001 > log/K-0001-run.out 2>&1 &` |
| `./card-run.sh K-0001 --resume` | Toteuttaja on jo valmis, joten ajaa vain testit ja katselmoinnin uudelleen |
| `./card-round.sh K-0001 "otsikko" "muutos" "valmis kun" [polku ...]` | Lisää korttiin korjauskierroksen ja käynnistää sen taustalle |
| `./board.sh` / `--all` / `--watch` | Taulu terminaaliin |
| `./board.sh K-0001` | Kortin tiedot, historia, päätettävät asiat ja lokien alku |
| `./board.sh --sync` | Päivittää PR-korttien tilan PR:n perusteella (mergetty → valmis, muutospyyntö → odottaa sinua jne.) |
| `./board.sh --web` | Selainnäkymä. Synkka pyörii 3 minuutin välein niin kauan kuin palvelin on pystyssä |
| `./notify.sh "otsikko" "viesti"` | Työpöytäilmoitus. Toimii myös Claude Coden Notification-hookina |

Lokit tallentuvat hakemistoon `log/<ID>/`, ja kierrokset hakemistoon `log/<ID>/k<N>/`:
- `build.md` on toteuttajan raportti
- `test.log` on testien tulos
- `review.md` on katselmoijan tuomio; ensimmäinen rivi on `HYVÄKSYTTY` tai `HYLÄTTY`.

## Kortin rakenne

```json
{
  "id": "K-0001",
  "tiketti": 123,
  "otsikko": "Lyhyt otsikko",
  "muutos": "Mitä tehdään, missä tiedostoissa, mitä testataan. Kirjoita kuin briiffaisit kollegaa, joka ei tiedä taustaa.",
  "done": "Valmis kun: tarkistettava lista, jota katselmoija vertaa tuotokseen.",
  "tiedostot": ["src/", "test/", "docs/"],
  "testit": ["npm ci", "npm test"],
  "readonly": false,
  "ui": false,
  "base": "main",
  "haara": "feature/123-lyhyt-kuvaus",
  "konteksti": null,
  "tyokalut": [],
  "tila": "todo",
  "paatokset": [],
  "historia": []
}
```

Kenttien merkitys:
- **`readonly: true`** tarkoittaa lukukorttia eli selvitystä. Worktree on irrallinen, ei synny haaraa eikä ajeta testejä, ja raportti on tuotos. Kortti päättyy tilaan `valmis`.
- **`tyokalut`** korvaa toteuttajan työkalulistan kokonaan, esimerkiksi `["Read","Grep","Glob","Bash(docker:*)"]`. Anna lista aina kokonaisena. Jos kopioit kortin pohjaksi toisesta kortista, tarkista että lista kopioituu mukaan.
- **`testit`** ajetaan worktreen juuresta yksi kerrallaan. Niiden ohjelmat (esim. `npm`) sallitaan toteuttajalle automaattisesti.
- **`konteksti`** on taustamateriaali, jonka toteuttaja lukee ensin, esimerkiksi aiemman selvityskortin `log/K-0003/build.md` tai tiketin teksti tiedostona. Katselmoija saa saman aineiston, jotta se voi tarkistaa siihen viittaavat ehdot. Jos agentit eivät pääse lukemaan tikettiä itse, tallenna tiketin teksti `log/<ID>/`-hakemistoon ja anna se tässä.
- **`paatokset`**: toteuttaja ei kysy, vaan kirjaa epäselvät asiat raportin "Päätettävää"-osioon. Lennonjohto nostaa ne sinulle.

Tilat ja niiden siirtymät:
- Normaali kulku: `todo` → `build` → `review` → `test` → `pr`, ja kun PR on mergetty, `valmis`.
- Katselmoija hylkää tai testit ovat punaiset: kortti menee tilaan `blocked`.
- Odottamaan jätetty kortti on tilassa `hold`.
- Kun kortti on tilassa `pr`, kenttä `odottaa` on `omistaja` tai `katselmoija`.

## Lennonjohtajan ohje (CLAUDE.md:hen)

Kopioi tämä ohje ja muokkaa polut omiksesi:

```markdown
## Lennonjohto

Toimit lennonjohtona: et toteuta koodimuutoksia itse tässä keskustelussa, vaan teet niistä kortit
tauluun ~/lennonjohto (README kertoo rakenteen ja komennot).

- **Uusi työ omaan korttiin.** Tiketti (jos käytössä) + kortti cards.json:iin + `card-run.sh` taustalle
  (`nohup ./card-run.sh K-xxxx > log/K-xxxx-run.out 2>&1 &`). Keskustelu pysyy vapaana.
  Poikkeus: tiivis iterointi (design, pieni kysymys) tehdään suoraan keskustelussa.
- **Kortin briiffi on ainoa mitä agentti tietää.** Kirjoita `muutos` niin, että se kertoo tiedostot,
  rivit, syyn, rajauksen (mitä EI tehdä) ja testit. `done` on tarkistettava lista, ei "toimii".
- **Selvitys ennen korjausta.** Epäselvä bugi → ensin lukukortti (`readonly: true`), sen raportti
  `konteksti`ksi korjauskortille.
- **Korjaukset samaan korttiin kierroksena** (`card-round.sh`), ei uutta korttia olemassa olevan PR:n korjaukselle.
- **Kun kortti valmistuu:** lue `log/<ID>/build.md` ja `review.md`, kerro tulos lyhyesti sanoin
  (ei pelkkä numero), nosta "Päätettävää"-kohdat käyttäjälle.
- **Commit, push, PR, PR-kommentit, tiketin tilan muutos, poistot: vain käyttäjän erillisellä luvalla.**
  Ennen committia näytä haara, diff ja mitä dokumentaatiota päivitettiin. "Voitko X?" on kysymys, ei lupa.
- **Ennen PR:ää oma katselmointi** (`/code-review` worktreen polulla). Löydökset kortille kierroksena.
- **PR:n jälkeen** merkitse kortille `pr`-numero ja `tila: "pr"`; `board.sh --sync` hoitaa loput.
- **Odota korttia** seuraamalla `log/K-xxxx-run.out`:n tilarivejä, älä aja samaa korttia kahdesti.
```

## Opittua

- **Katselmoija hylkää paljon**, ja se on tarkoitus. Hylkäys on halpa, rikkinäinen PR kallis. Kun katselmoija hylkää, tee korjaus kierroksena tai tarkenna valmiusehtoa. Älä ohita katselmointia.
- **Katselmoija ei voi ajaa testejä**, vaan luottaa skriptin tulokseen. Laita siksi `testit`-listaan kaikki, mitä CI ajaa, myös lint ja build.
- **`card-run.sh` ajaa itsensä kopiosta.** Voit muokata skriptiä, vaikka kortteja on käynnissä.
- **UI-muutoksissa** (`ui: true`) ota ennen- ja jälkeen-kuvat hakemistoihin `log/<ID>/kuvat/ennen/` ja `log/<ID>/kuvat/jalkeen/` samoilla tiedostonimillä. Selainnäkymä näyttää ne pareina.
- **Mallit:** toteuttaja voi olla nopeampi malli, mutta katselmoijan kannattaa olla vahvin malli (`IMPL_MODEL`, `REVIEW_MODEL`).
