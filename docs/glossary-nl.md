# Dutch glossary: Alnasl and OpenPairings

Both programs name the same things in front of the same person, so they use the
same Dutch word. Where the two differed, Alnasl moved to OpenPairings' word
(2026-10-14), unless Alnasl's was clearly better Dutch; those are listed as
suggestions for OpenPairings at the end.

Source of OpenPairings' words: `priv/gettext/nl/LC_MESSAGES/default.po` and the
manual chapters `priv/manual/nl/17-live-boards.md` and `18-setting-up-boards.md`
of the OpenPairings repository. Only `msgstr` lines of Alnasl's
`priv/gettext/nl/LC_MESSAGES/default.po` change; the English `msgid`s stay.

## Changed in Alnasl

| English | OpenPairings (nl) | Alnasl before | Alnasl now |
|---|---|---|---|
| the box (this program, in the hall) | kastje, bordkastje | box | kastje (`de box` becomes `het kastje`, `deze box` `dit kastje`, `boxen` `kastjes`; pronouns follow: `hij`/`hem` become `het`) |
| results site / results server | uitslagensite | uitslagenserver (and uitslagensite) | uitslagensite |
| relay key | relaissleutel | relaysleutel | relaissleutel |
| pairing, pairings | paring, paringen | indeling, indelingen | paring, paringen |
| pairing program | paringsprogramma | indelingsprogramma | paringsprogramma |
| a round that is paired | gepaard | ingedeeld | gepaard (`OpenPairings deelt in` becomes `paart`) |
| reconstructed (move mark, tile state) | afgeleid | gereconstrueerd | afgeleid (`Reconstrueren tot` becomes `Afleiden tot`) |
| guessed (move mark) | geraden | gegokt | geraden |
| rewritten (move mark) | herschreven | herschreven | herschreven (same) |
| Help (page) | Help | Hulp | Help |
| Ready | Klaar | Gereed | Klaar (also the Help line, which already said Klaar; "Uitslagensite: klaar") |
| Waiting (badge) | Wacht | Wachtend | Wacht (`Wachtend (n)` and `n wachtend` stay: they are phrases) |
| Dismiss (close a notice) | Sluiten | Negeren | Sluiten (negeren is ignore, which is not what the cross does) |

## Already the same

| English | Dutch |
|---|---|
| connect code | koppelcode |
| link (OpenPairings to Alnasl), board link | koppeling, bordkoppeling |
| withdraw a code | intrekken (ingetrokken) |
| live boards (the OpenPairings page, "Settings, Live boards") | Live borden |
| Settings, Setup | Instellingen |
| Tournaments, group | Toernooien, groep |
| round, rounds | ronde, rondes |
| board, table, table number | bord, tafel, tafelnummer |
| game, move, clock | partij, zet, klok |
| arbiter | arbiter |
| Test connection | Verbinding testen |
| State | Toestand |
| Log | Logboek |
| Labels (sheet of stickers) | Etiketten |
| Outbox | Verzendlijst (the manual's name for it; OpenPairings has no such page) |
| Round N starting | Ronde N starten |
| the Live link on the public pages | Live-link |

## Left different on purpose

| English | OpenPairings | Alnasl | Why |
|---|---|---|---|
| Result | Resultaat (and Uitslag, Uitslagen) | Uitslag | OpenPairings' own live-boards text and manual say uitslag ("de uitslag die het bord zag"); Alnasl follows that. |
| Sent | Verstuurd (78 uses of versturen, 24 of verzonden) | Verzonden / verzenden | OpenPairings mixes both; Alnasl uses verzenden throughout, as the manual's "Verzendlijst" does. |
| By hand | Handmatig (and "met de hand", also in the manual) | Met de hand | Both are OpenPairings'. |
| Permission (a Lichess token's scope) | recht | Recht | Not the same thing as the box's "toestemming" to send to the results site; Alnasl has no string for the latter. |
| Results page of a tournament | (no fixed word: "pagina op de uitslagensite") | uitslagenpagina | The manual quotes Alnasl's "de uitslagenpagina en relaissleutel zijn meegekomen". |

## Not a word, but open: je or u

Alnasl addresses the reader as "je" in most strings and "u" in a few
("Borden die u later aansluit", "De borden worden voor u in het toernooi gezet",
"de code die u plakte"). OpenPairings' live-boards strings and the manual use
"u", the rest of OpenPairings "je". Nothing changed here: it needs one decision,
then a pass.

## Suggestions for OpenPairings

Nothing below was changed in OpenPairings.

1. **"koppeling" means two things.** It is the link between OpenPairings and the
   box (and Alnasl's "Koppelcode"), but the Ainalrami strings use it for
   pairing: "De koppeling is onverwacht mislukt", "Ronde N kan niet gekoppeld
   worden", "Ronde N wordt gekoppeld...", "De ploegkoppeling voor ronde N is
   mislukt". Everywhere else the same program says paring, paren, gepaard.
   Suggest paring / gepaard there.
2. **Resultaat and uitslag** are both used for the same thing ("Result =>
   Resultaat", "Results => Uitslagen", "Bord zag", "wijkt af"). Pick one for
   the app; uitslag is the one the boards chapters already use.
3. **versturen / verzenden**: pick one ("Verstuurd" next to "Bezig met
   verzenden" in the same status badge set).
4. **scheidsrechter** in the team match sheet ("handtekeningen van de
   kapiteins en de scheidsrechter") against arbiter everywhere else.
5. **liveborden** (one audit-log string) against "Live borden".
6. **The manual quotes Alnasl's interface**, and these quotes now change
   (`priv/manual/nl/18-setting-up-boards.md`):
   - line 129 and line 365: `relaysleutel` becomes `relaissleutel`;
   - line 142: `Het moet *Gereed* zeggen` becomes `*Klaar*`;
   - line 157 and line 293: `Gereconstrueerd` becomes `Afgeleid`;
   - line 295: `gegokt` becomes `geraden`;
   - line 296: `*read as d3*` is English in the Dutch manual; Alnasl's Dutch is
     `gelezen als d3`;
   - line 299: the page `Hulp` is `Help`;
   - lines 302 and 378: `Indeling gewijzigd in OpenPairings` becomes
     `Paring gewijzigd in OpenPairings`.
