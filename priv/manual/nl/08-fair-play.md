# Fair-playscreening

Alnasl kan de zetten in de partijen die de borden vastleggen naast een sterke schaakengine leggen en de eigenaar van de zaal laten zien welke spelers vaker dezelfde zetten speelden als de engine, en minder verloren, dan hun rating voorspelt. Het is een reden om een partij beter te bekijken. Het is geen bewijs, geen beschuldiging en voor niemand zichtbaar behalve de eigenaar.

## Wat het is, en wat niet {#what-it-is}

Het is een screening: een getal per speler per toernooi, met de aantallen erachter, zodat een eigenaar die twijfelt iets heeft om naar te kijken naast een onderbuikgevoel.

Het is **niet** de methode die FIDE heeft goedgekeurd. De FIDE Fair Play Regulations (door de Raad goedgekeurd in november 2024) zeggen in art. 1.6 dat voorlopig alleen de methodologie van prof. Kenneth W. Regan is goedgekeurd, en art. 1.5 zegt dat een vermoeden van valsspelen alleen uit een goedgekeurd algoritme kan komen. Het getal van Alnasl is op dezelfde ideeën gebouwd, maar het is een ander programma met een eigen kalibratie, en het mag nooit aangehaald worden alsof het van FIDE is. Elke pagina van het rapport zegt dat.

Het kijkt alleen naar de zetten. Het kijkt niet naar de spelers, de borden, de telefoons of de klok, en het zegt niet waarom een speler speelde zoals hij speelde.

Het wijst alleen op opvallend sterk spel. Zwak spel is niemands zaak.

## Wie het ziet {#who-sees-it}

**De eigenaar van de zaal, en niemand anders.** Niet de arbiters, niet de kijkers, en ook niet de beheerder van de Alnasl-server: een beheerder kan elke zaal beheren en ziet toch niets van de fair play van een andere zaal. De pagina staat in niemand anders' menu en wordt voor iedereen anders beantwoord als een pagina die er niet is.

Een kastje zonder accounts kent geen eigenaren om uit elkaar te houden: iedereen op het netwerk van de zaal is daar eigenaar, zoals bij al het andere, dus de instellingen en het rapport staan voor allemaal open. Maak het eerste account (Instellingen, Toegang) voordat je fair play aanzet als dat in jouw zaal uitmaakt.

Telkens als de eigenaar een rapport of de pagina van een speler opent, schrijft Alnasl op wie en wanneer, en het rapport toont de laatste keren dat het geopend is.

Gegevens over fair play staan nooit op de uitslagenpagina's, in de PGN-bestanden, in wat naar OpenResults of Lichess gaat, in het logboek van de arbiter of in de wachtrij van de resultaten. Ze staan in de database van de Alnasl van de zaal en op het scherm van de eigenaar.

## Aanzetten, en de engine {#installing-the-engine}

Open de zaal (Zalen, de naam van de zaal) en druk op **Fair-playscreening**. Het staat **uit** tot je het aanzet, zaal per zaal.

Alnasl heeft een engine nodig om het werk te doen: Stockfish 19, de officiële release. Alnasl wordt er niet mee geleverd. De pagina toont of hij geïnstalleerd is.

1. Druk op **Stockfish 19 downloaden**. Alnasl haalt het officiële bestand op bij GitHub, controleert dat het precies het bestand is dat gepubliceerd werd, haalt het programma eruit en laat Stockfish zijn eigen test (`bench`) draaien om zeker te zijn dat het de build is waarvoor de getallen gekalibreerd zijn.
2. Wacht een minuutje. De status zegt **Geïnstalleerd**, met de versie.
3. Zet het fair-playscreening aan.

**Geen internet in de zaal?** Download het bestand op een andere computer, van de releasepagina van Stockfish 19 op GitHub (`official-stockfish/Stockfish`, tag `sf_19`): `stockfish-windows-x86-64-universal.zip` voor Windows, `stockfish-macos-universal.tar.gz` voor een Mac, `stockfish-linux-x86-64-universal.tar.gz` voor Linux (de arm64-versies voor ARM-computers). Neem het mee op een USB-stick, druk op **Kies een bestand** en kies het. Dezelfde controles gebeuren. Een bestand dat niet het officiële is, wordt geweigerd met een zin die zegt waarom.

