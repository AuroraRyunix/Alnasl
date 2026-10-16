# Aan de slag

Alnasl leest de elektronische borden in een speelzaal, leidt uit de stand van de stukken de zetten af en stuurt de zetten en de kloktijden naar de uitslagensite terwijl er gespeeld wordt. Dit hoofdstuk zegt wat het is, op welke twee manieren je het draait, hoe je het installeert en wat je nakijkt voor de eerste ronde.

> [!NOTE] Het beslist nooit over een resultaat
> Een mat op het bord of twee koningen in het midden is een voorstel. Jij bevestigt het. Een bord voert nergens zelf een resultaat in.

## Wat Alnasl doet {#what-alnasl-does}

Wie tegen wie speelt, hoort Alnasl van OpenPairings. Wat elk bord zag, gaat daarheen terug, naast de paring. De zetten en de klokken gaan naar de uitslagensite (OpenResults), waar de toeschouwers ze volgen. Alnasl bewaart eerst alles zelf, dus een zaal zonder internet verliest niets: wat niet kon worden verstuurd, gaat in volgorde weg zodra de verbinding terug is.

Je werkt ermee in een browser, op het kastje zelf of op je laptop in de zaal. De pagina's staan in de balk links, in groepen:

| Groep | Pagina | Waarvoor |
| --- | --- | --- |
| Spelen | Live | Het scherm tijdens het spel: de borden van deze zaal, als tegels of als lijst |
| Spelen | Borden | Wat er aangesloten is, de tafelnummers, "Klaar voor ronde N?" |
| Spelen | Partijen | Partijen als tekst (PGN): inlezen, toewijzen, vergelijken, exporteren |
| Versturen | Resultaten | Wat naar de uitslagensite en de andere bestemmingen gegaan is, en wat nog wacht |
| Beheren | Zalen | De zalen waar je bij hoort, hun bruggen en mensen |
| Beheren | Instellingen | Koppelingen, toernooien, accounts, updates |
| Terugkijken | Logboek | Wat er gebeurd is, in zinnen |
| Terugkijken | Opnames | Alles wat de borden zeiden, ruw, om nog eens te bekijken |
| | Help | Deze handleiding |

Bovenaan de balk: de naam van het kastje (op de server: "server") en, als je meer dan één zaal hebt, de zaalkiezer. Onderaan: de accountknop, met je taal, het kleurthema en Afmelden.

Op een telefoon wordt de balk een strook bovenaan (de naam, de zaalkiezer en de accountknop) en staan de pagina's in een strook onderaan: Live, Borden, Resultaten en Meer, met de rest. Op een telefoon ontbreekt niets; het is één tik verder.

Meldingen (de uitslagensite is niet bereikbaar, een bord speelt buiten zijn toernooi, een vraag over tafels, een nieuwe versie) staan boven de pagina, hoogstens twee tegelijk. De rest wacht achter "nog 1 melding"; druk erop om ze te zien.

## Twee manieren om het te draaien {#two-ways}

Het is beide keren hetzelfde programma. Het verschil is waar het draait en wat eraan hangt.

**Een kastje in de zaal.** Een kleine computer (een Raspberry Pi, een mini-pc, de laptop van de arbiter) waaraan de borden hangen met een usb- of seriële kabel. Het leest ze zelf. Dit is het gewone geval, en het werkt zonder internet.

**De gehoste server.** Hetzelfde programma draait op een server, op alnasl.zerotwo.cloud. Een server heeft zelf geen borden: hij heeft geen poorten om te lezen. In plaats daarvan neemt hij **bruggen** aan: Arkab, een klein programma in een zaal dat de borden daar leest en via internet doorsturen (zie [Bruggen](03-bridges.md)). De pagina's zijn die je kent: de ronde, de partijen, de correcties. Het verschil is dat elke pagina altijd vraagt wie je bent, en dat accounts alleen op uitnodiging bestaan (zie [Accounts, zalen en rollen](06-accounts-and-halls.md)).

De server laat weg wat alleen een kastje kan, in plaats van het grijs te maken: borden toevoegen en de lijst met seriële poorten op de pagina Borden, simulatorborden, het paneel Updates en meestarten met Windows, de pincode en het zaalnetwerk, en de naam van het kastje. Instellingen zegt welke editie je ziet, onder "Deze kopie van Alnasl".

> [!TIP] Welke kies je?
> Borden in je eigen zaal en je wilt het simpel: een kastje in de zaal. Meerdere zalen, een arbiter thuis, of niemand wil een computer in de zaal: bruggen en de server. Je kunt ze samen gebruiken, want één brug mag meer dan één server voeden.

## Installeren {#installing}

**Windows.** Alnasl-Setup.exe installeert alleen voor jou, zonder beheerder, en zet "Alnasl" in het Startmenu. Het programma is niet ondertekend, dus de eerste keer zegt Windows "Windows heeft je pc beschermd": kies "Meer info" en dan "Toch uitvoeren". Het kleine Alnasl-venster is het programma: sluit je het, dan stopt Alnasl, en zolang het gestopt is worden de borden niet gelezen. Er is ook een zipbestand dat niets installeert: uitpakken en Alnasl.exe starten.

