# IT-installation: Entra och Azure Function

För installation från början, följ [den fullständiga steg-för-steg-guiden](../IT-KONFIGURATION-STEG-FOR-STEG.md). Den här filen är en kortare teknisk referens.

**Detta är administrationssteg. Handläggarens dator ska inte installera Azure CLI eller några extra PowerShellmoduler.**

Koden och Azure-mallen är förberedda och offline-testade. Ingen skarp tenantkonfiguration eller Azure-distribution har verifierats under utvecklingen.

## Förutsättningar

- Azure-prenumeration i organisationens Entra-tenant och rätt att skapa resurser i avsedd resursgrupp. Mallen skapar Function App, Windows Consumption-plan, Storage, Log Analytics och Application Insights. Azurekostnader tillkommer vid distribution/användning.
- Azure CLI med Bicep-stöd samt PowerShell på IT:s administrationsdator.
- Administrativ behörighet att skapa applikationer/service principals, ge samtycke och tilldela approller. Graph-anropen behöver lämpliga administrativa befogenheter för `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All` och `DelegatedPermissionGrant.ReadWrite.All`. Tilldelning av Microsoft Graph Application permissions kan kräva Privileged Role Administrator eller Global Administrator. Följ era ordinarie PIM- och administrationsrutiner; ge inte handläggarna dessa roller.
- Device code tillåts av organisationens Conditional Access. Annars måste klientens inloggningsmetod anpassas före distribution.
- Riktiga verksamhetsdomäner och objekt-ID:n för godkända användare eller säkerhetsgrupper. Gruppbaserad apptilldelning kräver tillämplig Entra-licens. Nästlade grupper ersätter inte direkt tilldelning.

## 1. Administratörsinloggning

Kör från projektmappen. Byt platshållarna mot riktiga värden:

```powershell
az login --tenant <tenant-guid>
az account set --subscription <subscription-guid>
```

Kontrollera tenant och prenumeration. Följande skript gör verkliga konfigurationsändringar när IT kör dem, inte bara en plan.

## 2. Skapa Entra-applikationer

```powershell
.\azure\New-EntraApplications.ps1 `
  -Name 'transportlogg' `
  -UserOrGroupObjectId '11111111-1111-1111-1111-111111111111'
```

Ange ett eller flera riktiga objekt-ID:n. Skriptet skapar:

| Identitet | Användning |
| --- | --- |
| transportlogg-api | Single-tenant API, v2-access tokens, scopet `Transportlogg.Access` och rollen `Trace.Reader`. Enterprise Application kräver tilldelning. |
| transportlogg-klient | Publik device code-klient med delegerad behörighet endast till vårt API. Inga Graph-behörigheter eller klienthemligheter. |
| Microsofts Message Trace-service principal | Provisioneras vid behov, app-ID `8bd644d1-64a1-4d4b-ae52-2e0cbf64e373`. |

Klienten förhandsgodkänns för API:t. Administratörssamtycke ges för scopet och angivna användare/grupper tilldelas API-rollen `Trace.Reader`. Inga Exchange-roller tilldelas användarna.

Identifierare sparas efter varje skapad resurs i **.deployment/transportlogg-entra.json**. Behåll filen för förvaltning och återkörning. Om skapandet avbryts innan en identifierare sparats, kontrollera Entra före återkörning så att inga dubbletter skapas. Filen innehåller inga lösenord men ska inte checkas in offentligt.

## 3. Distribuera Azure-resurser och kod

Välj ett globalt unikt funktionsnamn och ange alla tillåtna domäner. Matchningen är exakt; underdomäner behöver egna poster.

```powershell
.\azure\Deploy-Azure.ps1 `
  -ResourceGroup 'rg-transportlogg' `
  -FunctionName 'erorganisation-transportlogg' `
  -EntraConfig '.\.deployment\transportlogg-entra.json' `
  -AllowedDomains 'kommun.se','bolag.kommun.se' `
  -Location 'swedencentral'