> [!NOTE] Oudere Intel-Macs
> De Mac-build draait misschien niet op de oudste macOS-versies. Als de test mislukt, zegt de pagina dat en wordt er niets geïnstalleerd.

Vanaf dan analyseert Alnasl elke zet zodra de tracker er zeker van is, op de achtergrond en met de laagste prioriteit die de computer biedt, met een paar engines tegelijk (het aantal kernen min één; één op de Alnasl-server). Niets daarvan vertraagt de borden: als de wachtrij vol is, wacht een partij, en de volgende zet van die partij zet hem opnieuw in de rij.

Stockfish is vrije software (GPL-3.0), van stockfishchess.org. Alnasl draait het als apart programma en geeft het nooit door.

## Het rapport {#the-report}

Onder **Rapporten** op dezelfde pagina open je het rapport van een toernooi. Het toont de spelers, hoogste score eerst, t/m de ronde die je kiest (of alleen die ronde). Per speler:

- **Getelde zetten**: hoeveel zetten in de getallen zitten (hieronder: wat niet meetelt).
- **Zelfde zet als de engine**, en wat daarvan **verwacht** werd voor de rating van die speler in die stellingen.
- **Gemiddeld verlies**, en wat verwacht werd. Het verlies is hoeveel slechter de gespeelde zet was dan de beste van de engine, geschaald zodat een pion weggooien in een gelijke stelling zwaarder weegt dan een pion weggooien als je twee pionnen voor staat.
- **Score**, met het interval, en een van de twee formuleringen hieronder.
- **Niet meegeteld**: hoeveel zetten niet meetelden, en waarom.

Druk op de naam van een speler voor de **stellingen om te bekijken**: de zetten van die speler die de eerste keuze van de engine waren, waar die keuze het meest afstak van de tweede, elk op een bord met de gespeelde zet en de vier beste van de engine.

### Zetten die niet meetellen {#left-out}

Een zet zegt niets over de speler, of Alnasl weet niet zeker dat hij gespeeld is, in deze gevallen. Elk wordt geteld en getoond:

| Niet meegeteld | Waarom |
| --- | --- |
| geen rating | Zonder rating is er niets om mee te vergelijken. Ratings komen uit de paring |
| geraden door de tracker | De tracker wist niet zeker wat er gespeeld werd, en dat geldt ook voor elke zet erna in die partij |
| herschreven, uitslag nog niet bevestigd | De tracker heeft hem gecorrigeerd en de arbiter heeft de uitslag nog niet bevestigd |
| opening (zet 1 tot 8) | Theorie, geen denkwerk |
| herhaalde stelling | Dezelfde stelling stond eerder op het bord |
| gedwongen zet | Maar één legale zet, of de beste is twee pionnen beter dan de tweede |
| minder dan een minuut op de klok | Als de klok bekend is |
| beslist | De engine ziet vóór de zet één kant meer dan drie pionnen voor |
| niet geanalyseerd | De engine gaf geen antwoord |

Een speler krijgt alleen een score bij minstens 40 getelde zetten in het toernooi; daaronder zegt het rapport **te weinig zetten**.

## Wat de getallen betekenen {#what-the-numbers-mean}

De **verwachte** waarden komen uit een model dat gefit is op echte partijen uit toernooien aan het bord (Lichess-uitzendingen, met FIDE-ratings en klokken): hoe vaak wordt voor een speler met die rating, in een stelling met zoveel goede zetten, de eerste keuze van de engine gespeeld, en hoeveel gaat er gemiddeld verloren. De **score** is hoe ver de speler van die verwachting af zit, in standaarddeviaties, waarbij de drie maten (de eerste keuze spelen, een even goede zet spelen, het verlies) samen genomen worden. Nul is zoals verwacht. Hoger is sterker dan de rating voorspelt.

- **Vanaf 2: "de moeite van een nader onderzoek waard".** Zulke scores komen bij een paar van elke honderd eerlijke spelers toevallig voor. Kijk naar de partijen, niet naar het getal.
- **Boven 5: "statistisch zeer ongewoon".** Eerlijke spelers hebben zo'n score in een model dat past vrijwel nooit. Het is nog steeds geen bewijs van iets, en het volgende onderdeel zegt wat je ermee mag doen.

Die twee woorden en die twee getallen zijn van Alnasl zelf, voor zijn eigen score. Het zijn niet de drempels van FIDE (de 5,00 van FIDE voor spel aan het bord hoort bij de goedgekeurde methode, en de 2,50 steunt alleen ander bewijs), en een 5 hier is geen 5 daar.