**Linux en de Raspberry Pi.** Eén regel installeert Alnasl als dienst die met het kastje opstart (64-bit; Debian 12, Ubuntu 22.04, Raspberry Pi OS Bookworm, of nieuwer):

```
curl -fsSL https://github.com/AuroraRyunix/Alnasl/releases/latest/download/install.sh | sudo sh
```

**Mac.** Download alnasl-macos-aarch64.zip voor een Mac met een Apple-chip (M1 en later; voor Intel-Macs is er geen build), open het en sleep Alnasl naar Programma's. Apple heeft het nog niet ondertekend, dus de eerste keer weigert macOS het te openen: klik in Systeeminstellingen, Privacy en beveiliging, op "Toch openen" bij de melding over Alnasl. Alnasl afsluiten (Cmd-Q) vraagt eerst bevestiging, want zolang het gestopt is worden de borden niet gelezen.

Open daarna de site in een browser: op het kastje zelf via `http://localhost:4040`; vanaf een laptop in het netwerk van de zaal via het adres van het kastje met dezelfde poort (Borden en Instellingen tonen het, met een QR-code voor een telefoon, zodra andere machines binnen mogen).

### Updaten {#updating}

Het kastje vraagt om het halfuur of er een nieuwere versie is en meldt dat bovenaan de pagina. Er wordt niets gedownload voor je ja zegt bij Instellingen, Updates, waar ook staat hoe groot de download is. Het herstart niet terwijl er een partij bezig is, tenzij je aandringt: de zetten tijdens de herstart worden niet gelezen. "Later" vraagt morgen opnieuw; "Niet meer vragen" stopt het zoeken, en Instellingen zet het weer aan.

### Waar je gegevens staan {#where-your-data-is}

Niet in de map van het programma. Windows: `%LOCALAPPDATA%\AlnaslData` (typ dat in de adresbalk van Verkenner). Linux, geïnstalleerd: `/var/lib/alnasl`. Mac: `~/Library/Application Support/AlnaslData`. Daarin staan de database, de PGN van elke partij, de ruwe opnames en de sleutels en codes die je geplakt hebt. Updaten en verwijderen laten die map met rust; opnieuw installeren vindt ze terug. Om naar een andere computer te verhuizen kopieer je die map terwijl Alnasl gestopt is.

Instellingen, "Deze kopie van Alnasl", zegt de versie, hoe deze kopie gestart is en waar de gegevensmap staat. Een tweede kopie die anders gestart is op dezelfde computer heeft een eigen gegevensmap: eigen borden, nummers en toernooien.

## Voor de ronde {#before-the-round}

Elke keer dezelfde korte lijst. Bij elke stap zegt een pagina in woorden wat er mis is, als er iets mis is.

1. Instellingen, Toernooien: plak de koppelcode uit OpenPairings en geef aan welke tafels in welk toernooi spelen (zie [OpenPairings, OpenResults en Lichess](05-openpairings-and-openresults.md)). Druk op "Verbinding testen".
2. Borden: elk bord moet een andere toestand tonen dan "Geen signaal", en zijn plaatje moet kloppen met de stukken erop.
3. Borden: de kolom "Beginstelling" moet bij elk bord "Juist" zeggen. Zo niet, dan noemt ze de stukken en velden. Een koning en dame die omgewisseld staan, komt het meest voor.
4. Een bord met een klok is pas "Juist" als de klok dat ook is: rechts van het bord, de hendel omhoog aan de kant van wit, zodat de tijd van wit eerst loopt.
5. Borden: geef elk bord zijn tafelnummer (zie [Borden en poorten](02-boards-and-ports.md)).
6. Borden: "Klaar voor ronde N?" moet "Klaar" zeggen. Zo niet, dan somt het per bord op wat er mis is.
7. Ronde: elke tegel moet "Wacht op begin" zeggen.

## Taal en kleuren {#language-and-colours}

De site bestaat in het Engels en het Nederlands. De taal is de jouwe, niet die van het kastje: kies ze in het accountmenu (de knop onderaan de balk, op een telefoon rechtsboven). Met een account wordt de keuze bij het account bewaard en volgt ze je naar elke browser; zonder accounts wordt ze in die browser bewaard. Hoe dan ook verandert niemand anders van taal, en deze handleiding volgt de jouwe.

Wie niets koos, leest de standaardtaal van het kastje. Een beheerder stelt die in bij Instellingen, "Dit kastje" ("Deze server"), Standaardtaal.

De kleuren komen in dezelfde thema's als OpenResults: Papier, Nacht, Bord, Leisteen en Hoog contrast, en Volg het toestel, dat het toestel volgt. Kies in het accountmenu, bij Kleurthema; dat is de enige plek. De keuze geldt alleen voor die browser. Hoog contrast is voor een projector achteraan de zaal.

Er kunnen meer thema's bij als themapakketten: een map per thema, in de map `themes` binnen de gegevensmap. Bij de volgende keer laden staan ze na de ingebouwde thema's. Een pakket dat het kastje niet wil laden, staat in het grijs in de lijst, met de reden.
