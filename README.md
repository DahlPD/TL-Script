# Transportlogg – direkt mot Microsoft Graph

Handläggaren öppnar **Handläggare/Starta.cmd**, loggar in med arbetskontot och söker transportloggar. Skriptet använder inbyggd Windows PowerShell 5.1 och .NET för HTTPS-anrop direkt till Microsoft Graph.

**Inga extra program eller PowerShellmoduler behöver installeras på klienterna.** Ingen Azure Function, Azure-prenumeration, lokal server, klienthemlighet eller certifikat behövs för denna version.

IT konfigurerar en publik klientapp med tillhörande Enterprise Application i Entra och ger administratörsgodkännande för den **delegerade** behörigheten `ExchangeMessageTrace.Read.All`. Microsofts separata förberedelse för Message Trace-API:t behövs också. [Steg-för-steg-guiden för IT](IT-KONFIGURATION-STEG-FOR-STEG.md) beskriver hela konfigurationen i webbläsaren.

## Handläggarens fem filer

Distribuera hela mappen **[Handläggare](Handläggare/)**:

| Fil | Funktion |
| --- | --- |
| Starta.cmd | Startas med dubbelklick. |
| Start-Transportlogg.ps1 | Fönster, träfflista och arbetsflöde. |
| Transportlogg.Client.ps1 | Microsoftinloggning och direkta Graph-anrop. |
| Transportlogg.Core.ps1 | Datum, sökfilter och rapportexport. |
| Installningar.json | Tenant ID, klient-ID, verksamhetsdomäner och valfri exportmapp. Fylls i av IT. |

Inga andra projektfiler behövs på handläggarens dator. Testfilerna, demostarten och dokumentationen i projektroten är till för IT och utveckling.

## Prova utan inloggning

Dubbelklicka på **Starta-demo.cmd** i projektroten. Tryck på Sök och exportera valda fiktiva träffar. Alla demorapporter märks som fiktiva. Tomma app-ID:n är tillåtna i demoläget.

## Inställningar för riktig användning

```json
{
  "TenantId": "ORGANISATIONENS-TENANT-GUID",
  "ClientId": "APPREGISTRERINGENS-CLIENT-GUID",
  "VerksamhetensDomaner": ["kommun.se", "bolag.kommun.se"],
  "Exportmapp": ""
}
```

Lägg aldrig lösenord eller klienthemligheter i inställningsfilen. Domäner är exakta lokala sökfilter; underdomäner anges separat. De är **inte en central behörighetsgräns**. En användare som har fått Graph-åtkomst kan använda den utanför vårt gränssnitt. Begränsa därför applikationens användare i Entra och tilldela åtkomst efter verksamhetens behov.

Tom exportmapp innebär att handläggaren väljer plats. En förvald mapp är ingen lagringsspärr. Använd exempelvis `C:/GodkandLagring` eller dubbla bakstreck i JSON. Ett ensamt bakstreck i `C:\temp` gör `\t` till en tabulator.

## Handläggarens arbetsgång

1. Öppna **Starta.cmd** och välj **Logga in**.
2. Välj **Öppna inloggning**, ange engångskoden hos Microsoft och logga in med arbetskontot. Följ eventuell MFA och återvänd till verktyget.
3. Verktyget kontrollerar åtkomst till transportloggar innan Sök aktiveras. En lyckad Microsoftinloggning räcker inte om API:t nekar åtkomst.
4. Ange adressen som begäran gäller och vid behov verksamhetens exakta adress. Välj period och riktning och tryck på **Sök**.
5. Markera relevanta rader med Ctrl/klick eller Shift/klick. Ctrl+A i listan markerar alla. Inga rader väljs automatiskt.
6. Välj ämnesrad endast om den behövs. Ändras ämnestillvalet efter en sökning rensas resultatet; sök igen.
7. Välj **Exportera valda träffar**, välj godkänd lagringsplats och granska rapporten före utlämning.

Alla datum anges i svensk tid. Standardperioden är föregående sju hela dygn. Sluttiden `2026-10-20 00:00` betyder början av den 20 oktober. Ange nästa dygns `00:00` för en hel dag; exakt gränstid kan ingå i två intilliggande sökningar. Tvetydiga eller ogiltiga klockslag vid tidsomställning avvisas.

Åtkomsttoken finns endast i processens minne och förnyas inte automatiskt. När giltigheten löpt ut behöver användaren logga in igen. Graph-token avkodas inte av klienten. Ett visningsnamn kan läsas ur den separata ID-token som Microsoft returnerar för vår egen klient; namnet används inte för behörighetsbeslut.

## Export

| Fil | Innehåll |
| --- | --- |
| Transportlogg.html | Läsbar rapport med valda rader och sökvillkor. Kan skrivas ut eller sparas som PDF via webbläsaren. |
| Transportlogg.csv | Samma valda rader, semikolonseparerat med UTF-8 BOM för svenska Excel. |
| Internt-underlag.json | Windowsanvändare, visat kontonamn, sökvillkor och valda spårnings-ID. Hantera separat från utlämningsfilerna. |

Ämne visas och exporteras endast när det valts. Graph kan returnera ämnet i API-svaret även när det inte visas; klienten rensar det då ur sitt färdiga sökresultat. Inga mejltexter eller bilagor hämtas. Rapporten kan ändå innehålla personuppgifter. Radurval ersätter inte granskning eller maskning enligt verksamhetens rutin.

CSV-formler neutraliseras och HTML kodas som text. Filer får lagringsplatsens vanliga behörigheter. Det interna underlaget är ingen manipulationsskyddad revisionslogg. Ingen central applikationslogg eller användarbehörighetskontroll utöver Microsofts åtkomstkontroll ingår i direktversionen.

## Tolkning, gränser och verifiering

Varje rad gäller ett meddelande till en mottagare. **Levererat** visar transportstatus och är inget läskvitto. För externa mottagare kan det avse deras e-postsystem. Inga träffar bevisar inte att ett mejl aldrig har skickats. Kontrollera adresser, alias, tidsperiod och spårningsfördröjning. Grupper och vidarebefordran kan behöva utredas av IT.

API:t stöder upp till 90 dagars historik och tio dygn per anrop. Klienten delar perioder och följer `@odata.nextLink`. Sökningar begränsas till 10 000 träffar i gränssnittet. Vid fel eller för stort resultat avbryts sökningen utan exporterbart delresultat. Graphs 429/503/504 hanteras med begränsade återförsök och `Retry-After`; längre väntan ger ett fel och användaren försöker senare. Fönstret kan vara upptaget under sökningen. [Microsofts API-referens](https://learn.microsoft.com/en-us/graph/api/messagetracingroot-list-messagetraces?view=graph-rest-1.0).

IT måste verifiera direktåtkomsten med ett vanligt testhandläggarkonto **utan Exchange-adminroller** innan användning. Dokumentationen anger delegerat stöd, men någon faktisk tenantanslutning eller sådan kontoåtkomst har inte verifierats vid utvecklingen. Organisationens Conditional Access måste tillåta device code. Skriptkörning, inbyggd Windows PowerShell 5.1 och WinForms måste vara tillåtna på datorn; verktyget ändrar ingen säkerhetspolicy.

Offlinekontroller:

```powershell
powershell.exe -NoProfile -File .\Test-Transportlogg.ps1
powershell.exe -NoProfile -File .\Test-Graph.ps1
powershell.exe -NoProfile -File .\Test-Client.ps1
```

Tidigare Azure Function-version finns i Git-historiken. Inga redan skapade molnresurser tas bort automatiskt när ni byter till den här klienten.

MIT-licens, se [LICENSE](LICENSE).
