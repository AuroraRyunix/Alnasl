# Dutch glossary: Alnasl and OpenPairings

Both programs name the same things in front of the same person, so they use the
same Dutch word. Where the two differed, Alnasl moved to OpenPairings' word
(2026-10-14), unless Alnasl's was clearly better Dutch; those are listed under
"Left different on purpose". The changes made to OpenPairings follow at the end.

Source of OpenPairings' words: `priv/gettext/nl/LC_MESSAGES/default.po` and the
manual chapters `priv/manual/nl/17-live-boards.md` and `18-setting-up-boards.md`
of the OpenPairings repository. Only `msgstr` lines of Alnasl's
`priv/gettext/nl/LC_MESSAGES/default.po` change; the English `msgid`s stay.

See [glossary.md](glossary.md) for the whole list, English and Dutch side by
side. Since 2026-10-17 a sentence the server can show says "Alnasl" where it
said "het kastje", and "het eigen toernooi van de zaal" where it said "het
eigen toernooi van dit kastje"; "kastje" is left to what only a box shows.

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
| Outbox, now the page Results | Resultaten (the rail said Resultaten and the title Wachtrij until step 4 of the UI plan, 2026-10-17; both say Resultaten now, as the English says Results twice; the manual may still call what it holds "de wachtrij") |
| Round N starting | Ronde N starten |
| the Live link on the public pages | Live-link |

## Left different on purpose

| English | OpenPairings | Alnasl | Why |
|---|---|---|---|
| Result (of a game) | Resultaat | Resultaat | The owner decided on 2026-10-14 that Alnasl follows OpenPairings: a game's result is a *resultaat* ("Geen resultaat", "de drie resultaten"), the results site stays the *uitslagensite*. |
| Sent | Verstuurd, versturen | Verstuurd / versturen | Alnasl follows OpenPairings (owner's decision, 2026-10-14): "Nu versturen", "Versturen hervatten", the page Wachtrij. |
| By hand | Handmatig (and "met de hand", also in the manual) | Met de hand | Both are OpenPairings'. |
| Permission (a Lichess token's scope) | recht | Recht | Not the same thing as the box's "toestemming" to send to the results site; Alnasl has no string for the latter. |
| Results page of a tournament | (no fixed word: "pagina op de uitslagensite") | uitslagenpagina | The manual quotes Alnasl's "de uitslagenpagina en relaissleutel zijn meegekomen". |

## Decided: je

Both programs address the reader as "je" (informal), never "u" (decision of the
owner, 2026-10-14). In Alnasl the six strings that still said "u" were changed
("Borden die u later aansluit", "De borden worden voor u in het toernooi gezet",
"de code die u plakte", and three more). In OpenPairings the live-boards strings
and the whole Dutch manual were changed. Two "u" remain on purpose, in both
programs: they are quotes of Windows' own text ("Uw pc wordt beschermd" from
SmartScreen; "wilt u toestaan dat deze app communiceert..." from the firewall
prompt), which Windows says in the formal form.

## Done in OpenPairings (branch `dutch-je`)

These were suggestions in the first version of this file; they are now applied.

1. **"koppeling" means one thing.** It is the link between OpenPairings and the
   box (and Alnasl's "Koppelcode"). The Ainalrami strings that used it for
   pairing now say paring / gepaard / paren ("De paring is onverwacht
   mislukt", "Ronde N kan niet gepaard worden", "Ronde N wordt gepaard...",
   "De paring van de ploegen voor ronde N is mislukt").
2. **Resultaat and uitslag**: a game's, a round's or a match's result is a
   *resultaat*; "outcome" (a possible result in the next-round preview) is
   *uitkomst*; the results site is the *uitslagensite*. One exception: the
   Belgian SWAR publication's heading "Uitslagen" is a Dutch message id and
   stays as the federation prints it.
3. **versturen**: versturen, verstuurd, never verzenden/verzonden. The "Receipt" strings, which
   said Verzendbewijs next to Ontvangstbewijs, all say Ontvangstbewijs now.
4. **scheidsrechter** in the team match sheet is *arbiter*, like everywhere else.
5. **liveborden** (one audit-log string) is "Live borden".
6. **The manual quotes Alnasl's interface**, and these quotes were corrected
   (`priv/manual/nl/18-setting-up-boards.md`): `relaysleutel` is `relaissleutel`;
   `*Gereed*` is `*Klaar*`; `Gereconstrueerd` is `Afgeleid`; `gegokt` is
   `geraden`; `*read as d3*` is `*gelezen als d3*`; the page `Hulp` is `Help`;
   `Indeling gewijzigd in OpenPairings` is `Paring gewijzigd in OpenPairings`.
