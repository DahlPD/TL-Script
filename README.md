# Transportlogg för Exchange Online

Ett svenskt Windowsverktyg för handläggare som behöver hitta e-postens transportstatus och exportera valda träffar för granskning och utlämning.

**Ingen extra installation behövs hos handläggaren.** Klienten använder inbyggd Windows PowerShell 5.1, .NET och webbläsare. Användaren loggar in via Entra ID och tilldelas åtkomst via verksamhetens Enterprise Application. En Azure Function anropar Microsoft Graph med sin managed identity. Handläggaren behöver inga egna Exchange-administratörsroller.

Koden och distributionsskripten är förberedda. IT behöver konfigurera Entra och Azure enligt [installationsguiden](azure/README.md). Ingen faktisk tenantanslutning eller Azure-distribution har utförts under utvecklingen.

**Börja här som IT:** [Steg-för-steg-guide för hela konfigurationen](IT-KONFIGURATION-STEG-FOR-STEG.md), med kommandon, förväntade resultat, acceptanstest och felsökning.

## Vad ska handläggaren ha?

Distribuera endast mappen **[Handläggare](Handläggare/)**. Den innehåller fem filer och fungerar fristående från resten av projektet:

| Fil i Handläggare | Funktion |
| --- | --- |
| Starta.cmd | Startfilen som handläggaren dubbelklickar på. |
| Start-Transportlogg.ps1 | Fönstret, träfflistan och arbetsflödet. |
| Transportlogg.Client.ps1 | Microsoftinloggning och anrop till verksamhetens tjänst. |
| Transportlogg.Core.ps1 | Gemensamma funktioner för datum, validering och rapportexport. |
| Installningar.json | Tjänstens adress, app-ID:n och valfri exportmapp; fylls i av IT. |

De andra filerna behövs för att bygga, driftsätta, testa och förvalta tjänsten som klienten använder:

| Övrigt i projektet | Funktion |
| --- | --- |
| azure/function/ | Serverkoden som körs i Azure och kontrollerar behörighet. |
| Transportlogg.Graph.ps1 | Serverns anrop till Microsoft Graph och hantering av resultatsidor. |
| azure/main.bicep | Beskriver Azure-resurser och autentiseringsinställningar. |
| azure/New-EntraApplications.ps1 | IT:s konfiguration av applikationer och användartilldelning. |
| azure/Deploy-Azure.ps1 och Build-Package.ps1 | Bygger och distribuerar serverpaketet. |
| Test-*.ps1 | Automatiska kontroller för utveckling och förvaltning. |
| Starta-demo.cmd | Valfri demostart för IT, utanför handläggarmappen. |
| README, arkitektur, azure/README och LICENSE | Instruktioner, teknisk beskrivning och licens. |

De fem klientfilerna är alltså användarens del av lösningen. Azure-tjänsten måste också vara driftsatt, men dess filer ska inte ligga på handläggarens dator.

## Prova utan Microsoft 365-anslutning

Dubbelklicka på **Starta-demo.cmd**, tryck på **Sök**, markera rader och välj **Exportera valda träffar**. Inga konfigurerade app-ID:n behövs i demoläget. Exporterna märks som fiktiva.

Organisationens policy måste tillåta skriptkörning. IT kan distribuera och signera skripten enligt ordinarie rutin. Startfilerna ändrar inte körningspolicy och installerar inga moduler. Windows och Windows PowerShell 5.1 krävs.

## Installation för IT

Se [Azure-installation](azure/README.md) och [arkitektur](GRAPH-ARKITEKTUR.md). Inställningsfilen innehåller endast offentliga identifierare, tjänstens basadress och valfri exportmapp:

```json
{
  "TenantId": "TENANTENS-GUID",
  "ClientId": "KLIENTAPPLIKATIONENS-GUID",
  "ApiAppId": "API-APPLIKATIONENS-GUID",
  "ApiBasUrl": "https://er-transportlogg.azurewebsites.net",
  "Exportmapp": "C:/GodkandLagring/Transportloggar"
}
```

Distributionsskriptet genererar en komplett inställningsfil i `.deployment/` utan att skriva över den lokala filen. IT kopierar de färdiga inställningarna till `Handläggare/Installningar.json` innan mappen distribueras. Lägg inga klienthemligheter, certifikat eller funktionsnycklar i klienten. Tillåtna verksamhetsdomäner bestäms på servern.