```

Skriptet bygger paketet, distribuerar `main.bicep`, tilldelar **funktionens managed identity** Graph-applikationsbehörigheten `ExchangeMessageTrace.Read.All` och laddar upp koden. Om managed identity ännu inte syns i Graph kan tilldelningen behöva återköras efter propagation. Nya behörigheter och Microsofts Message Trace-provisionering kan ta tid att slå igenom.

Mallen kräver HTTPS och Easy Auth för alla anrop, rätt tenant-issuer, API-audience och klient-ID. HTTP-triggern är `anonymous` eftersom klienten inte ska innehålla en gemensam funktionsnyckel. **App Service Authentication framför triggern får inte stängas av.** Exponera inte koden som en fristående öppen endpoint.

Graph-behörigheten ska bara ligga på funktionens managed identity, inte på handläggaren eller den publika klienten. Användarnas `Trace.Reader` avser enbart åtkomst till vårt API.

Skriptet skapar **.deployment/erorganisation-transportlogg-Installningar.json** utan att skriva över projektets inställningar. Granska filen, välj eventuell godkänd exportmapp och kopiera den till `Handläggare/Installningar.json` efter acceptanstest.

För att enbart bygga utan Azureanslutning:

```powershell
.\azure\Build-Package.ps1
```

Resultat: `dist/Transportlogg-Function.zip`, med `host.json` i zip-filens rot. Klientinställningar och exporterade uppgifter ingår inte i serverpaketet.

Validera mallen och paketet separat på IT:s administrationsdator:

```powershell
az bicep build --file .\azure\main.bicep --outfile .\dist\main.json
powershell.exe -NoProfile -File .\Test-AzurePackage.ps1
```

## 4. Distribuera klienten

Distribuera hela mappen **Handläggare** efter att IT fyllt i `Handläggare/Installningar.json`. Mappen innehåller exakt fem filer: `Starta.cmd`, `Start-Transportlogg.ps1`, `Transportlogg.Client.ps1`, `Transportlogg.Core.ps1` och `Installningar.json`. Den ska fungera utan övriga projektmappar. Handläggaren öppnar `Starta.cmd`.

`Starta-demo.cmd` ligger kvar i projektroten för IT:s tester och pekar på samma program i Handläggare-mappen. Den behöver inte distribueras.

`azure/` och Graph-adaptern behövs bara för server/administration. Följ ordinarie signerings- och distributionsrutin. Windows PowerShell 5.1, WinForms och HTTPS måste vara tillåtna. Verktyget ändrar inte klientens säkerhetspolicy.

## 5. Acceptanstest

1. Kör de fyra testskripten i projektroten och prova demolägets fönster och export.
2. Anropa `/api/transportlogg` utan token: Azure ska svara **401**, inte lämna data eller en inloggnings-HTML.
3. Logga in som tilldelad testhandläggare. Kontrollera användarnamn och att domäner kommer från servern.
4. Prova konto utan `Trace.Reader` samt token för fel tenant, audience och klient: åtkomst ska nekas av Easy Auth eller funktionen.
5. Verifiera att handläggaren saknar Exchange-adminroller och att klientapplikationen saknar Graph-rättigheter. Sökning ska ändå fungera genom funktionen.
6. Jämför kända inkommande/utgående testmejl med Exchange admin center. Kontrollera flera mottagare, sidindelning, period över tio dygn, sommartidsgräns och tomt resultat.
7. Prova verksamhetsadress utanför tillåtna domäner. Kontrollera att manipulerade domäner eller radgränser i anropet inte utökar behörigheten.
8. Kontrollera att API-svaret utelämnar ämnesinnehåll när tillvalet inte används. Välj ämne, sök igen och kontrollera exportens rader och tider.
9. Kontrollera Application Insights/Log Analytics. Använd felmeddelandets referens eller `TjanstReferens` i internt underlag för korrelation. Token och råa Graph-fel ska inte finnas i loggarna. Bestäm åtkomst och bevaring enligt er rutin.
10. Testa timeout/throttling/fel: klienten ska visa fel utan exporterbart delresultat. Begränsa sedan sökningen.

## Förvaltning och kapacitet

Tilldela/ta bort `Trace.Reader` på API:ts Enterprise Application. Redan utfärdade token kan fortsätta gälla tills de löper ut. Ändra domäner centralt via `TL_ALLOWED_DOMAINS` eller ny distribution. Klienttoken lagras inte på disk och förnyas inte automatiskt; handläggaren loggar in på nytt.

Tjänsten är synkron med högst 10 000 träffar och tidsbudget. En instans/worker, begränsad HTTP-kö, glesare Graph-anrop och `Retry-After` minskar anropstrycket. Tenantens kvot delas med andra appar och omstarter nollställer lokal state. Ingen beständig tenantkö eller asynkron jobblagring ingår; större volymer behöver en sådan lösning.

Mallen använder Functions 4.x och PowerShell 7.4. Planera runtimeuppdateringar enligt Microsofts supportcykel. Central loggning visar användar-ID, referens, status och radantal; den är ingen komplett, manipulationsskyddad revision av sökfilter eller utlämnade rapporter.

Microsoftkällor och säkerhetsgränser finns i [arkitekturdokumentet](../GRAPH-ARKITEKTUR.md).
