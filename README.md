# Transportlogg för Exchange Online

Ett Windowsverktyg med svenskt fönster för handläggare som behöver söka efter e-post mellan en angiven adress och verksamheten, välja relevanta träffar och skapa ett underlag för utlämning. Verktyget skickar inga mejl och läser inte mejltexter eller bilagor.

## Prova direkt

Dubbelklicka på **Starta-demo.cmd**. Ingen Exchangeanslutning eller modul behövs. Tryck på **Sök**, markera rader och välj **Exportera valda träffar**. Demorapporten, CSV-filen och det interna underlaget märks som fiktiva. Stäng fönstret för att avsluta.

Om organisationens policy blockerar PowerShellskript behöver IT distribuera/signera dem enligt ordinarie rutin. Startfilerna ändrar inte körningspolicy.

## Förberedelser för IT

1. Använd en Windowsdator med Windows PowerShell 5.1 och interaktiv inloggning. Startfilerna väljer denna miljö och STA-läge.
2. Installera en aktuell, av IT godkänd version av ExchangeOnlineManagement, minst 3.7.0, för handläggarens körmiljö. Exempel, i Windows PowerShell:

   ```powershell
   Install-Module ExchangeOnlineManagement -Scope CurrentUser -MinimumVersion 3.7.0
   ```

3. Redigera **Installningar.json**. Ange samtliga verksamhetsdomäner som sökningar ska omfatta. Matchningen är exakt; underdomäner behöver egna poster. Exempel:

   ```json
   {
     "VerksamhetensDomaner": ["kommun.se", "bolag.kommun.se"],
     "Exportmapp": "C:\\GodkandLagring\\Transportloggar"
   }
   ```

   Tom exportmapp innebär att handläggaren själv väljer lagringsplats. Inställningen är en föreslagen plats, ingen spärr. Den tomma domänlistan som levereras blockerar skarp inloggning tills IT har konfigurerat den.

   I JSON behöver bakstreck dubbleras: skriv `"C:\\temp"` eller använd `"C:/temp"`. Ett ensamt bakstreck i `"C:\temp"` gör att `\t` blir en tabulator och sökvägen blir ogiltig.

