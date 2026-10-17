# Glossary: one word per thing

Step 4 of [plan-ui-redesign.md](plan-ui-redesign.md), section H. The screens,
the flash messages, the page titles, the log and the manual use these words
and no others, in English and in Dutch. Dutch addresses the reader as *je*.
The Dutch choices shared with OpenPairings, and why, are in
[glossary-nl.md](glossary-nl.md); this file is the list to check a new string
against. `test/alnasl_web/glossary_test.exs` keeps the retired words out of
the English catalogue.

## The things

| Concept | English | Dutch | Not |
|---|---|---|---|
| The program, whichever edition | Alnasl | Alnasl | "the box" in a sentence the server also shows |
| Alnasl running in a hall, on its own machine | box | kastje | box (in Dutch), relay |
| The hosted Alnasl at alnasl.zerotwo.cloud | server | server | box |
| One running installation, when two must be told apart | copy of Alnasl | Alnasl (deze / een andere) | box |
| OpenResults, where spectators follow the games | results site | uitslagensite | results server, results page, server |
| One tournament's page on the results site | results page | uitslagenpagina | |
| Arkab, the program that reads boards in another hall | bridge | brug | relay, agent |
| A connect code or an account link to OpenPairings | connection | koppeling | link (alone) |
| The code from OpenPairings | connect code | koppelcode | |
| A room with tables and boards | hall | zaal | room, venue |
| The tournament a hall keeps for boards nobody paired | the hall's own tournament | het eigen toernooi van de zaal | this box's own tournament, "This box" as a name |
| An electronic chessboard | board, live board, electronic board | bord, live bord, elektronisch bord | the brand's name |
| The number on the table | table number | tafelnummer | |
| The board of a round (OpenPairings' number) | board N | bord N | |
| A pairing | pairing | paring | indeling |
| The key that lets Alnasl send to the results site | relay key | relaissleutel | relaysleutel |
| A game's outcome | result | resultaat | uitslag (that is the site) |
| A person who looks after the games | arbiter | arbiter | scheidsrechter |
| Someone who watches only | viewer | kijker | spectator (that is the results site's public) |
| Someone who reads the results site | spectator | toeschouwer | |
| The person who changed a game | the arbiter in Alnasl ("Arbiter in Alnasl: ...") | arbiter in Alnasl | arbiter at the box |
| A game kept but not sent | stays in Alnasl | blijft in Alnasl | stays on the box |

## The pages

The rail and the page title say the same word.

| Page | English | Dutch |
|---|---|---|
| `/` | Live | Live |
| `/boards` | Boards | Borden |
| `/pgn` | Games | Partijen |
| `/outbox` | Results | Resultaten (no longer "Outbox" / "Wachtrij" in the title) |
| `/halls` | Halls | Zalen |
| `/setup` | Setup | Instellingen |
| `/log` | Log | Logboek |
| `/recordings` | Recordings | Opnames |
| `/help` | Help | Help |

## Names, not words

Left as they are, in both languages: Alnasl, Arkab, OpenPairings, OpenResults,
Lichess, 02cloud, PGN, FEN, QR, PIN, and the language names in the language
picker ("English", "Nederlands"), which are shown in their own language on
purpose. An OpenPairings that gives no name of its own is called
"OpenPairings".

## Box-only sentences

A sentence that only a box can show - serial ports, the PIN, the hall network,
updates, starting with Windows, a box without accounts - may say "box"
(Dutch: "kastje"). Anything the server can show says "Alnasl", "this hall" or
"the results site" instead.