Het interval naast de score is het bereik waarin de werkelijke stand van de speler waarschijnlijk ligt: een score van 2,4 uit 40 zetten verschilt niet veel van een score van 0,5.

> [!IMPORTANT] Geen kalibratie, geen score
> Het model is een bestand dat bij één engine-build hoort. Zolang Alnasl er geen heeft voor de engine die je installeerde, toont het rapport de aantallen en zegt het duidelijk dat er **geen score** is. De aantallen kloppen. Ze zijn geen score en moeten niet als een score gelezen worden. Het model is gemaakt voor standaard bedenktijden; rapid en blitz zijn niet gekalibreerd.

Wat de screening niet kan zien: een partij die zonder de borden gespeeld is, een zet die de tracker niet kon lezen, openingskennis, een speler die gewoon veel sterker is dan zijn rating, een speler die één variant erg goed voorbereid heeft. Sterke, eenvoudige, gedwongen ogende stellingen geven veel overeenkomst zonder dat iemand iets verkeerd doet.

## De regels waaraan je gebonden bent {#the-rules}

Uit de FIDE Fair Play Regulations 2024:

- **Art. 1.6**: alleen de goedgekeurde methodologie (die van Regan) kan een vermoeden dragen; voor spel aan het bord is de drempel 5,00, en 2,50 of meer alleen ter ondersteuning van ander bewijs. De screening van Alnasl is dat niet en zegt dat ook.
- **Art. 1.7**: een roekeloze of kennelijk ongegronde beschuldiging is zelf een overtreding. Een speler, een ouder, de organisator of de zaal vertellen dat "de computer het zegt" is precies dat, als je alleen dit scherm hebt. Een vermoeden in vertrouwen aan een arbiter melden mag wel.
- **Art. 3.1.2 a**: de hoofdarbiter (of de Chief Fair Play Officer) mag een zaak melden aan de FIDE Fair Play Commission.
- **Art. 3.2.12**: strikte vertrouwelijkheid. Dit rapport is vertrouwelijk. Print het niet, stuur het niet rond en laat het aan niemand zien die geen deel van de procedure is.

## Wat te doen met een opvallende score {#unusual-score}

1. **Controleer eerst de gegevens.** Open de pagina van de speler. Zijn er veel of weinig getelde zetten? Zijn er veel zetten niet meegeteld omdat de tracker ze raadde of herschreef? Zijn de partijen de hele tijd op de borden gespeeld? Lijken de genoemde stellingen op stellingen waarin alleen een goede zet verstandig is?
2. **Vertel het niet aan de speler en niet aan iemand anders.** Nog niet, en niet in de zaal. Dat is art. 1.7 en art. 3.2.12.
3. **Als je nog steeds reden tot zorg hebt**, zeg het in vertrouwen tegen de hoofdarbiter. De hoofdarbiter mag de zaak melden aan de FIDE Fair Play Commission (art. 3.1.2 a) en **vraagt daar om een echte analyse**, volgens de goedgekeurde methode. Die analyse telt, niet dit scherm.
4. **Bewaar de gegevens zolang de zaak loopt** (hieronder), en schrijf op waarom.

Een eigenaar die niet de hoofdarbiter van het toernooi is, geeft de zaak aan die hoofdarbiter en beslist zelf niets.

## Hoe lang het bewaard blijft {#retention}

De analyse van een toernooi, en de lijst van wie de rapporten opende, worden verwijderd **30 dagen na de laatste ronde van het toernooi** (de laatste keer dat een partij ervan beëindigd of gewijzigd werd). Eén keer per dag ruimt een taak ze op. De beheerder van de installatie kan het aantal dagen veranderen (`ALNASL_FAIR_PLAY_RETENTION_DAYS`).

Een zaak die naar de FIDE Fair Play Commission gaat, heeft de gegevens misschien langer nodig. Geef op het rapport van het toernooi, onder **Hoe lang dit bewaard blijft**, een aantal dagen na de laatste ronde, **hoogstens 365**, en **een reden**. De reden wordt ermee bewaard. Als die datum voorbij is, gaat alles weg.

Fair play uitzetten stopt de analyse van nieuwe zetten. Wat er al is, wordt niet verwijderd; dat doet de bewaartermijn.