4. Tilldela och verifiera den minsta Exchange RBAC-behörighet som behövs för `Get-MessageTraceV2` och parametrarna `StartDate`, `EndDate`, `ResultSize`, `SenderAddress`, `RecipientAddress`. Utred rollerna i den egna miljön med ett administratörskonto:

   ```powershell
   Get-ManagementRole -Cmdlet Get-MessageTraceV2
   Get-ManagementRoleEntry '*\Get-MessageTraceV2'
   ```

   Utgå från resultatet när ni skapar eller väljer rollgrupp. Verktyget tilldelar inga roller. Dela inte administratörskonton mellan handläggare och ge inte Global Administrator bara för detta verktyg. Följ [Microsofts metod för att hitta cmdletbehörigheter](https://learn.microsoft.com/en-us/powershell/exchange/find-exchange-cmdlet-permissions?view=exchange-ps).

5. Bestäm godkänd lagringsplats, åtkomst, gallring och utlämningsrutin. Filer får lagringsplatsens normala behörigheter. Distribuera skript och inställningar med lämpligt skrivskydd/signering.
6. Genomför acceptanstestet nedan med handläggarens konto innan driftsättning.

Domän- och adressfiltreringen är klientfunktioner för att avgränsa sökningar. En användare med Exchangebehörighet kan köra andra kommandon utanför verktyget. Om handläggare inte ska ha den underliggande sökbehörigheten behövs en separat tjänst med serverbaserad behörighetskontroll. Det ingår inte här.

## Handläggarens arbetsgång

1. Öppna **Starta.cmd**, skriv ditt arbetskonto och tryck på **Logga in**. Microsoft hanterar inloggning och eventuell MFA. Skriptet sparar inga lösenord.
2. Ange den exakta adress som begäran gäller, normalt invånarens adress. Valfritt: ange verksamhetens exakta adress för att begränsa träffarna ytterligare.
3. Välj period och riktning. **Till verksamheten** söker angiven adress som avsändare; **Från verksamheten** söker den som mottagare. **Båda** gör båda sökningarna. Även en intern adress kan användas som sökadress.
4. Alla inmatade tider är svensk tid, oavsett datorns tidszon. Sluttiden är ett klockslag: `2026-10-20 00:00` avser början av den 20 oktober. Välj nästa dygns `00:00` för att täcka en hel dag; exakt gränstid kan ingå i båda perioderna. Standardperioden är de föregående sju hela dygnen.
5. Tryck på **Sök**. Markera relevanta rader med Ctrl/klick eller Shift/klick. Ctrl+A i träfflistan markerar alla. Inga rader väljs automatiskt. Om sökvillkor ändras rensas resultatet.
6. Kryssa endast vid behov i **Visa och exportera ämnesrad**. Granska träffarna och välj **Exportera valda träffar** samt en godkänd lagringsplats.
7. Öppna HTML-rapporten och granska innehållet enligt verksamhetens rutin innan utlämning. Skicka underlaget genom ordinarie kanal.

Varje export skapar en ny undermapp med:

| Fil | Innehåll och användning |
| --- | --- |
| Transportlogg.html | Läsbar rapport med valda träffar, sökvillkor och förklaringar. Kan öppnas i webbläsare och skrivas ut eller sparas som PDF därifrån. |
| Transportlogg.csv | Samma valda träffar, semikolonseparerat med UTF-8 BOM för svenska Excel. Ämne ingår bara om det har valts. |
| Internt-underlag.json | Internt sökunderlag med Windowsanvändare, angivet inloggningskonto, sökvillkor och valda spårnings-ID. Hantera separat från utlämningsfilerna. |

Internt-underlag.json skapas vid export, inte vid varje sökning. Det är inte en manipulationsskyddad revisionslogg. Arbetskontot är den uppgift som angavs vid inloggning, inte ett separat verifierat identitetsintyg. HTML/CSV innehåller inga interna spårnings-ID, IP-adresser eller inloggningskonton. Rapporten kan fortfarande innehålla andra personers adresser och känsliga ämnesrader; ett urval är inte automatisk maskning eller sekretessprövning.

## Vad resultatet betyder

En träff avser ett meddelande till en mottagare. Samma mejl kan därför ge flera rader. Statuskoden från Exchange bevaras tillsammans med en svensk förklaring. **Delivered** bevisar inte att mottagaren läst mejlet. För externa mottagare kan status avse leverans till mottagarens e-postsystem.

Inga träffar bevisar inte att ett mejl aldrig skickats. Kontrollera rätt adresser, alias, period och eventuell spårningsfördröjning. Gruppadresser, vidarebefordran, karantän eller oklara statusar kan kräva IT:s analys och händelsedetaljer. Verktyget hämtar sammanfattande transportstatus, inte `Get-MessageTraceDetailV2` eller postlådans innehåll.

Enligt [Microsofts dokumentation för Get-MessageTraceV2](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-messagetracev2?view=exchange-ps) är data sökbara upp till 90 dagar bakåt, högst tio dygn per anrop och högst 5 000 träffar per anrop. Verktyget delar långa perioder och fulla resultat i mindre tidsintervall och tar bort dubbletter. Om ett ensekundsintervall fortfarande är fullt avbryts sökningen utan exporterbart resultat. Sökningen begränsas också till 50 000 träffar. Meddelanden till fler än 1 000 mottagare kan kräva separat IT-sökning med `MessageTraceId`, enligt Microsoft. Rapporten ska inte användas som garanti för fullständig återgivning i sådana fall.

Anropshastigheten begränsas lokalt till högst 80 anrop per femminutersfönster. Andra klienter delar tenantens begränsning; kvarstående fel avbryter sökningen efter tre försök. Microsofts gränser och modulkrav beskrivs även i [dokumentationen om meddelandespårning](https://learn.microsoft.com/en-us/Exchange/monitoring/trace-an-email-message/message-trace-modern-eac). Fönstret arbetar synkront och kan vara upptaget under långa sökningar eller väntan på Exchange. Det finns ingen avbrytknapp i denna version.

## Kontroll och acceptanstest

Kör de fristående testerna utan Exchangeanslutning:

```powershell
powershell.exe -NoProfile -File .\Test-Transportlogg.ps1
```

Testerna verifierar bland annat svensk sommar/vintertid, ogiltiga datum/adresser, domänavgränsning, båda riktningar, stora resultat, dubbletter, felhantering, exporturval, ämnestillval, HTML-kodning och skydd mot CSV-formler. CSV-text som kan tolkas som en formel får en inledande apostrof.

Före skarp användning behöver IT jämföra resultatet med Exchange admin center för ett känt inkommande och ett känt utgående testmejl. Kontrollera även ett mejl med flera mottagare, en sökning som korsar svensk sommartidsgräns, en period över tio dygn, en tom sökning och kontots behörigheter. Verifiera att valda rader och deras tider stämmer i både rapport och CSV. Ingen skarp Exchangeanslutning har verifierats vid utvecklingen. Fönstret har startats utan startupfel, men skärmkontroll och klickflödet kunde inte verifieras i utvecklingsmiljön. Kontrollera därför även fönstrets layout och handläggarflödet lokalt i demoläget.

## Filer

`Start-Transportlogg.ps1` innehåller fönstret. `Transportlogg.Core.ps1` innehåller sök- och exportfunktioner. `Installningar.json` är IT:s konfiguration. `Starta.cmd` och `Starta-demo.cmd` är handläggarens startfiler. PowerShellfilerna sparas med UTF-8 BOM för att svenska tecken ska fungera i Windows PowerShell 5.1.