Exportmappen är ett förvalt alternativ, ingen åtkomstspärr. Använd `/` i JSON-sökvägar eller dubbla bakstreck: `C:/temp` respektive `C:\\temp`. Ett ensamt bakstreck i `C:\temp` gör `\t` till en tabulator. Tom exportmapp låter användaren välja plats själv.

## Handläggarens arbetsgång

1. Öppna **Handläggare/Starta.cmd** och tryck på **Logga in**.
2. Tryck på **Öppna inloggning**, ange engångskoden på Microsofts sida och logga in med arbetskontot. Följ organisationens MFA-anvisningar och återvänd till verktyget.
3. Ange den exakta adress som begäran gäller, normalt invånarens adress. Ange vid behov även verksamhetens exakta adress.
4. Välj period och riktning. **Till verksamheten** söker adressen som avsändare; **Från verksamheten** söker den som mottagare. **Båda** gör båda sökningarna.
5. Tryck på **Sök**. Markera rader med Ctrl/klick eller Shift/klick. Ctrl+A i träfflistan väljer alla. Inget väljs automatiskt.
6. Ämne är avstängt som standard och skickas då inte till klienten. Ändras ämnestillvalet efter en sökning rensas resultatet; sök igen.
7. Välj **Exportera valda träffar**, välj godkänd lagringsplats och granska rapporten enligt verksamhetens utlämningsrutin.

Datum anges alltid i svensk tid. Standardperioden är föregående sju hela dygn. Sluttiden `2026-10-20 00:00` betyder början av den 20 oktober. Ange nästa dygns `00:00` för att täcka en hel dag; exakt gränstid kan ingå i två sökningar. Ogiltiga eller tvetydiga klockslag vid tidsomställning avvisas.

Användartoken finns bara i processens minne och rensas när fönstret stängs. När den löper ut behöver användaren logga in igen. Inga lösenord sparas och inga mejl skickas.

## Export och tolkning

Varje export skapar en ny undermapp:

| Fil | Användning |
| --- | --- |
| Transportlogg.html | Läsbar rapport. Kan skrivas ut eller sparas som PDF via webbläsaren. |
| Transportlogg.csv | Samma valda träffar, semikolonseparerat med UTF-8 BOM för svenska Excel. Ämne endast om valt. |
| Internt-underlag.json | Windowsanvändare, verifierat användarnamn från tjänsten, sökvillkor, tjänstens referens och valda spårnings-ID. Hantera separat från utlämningsfilerna. |

Filer får lagringsplatsens vanliga behörigheter. CSV-formler neutraliseras och HTML kodas som text. Ingen mejltext eller bilaga hämtas. Rapporten kan ändå innehålla personuppgifter och känsliga ämnen; radurval ersätter inte granskning eller maskning. Det interna underlaget är ingen manipulationsskyddad revisionslogg.

Varje träff avser ett meddelande till en mottagare; samma mejl kan ge flera rader. **Levererat** visar transportstatus, inte att mejlet lästs. För externa mottagare kan det avse mottagarens e-postsystem. Inga träffar bevisar inte att ett mejl aldrig skickats. Kontrollera alias, adresser, period och spårningsfördröjning. Grupper och vidarebefordran kan kräva IT:s analys.

Graph stöder upp till 90 dagars historik, högst tio dygn per anrop och sidindelning. Se [Microsofts API-referens](https://learn.microsoft.com/en-us/graph/api/messagetracingroot-list-messagetraces?view=graph-rest-1.0). Tjänsten följer alla sidor och begränsar sökningen till **10 000 träffar** och en tidsbudget. Om sökningen blir för stor eller kräver för lång väntan avbryts den utan exporterbart delresultat. Begränsa då perioden eller ange verksamhetsadress. Fönstret kan vara upptaget under sökningen.

## Test

```powershell
powershell.exe -NoProfile -File .\Test-Transportlogg.ps1
powershell.exe -NoProfile -File .\Test-Graph.ps1
powershell.exe -NoProfile -File .\Test-Client.ps1
powershell.exe -NoProfile -File .\Test-Service.ps1
```

Testerna använder simulerade svar och verifierar bland annat datum, filter, export, Graph-sidor, tokenhantering, inloggningsprotokoll, serverroller och gränser. Verklig inloggning, Azurekonfiguration och fönstrets layout behöver verifieras enligt IT-guidens acceptanstest.

MIT-licens, se [LICENSE](LICENSE).
