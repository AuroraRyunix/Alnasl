# OpenPairings, OpenResults en Lichess

Alnasl weet niet wie tegen wie speelt, en het host de pagina van de toeschouwers niet. OpenPairings vertelt het de paringen en ontvangt wat de borden zagen; OpenResults toont de partijen aan het publiek; Lichess kan ze ook tonen. Dit hoofdstuk zegt hoe de drie verbonden zijn en wat elk krijgt.

## Waar de partijen heen gaan {#where-the-games-go}

Elke bestemming heeft zijn eigen wachtrij, zijn eigen pauze na een mislukking, zijn eigen regel op de pagina Wachtrij (verbonden of niet, laatste succes, hoeveel er wachten, de laatste fout in woorden), zijn eigen schakelaar en zijn eigen "Nu versturen". Ze wachten niet op elkaar.

| Bestemming | Wat ze krijgt |
| --- | --- |
| Uitslagensite (OpenResults) | Elke wijziging: de hele partij tot nu toe, met de klok |
| OpenPairings | Elke partij zoals ze staat: zetten, klokken, PGN, het resultaat dat het bord zag, hoeveel zetten afgeleid of geraden zijn |
| Lichess-uitzending | De PGN van elke partij van één ronde, telkens ze veranderd is |

Elke partij gaat naar de plaatsen van haar eigen toernooi: de uitslagenpagina van dat toernooi, de Lichess-ronde van dat toernooi, de OpenPairings waar ze vandaan komt. Een toernooi waarvan de sleutel geweigerd wordt, of dat nog niet gepubliceerd is, houdt niemand anders op.

Versturen gebeurt vanzelf: naar OpenPairings vanaf het moment dat een toernooi gekoppeld is, naar de uitslagensite vanaf het moment dat het een adres en een sleutel heeft (een partij die daarvoor opgenomen werd, gaat volledig weg). Lichess blijft uit tot je een ronde en een token invult. "Nu versturen" op de pagina Wachtrij port enkel een bestemming aan die een pauze uitzit, en zegt altijd wat hij deed of waarom hij niets deed.

## Koppelen met OpenPairings {#linking-to-openpairings}

1. In OpenPairings: Instellingen, Live borden, maak een koppelcode, voor één toernooi of voor een groep toernooien. Ze wordt één keer getoond, als een regel tekst en als QR-code met dezelfde tekst.
2. Op het kastje: Instellingen, Toernooien, plak de regel en druk op Toevoegen. Vanaf een telefoon: scan de QR-code met de eigen camera van de telefoon, kopieer de link die hij toont in plaats van hem te openen, en plak hem in het veld. Het kastje kan hem niet zelf scannen: een browser leent zijn camera enkel aan een pagina die via https geserveerd wordt, en het kastje doet dat niet.
3. De toernooien waar de code bij kan, verschijnen, elk met wat ermee meekwam: spelers, de rondes die gepaard zijn, het tempo van spel, en, als het toernooi gepubliceerd is, zijn uitslagenpagina en relaissleutel. Voor de uitslagensite typ je op het kastje niets. Een toernooi dat later aan de groep wordt toegevoegd, verschijnt vanzelf.
4. De borden worden voor je in het toernooi gezet. Met één toernooi en nog niets gespeeld in dat van het kastje zelf, spelen alle borden die het kastje kent meteen daar, met hun tafelnummer als bord; de regel onder de balk zegt het en heeft een Ongedaan maken. Bij een groep, of een partij die al bezig is, vraagt het kastje welke tafels in welk toernooi spelen, met bereiken al ingevuld: "Tafels van 5 tot 8", waarbij tafel 5 bord 1 van het toernooi is. Eén bord kan ook op de pagina Borden in een toernooi gezet worden.

Druk op "Verbinding testen": het vraagt echt na en legt mislukkingen in woorden uit (een foute code, een ingetrokken code, niemand thuis, een toernooi dat niet gepubliceerd is).

### Al je toernooien in één keer {#whole-account}

In plaats van een code per toernooi koppel je een heel OpenPairings-account:

1. Op het kastje: Instellingen, Toernooien, **Een OpenPairings-account koppelen**. Typ het adres van je OpenPairings (of `http://127.0.0.1:4000` voor een kopie op deze computer). Het wordt onthouden; op de gehoste server staat het er al.
2. OpenPairings gaat open. Meld je aan als het dat vraagt, kijk welk kastje het vraagt, en druk op **Toestaan**. Je bent terug op het kastje.
3. Het kastje heeft nu elk lopend toernooi dat je in OpenPairings mag bewerken, als eigenaar of medewerker - ook de toernooien die je later maakt. Meer dan 14 dagen geleden afgelopen, gearchiveerd of overgedragen: niet. De lijst toont het als *Al je toernooien op* de server, met het aantal.

Eigenaars en arbiters van de zaal kunnen dit. Stoppen doe je in OpenPairings (je accountpagina, Live borden) of door het hier te verwijderen. Een account heeft hoogstens 8 kastjes. De luisteraar voor het zaalnetwerk van een desktopkopie biedt dit niet aan: daar blijven de gewone codes werken.

### Wat de balk zegt {#statuses}

De balk noemt waar hij over gaat. "OpenPairings: verbonden" is de code die je plakte; "Uitslagensite: ..." is de uitslagenpagina van het toernooi. "Nog geen relaissleutel" betekent dat OpenPairings geen relaissleutel voor het toernooi bewaard heeft: in OpenPairings, Instellingen, Live borden, De uitslagensite. Het kastje begint vanzelf te versturen een paar seconden nadat de sleutel bewaard is. "Live" en het getal ernaast is de verbinding van deze browser met het kastje, niet met het internet.

### Een bord dat nergens speelt {#unlinked}

De regel onder de balk, de pagina Borden, de pagina Ronde en "Klaar voor ronde N?" zeggen allemaal "Bord 1 speelt niet in ...", met een knop om het daar te zetten. Is er een partij bezig, dan biedt de knop "deze zetten zijn bord N van ronde R" aan (de zetten blijven, onder de namen van de paring, en worden volledig verstuurd) of "opnieuw beginnen" (de partij wordt zonder resultaat gesloten en bewaard waar ze was). Een bord dat later wordt aangesloten, voegt zich vanzelf bij het enige gekoppelde toernooi, zolang dat van het kastje zelf niet gebruikt is.

### Wat naar OpenPairings teruggaat {#goes-back}

Per partij: de zetten, de klokken, de PGN en het resultaat dat het bord zag, met hoeveel zetten het kastje afgeleid of geraden heeft. Het staat daar naast de paring, in het rood als het verschilt van het resultaat dat de arbiter invoerde. Een bord voert nooit een resultaat in.

### Twee codes voor één toernooi {#two-codes}

Twee codes die bij één toernooi komen, die van een groep en die van het toernooi zelf, of de code van een desktopkopie voor deze computer en voor het netwerk van de zaal, maken één toernooi op het kastje, geen twee. De tweede code zegt "Deze code bereikt ..., dat dit kastje al heeft via ...". Is de oude code ingetrokken en een nieuwe gemaakt, druk dan onder de nieuwe op "Deze code gebruiken": het toernooi houdt zijn borden en partijen, en de oude code verdwijnt als hij niets anders meer bereikt.

### Een desktopkopie van OpenPairings {#desktop}

Met een desktopkopie van OpenPairings op dezelfde computer begint de code met `http://127.0.0.1` en werkt alles zonder internet. Zo'n code werkt niet vanaf een kastje elders in de zaal: de desktopkopie antwoordt enkel op zijn eigen computer.

### Zonder OpenPairings {#without-openpairings}

Het kastje werkt toch. Typ de uitslagenpagina in bij Instellingen (het adres van de uitslagensite, het toernooi en de relaissleutel), en zeg wie op elk bord speelt op de pagina van het bord ("Spelers") of wijs een PGN toe die het zegt. Het kastje leest geen paringen van de uitslagensite.

## De uitslagensite {#results-site}

OpenResults is waar de toeschouwers de partijen volgen. Om te zien wat zij zien: op de pagina Ronde opent "Open de uitslagensite" de live borden van de ronde in een nieuw tabblad, toont "QR" een code van de livepagina van het toernooi om in de zaal omhoog te houden, en heeft elke tegel een link "Livepagina" naar haar bord. De pagina van een bord heeft "Deze partij op de uitslagensite". Een toernooi dat niet op een uitslagensite staat, heeft geen link en zegt dat.

> [!NOTE] De openbare pagina loopt misschien met opzet achter
> De uitslagensite kan live borden achterhouden met een vertraging die haar beheerder instelt, dus een zet van een minuut geleden staat er misschien nog niet. Dat is geen fout, en er ontbreekt niets.

Een partij wordt enkel getoond voor een bord van een gepubliceerde ronde. Toont de uitslagensite niets, zie dan [Opnemen, herhalen en problemen oplossen](07-recording-and-troubleshooting.md).

## Uitzenden op Lichess {#lichess}

Twee manieren, en ze kunnen naast elkaar draaien. In beide gevallen maak je eerst een uitzending op Lichess (lichess.org/broadcast/new) en een ronde erin.

### Push: het kastje stuurt de partijen naar Lichess {#lichess-push}

1. Laat op Lichess de bron van de ronde leeg: de partijen worden gepusht. Kopieer de link naar de ronde.
2. Maak op Lichess een persoonlijk toegangstoken (lichess.org/account/oauth/token) met het recht om studies en uitzendingen aan te maken en bij te werken. Het wordt één keer getoond: kopieer het.
3. Op het kastje, Instellingen, "Lichess-uitzending": plak de link en het token, zeg welke ronde van het toernooi het is, vink "De partijen versturen" aan, Bewaren. "Testen" vraagt Lichess of het token en de ronde kloppen, en zegt in woorden wat niet klopt.
4. Vanaf dan gaat elke zet, correctie en uitslag binnen een paar seconden naar Lichess, met de klokken. De pagina Wachtrij toont Lichess als een bestemming op zich.

Het kastje heeft internet nodig. Een nieuwe ronde op Lichess is een nieuw rondenummer: pas het aan bij Instellingen als de ronde verandert.

### Pull: Lichess haalt de partijen op bij de uitslagensite {#lichess-pull}

De uitslagensite serveert elke ronde als één PGN op `https://<uitslagensite>/t/<toernooi>/live/<ronde>/pgn`. Geef dat adres aan Lichess als bron van de ronde en Lichess leest het om de paar seconden. Het kastje heeft hiervoor geen Lichess-token nodig; het moet enkel de uitslagensite bereiken. Toeschouwers op Lichess zien dan wat de uitslagensite toont, vertraging inbegrepen.
