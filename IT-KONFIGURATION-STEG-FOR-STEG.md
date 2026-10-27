# IT-guide: konfigurera Transportlogg steg för steg

**Mål:** en handläggare ska kunna öppna `Handläggare/Starta.cmd`, logga in med sitt arbetskonto, söka transportloggar och exportera valda träffar. Ingen extra programvara eller PowerShellmodul installeras på handläggarens dator. Handläggaren behöver ingen egen Exchange-administratörsroll.

Guiden avser projektversionen med mappen **Handläggare** och serverdelen i **azure**. Kommandona körs av IT på en Windowsdator, i PowerShell, från projektets rotmapp. Behåll samma PowerShellfönster genom stegen så att variablerna finns kvar.

Status vid framtagning: koden har testats med simulerade svar och Azure-mallen har kompilerats. Guiden har inte genomförts mot en faktisk tenant. Genomför först i er testmiljö och kontrollera resultaten nedan innan klienten lämnas ut.

## Översikt: vad sätts upp?

| Del | Uppgift |
| --- | --- |
| App registration och Enterprise Application `transportlogg-api` | Skyddar vårt API. Rollen `Trace.Reader` avgör vilka handläggare som får använda det. |
| App registration och Enterprise Application `transportlogg-klient` | Låter Windowsverktyget logga in användaren och anropa vårt API. |
| Azure Function | Kontrollerar användarens åtkomst och genomför sökningen. |
| Funktionens managed identity | Har Graph-behörigheten `ExchangeMessageTrace.Read.All`. |
| Microsofts Message Trace-service principal | Förberedelse som krävs av Microsofts Message Trace-API. Skapas om den saknas. |
| Mappen Handläggare | De fem filer som distribueras till användaren. |

Appregistreringarnas namn får ett annat prefix om ni väljer ett annat värde än `transportlogg` i steg 3. Applikationernas **client ID**, deras **object ID** och användarens/gruppens **object ID** är olika identifierare och ska inte blandas ihop.

## Steg 1 – Kontrollera IT:s behörigheter och miljö

1. Säkerställ att ni har en Azure-prenumeration i rätt Entra-tenant och en godkänd plats för resursgruppen.
2. Säkerställ rätt att skapa Azure-resurser. Rollen **Contributor** på en lämplig omfattning kan användas för resursdistributionen. Eftersom skriptet även skapar resursgruppen måste kontot kunna göra detta på prenumerationsnivå, alternativt måste en behörig administratör förbereda resursgruppen.
3. Säkerställ rätt att skapa App registrations, service principals, samtycken och approllstilldelningar i Entra. Microsoft anger **Privileged Role Administrator** som lägsta stödda inbyggda roll för tilldelning av Microsoft Graph-approller. Aktivera administrativa roller enligt er PIM-rutin. En Azure-roll ger inte automatiskt motsvarande Entra-behörighet. [Microsofts rollkrav](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-approleassignments?view=graph-rest-1.0).
4. Administrationsskripten använder Microsoft Graph genom Azure CLI:s inloggade administratör. Administrationsklienten behöver tillämpliga delegerade Graph-behörigheter för `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All` och `DelegatedPermissionGrant.ReadWrite.All`. Kontots roll och tokenens behörigheter är separata krav. Dessa behörigheter avser administrationen, inte handläggarnas klientapplikation. [Samtyckeshantering](https://learn.microsoft.com/en-us/graph/api/oauth2permissiongrant-post?view=graph-rest-1.0).
5. Kontrollera med ansvarig för Conditional Access att **device code-flödet** tillåts för denna lösning. Om det är blockerat behöver inloggningsmetoden anpassas innan användning. [Microsofts beskrivning av flödet](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code).

**Kontrollpunkt:** det finns en ansvarig administratör för både Azure och Entra. Handläggarnas konton behöver inte få dessa administrativa roller.

## Steg 2 – Förbered administrationsdatorn och projektmappen

1. Hämta projektversionen som innehåller mappen **Handläggare**. Packa upp hela projektet på IT:s dator. Handläggarna ska senare bara få den mappen.
2. Installera Azure CLI på **IT:s dator** om det saknas. Använd organisationens godkända installationsmetod. Microsofts dokumenterade WinGet-kommando är:

   ```powershell
   winget install --exact --id Microsoft.AzureCLI
   ```

3. Stäng och öppna PowerShell efter installationen. Se [Microsofts installationsguide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows?view=azure-cli-latest).
4. Gå till projektets rotmapp. Ersätt exempelvägen med var ni har lagt projektet:

   ```powershell
   Set-Location -LiteralPath 'C:\IT\TL-Script'
   az version
   az bicep install
   az bicep version
   ```

5. Kontrollera att rätt projektfiler finns:

   ```powershell
   Test-Path -LiteralPath '.\Handläggare\Starta.cmd'
   Test-Path -LiteralPath '.\azure\New-EntraApplications.ps1'
   Test-Path -LiteralPath '.\azure\Deploy-Azure.ps1'
   ```

**Förväntat:** alla tre kontroller returnerar `True`. Om Handläggare-mappen saknas har ni en äldre projektversion. Följ organisationens ordinarie policy för skriptkörning och signering.

## Steg 3 – Samla och fyll i era värden

Hämta identifierarna i rätt tenant:

| Värde | Var IT hittar/väljer det |
| --- | --- |
| Tenant ID | Entra admin center → Entra ID → Overview/Översikt → Tenant ID. |
| Subscription ID | Azure Portal → Subscriptions/Prenumerationer → aktuell prenumeration → Subscription ID. |
| Användarens object ID | Entra → Users/Användare → testhandläggaren → Object ID. Börja gärna med direkt användartilldelning. |
| Gruppens object ID, om grupp används | Entra → Groups/Grupper → vald säkerhetsgrupp → Object ID. Kontrollera licensförutsättningar för gruppbaserad apptilldelning. |
| Domäner | De faktiska e-postdomäner som verksamhetens adresser använder. Ange underdomäner separat. |
| Funktionsnamn | Ett globalt unikt namn, exempelvis `minorg-transportlogg-test`. Skriptet tillåter 3–50 små bokstäver, siffror och bindestreck, med bokstav/siffra först och sist. |
| Region och resursgrupp | Välj enligt er Azure-standard. Exemplet använder `swedencentral`. |

Fyll i blocket nedan. GUID-värdena är exempel och ska ersättas. Skriv inte in lösenord eller klienthemligheter.

```powershell
$TenantId = '11111111-1111-1111-1111-111111111111'
$SubscriptionId = '22222222-2222-2222-2222-222222222222'
$HandlaggarObjectId = '33333333-3333-3333-3333-333333333333'
$EntraName = 'transportlogg'
$ResourceGroup = 'rg-transportlogg-test'
$FunctionName = 'minorg-transportlogg-test'
$Location = 'swedencentral'
$AllowedDomains = @('kommun.se', 'bolag.kommun.se')
```

**Kontrollpunkt:** GUID:erna kommer från er miljö och funktionsnamnet är valt för just er installation. Ett objekts visningsnamn eller e-postadress kan inte ersätta dess object ID i tilldelningsskriptet.

## Steg 4 – Logga in mot rätt tenant och prenumeration

```powershell
az login --tenant $TenantId
az account set --subscription $SubscriptionId
az account show --query '{Tenant:tenantId,Subscription:id,Namn:name}' -o table
```

Slutför Microsofts inloggning som IT-administratör.

**Förväntat:** tabellen visar exakt de värden som angavs i steg 3. Avbryt och rätta inloggningen om tenant eller prenumeration är fel.

## Steg 5 – Bygg och kontrollera koden lokalt

Detta steg skapar inga Azure- eller Entra-resurser:

```powershell
powershell.exe -NoProfile -File .\Test-Transportlogg.ps1
powershell.exe -NoProfile -File .\Test-Graph.ps1
powershell.exe -NoProfile -File .\Test-Client.ps1
powershell.exe -NoProfile -File .\Test-Service.ps1
.\azure\Build-Package.ps1
az bicep build --file .\azure\main.bicep --outfile .\dist\main.json
powershell.exe -NoProfile -File .\Test-AzurePackage.ps1
```

**Förväntat:** testerna avslutas med `Godkänt`. Denna version har 37 + 22 + 21 + 26 + 15 = **121 kontroller**. Bicep-kompileringen ska lyckas och `dist/Transportlogg-Function.zip` ska finnas. Fortsätt inte om ett test eller kompileringen misslyckas.

Prova även `Starta-demo.cmd` i projektroten. Kontrollera att fönstret öppnas och att fiktiva rader kan väljas och exporteras.

## Steg 6 – Skapa Entra-applikationerna och tilldela testhandläggaren

Detta steg gör konfigurationsändringar i Entra:

```powershell
.\azure\New-EntraApplications.ps1 -Name $EntraName -UserOrGroupObjectId $HandlaggarObjectId
```

Skriptet skapar API-applikationen och den publika klienten, sätter upp scopet `Transportlogg.Access`, approllen `Trace.Reader`, nödvändigt samtycke och tilldelning. Det provisionerar också Microsofts Message Trace-service principal om den saknas.

**Förväntat:** skriptet skriver att konfigurationen sparats i `.deployment/transportlogg-entra.json`, med ert valda prefix om ni ändrat det.

Kontrollera därefter i **Entra admin center**:

1. Under **App registrations** finns `<EntraName>-api` och `<EntraName>-klient`.
2. API:ts **Expose an API** visar `api://<ApiAppId>` och scopet `Transportlogg.Access`.
3. API:ts **App roles** innehåller `Trace.Reader`, med visningsnamnet *Transportlogg – handläggare*.
4. Under **Enterprise applications**, öppna **API-applikationen**. Kontrollera att **Assignment required?** är `Yes`.
5. Under API-applikationens **Users and groups** har testhandläggaren/gruppen rollen *Transportlogg – handläggare*.
6. Klientapplikationen har delegerad åtkomst till vårt API. Den ska inte ha `ExchangeMessageTrace.Read.All` eller andra Graph-rättigheter för att söka loggar.

Behåll `.deployment/<EntraName>-entra.json` på IT:s godkända plats. Skriptet återanvänder identifierarna vid återkörning. Radera inte filen för att försöka lösa ett fel. Om ett skapande avbrutits innan en identifierare sparats: kontrollera först i Entra om objektet redan finns.

**Kontrollpunkt:** användartilldelningen finns på **API:ts Enterprise Application**. Det räcker inte att bara lägga till användaren på klientapplikationen.

## Steg 7 – Distribuera Azure Function och ge tjänsten Graph-behörighet

Detta steg skapar Azure-resurser och kan medföra Azurekostnader:

```powershell
$EntraConfigPath = Join-Path '.\.deployment' ($EntraName + '-entra.json')
$deployParameters = @{
    ResourceGroup = $ResourceGroup
    FunctionName = $FunctionName
    EntraConfig = $EntraConfigPath
    AllowedDomains = $AllowedDomains
    Location = $Location
}
.\azure\Deploy-Azure.ps1 @deployParameters
```

Skriptet skapar Function App, Consumption-plan, Storage, Log Analytics och Application Insights. Det aktiverar managed identity och tilldelar **den identiteten** `ExchangeMessageTrace.Read.All` i Microsoft Graph, samt laddar upp serverpaketet. Det konfigurerar också obligatorisk Entra-autentisering framför funktionen.

**Förväntat:** avslutningsmeddelandet anger sökvägen till `.deployment/<FunctionName>-Installningar.json`. Inga klienthemligheter för Graph behöver skapas eller distribueras.

Om en ny managed identity ännu inte syns i Graph kan behörighetstilldelningen behöva återköras efter propagation. Microsofts Message Trace-förberedelser kan också ta flera timmar att slå igenom. [Microsofts onboardingguide](https://learn.microsoft.com/en-us/exchange/monitoring/trace-an-email-message/graph-api-message-trace).

## Steg 8 – Kontrollera Azurekonfigurationen

Öppna **Azure Portal → Function App → er funktion** och kontrollera:

| Kontroll | Förväntat resultat |
| --- | --- |
| Functions | Funktionen `Trace` finns, med routen `/api/transportlogg`. |
| Identity → System assigned | `On`. Anteckna principal/object ID för förvaltningen. |
| Authentication | Microsoft identity provider är aktiverad. Autentisering krävs och anonyma anrop ska få HTTP 401. |
| Identity provider | Rätt tenant-issuer, API-audience och tillåten klient. |
| Environment variables / Configuration | `TL_TENANT_ID`, `TL_CLIENT_ID` och `TL_ALLOWED_DOMAINS` har rätt värden. |

Visa endast lösningens egna inställningar från PowerShell:

```powershell
az functionapp config appsettings list --resource-group $ResourceGroup --name $FunctionName --query "[?starts_with(name, 'TL_')].{Namn:name,Varde:value}" -o table
```

Graph-behörigheten hör till funktionens **managed identity**, inte API-appregistreringen eller klienten. Om ni granskar den i Entra, hitta rätt identitet via principal/object ID och kontrollera tilldelningen till Microsoft Graph.

HTTP-triggern använder `authLevel: anonymous` därför att ingen gemensam funktionsnyckel ska finnas på datorerna. **App Service Authentication/Easy Auth framför triggern måste vara obligatorisk.** Stäng inte av den för att få ett test att fungera. [Microsofts beskrivning av autentiseringskonfigurationen](https://learn.microsoft.com/en-us/azure/templates/microsoft.web/sites/config-authsettingsv2).

## Steg 9 – Verifiera att anonyma anrop nekas

Läs de genererade klientinställningarna och gör ett anrop utan token:

```powershell
$ClientSettingsPath = Join-Path '.\.deployment' ($FunctionName + '-Installningar.json')
$ClientSettings = Get-Content -LiteralPath $ClientSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ApiUrl = $ClientSettings.ApiBasUrl.TrimEnd('/') + '/api/transportlogg'
$StatusCode = 0
try {
    $probe = Invoke-WebRequest -Uri $ApiUrl -Method Post -Body '{"action":"session"}' -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
    $StatusCode = [int]$probe.StatusCode
} catch {
    if ($null -eq $_.Exception.Response) { throw }
    $StatusCode = [int]$_.Exception.Response.StatusCode
}
if ($StatusCode -ne 401) { throw "Kontrollera autentiseringen: förväntade 401, fick $StatusCode." }
'Godkänt: anonyma anrop nekas med HTTP 401.'
```

**Kontrollpunkt:** svaret är HTTP **401**. Ett 200-svar med data eller ett 200-svar med en inloggningssida är inte godkänt för denna kontroll.

## Steg 10 – Fyll i klientinställningarna

Efter godkänd serverkontroll kopieras de genererade inställningarna till handläggarmappen. Detta skriver över den befintliga filen där:

```powershell
Copy-Item -LiteralPath $ClientSettingsPath -Destination '.\Handläggare\Installningar.json' -Force
```

Öppna därefter `Handläggare/Installningar.json` och kontrollera:

| Inställning | Betydelse |
| --- | --- |
| TenantId | Organisationens tenant ID. |
| ClientId | Klientappens Application (client) ID, inte object ID. |
| ApiAppId | API-appens Application (client) ID, inte object ID. |
| ApiBasUrl | Funktionens HTTPS-basadress. Ingen `/api/transportlogg`, funktionsnyckel eller frågeparameter ska läggas till. |
| Exportmapp | Godkänd förvald exportplats, eller tom sträng om handläggaren ska välja själv. |

Exempel på exportmapp: `"Exportmapp": "C:/GodkandLagring/Transportloggar"`. Använd framåtsnedstreck eller dubbla bakstreck i JSON. Skriv inte `C:\temp` med ett ensamt bakstreck; `\t` blir då en tabulator.

Den lokala exportmappen är ett förvalt val, ingen lagringsspärr. Verksamhetens sökdomäner ska inte läggas in i klientfilen; de styrs av funktionen.

## Steg 11 – Genomför acceptanstest med handläggarkonto

Använd ett vanligt tilldelat konto, utan Exchange-administratörsroller:

1. Öppna `Handläggare/Starta.cmd` och välj **Logga in**.
2. Välj **Öppna inloggning**. Ange den visade koden hos Microsoft och logga in som testhandläggaren, inklusive eventuell MFA.
3. Kontrollera att rätt användarnamn visas efter återgång till verktyget.
4. Skicka ett känt testmejl från en extern testadress till en verksamhetsadress. Skicka även ett mejl åt andra hållet. Låt meddelandena hinna bli synliga i spårningen.
5. Sök i respektive riktning och jämför med Exchange admin center. Kontrollera svensk tid, UTC, avsändare, mottagare och status.
6. Välj en del av träffarna och exportera. Kontrollera att HTML och CSV bara innehåller valda rader och att `Internt-underlag.json` hanteras separat.
7. Prova ämnestillvalet. Resultatet ska rensas när valet ändras; efter ny sökning ska ämnet bara inkluderas när det begärts.
8. Prova ett konto utan `Trace.Reader`. Det ska inte kunna skapa session eller söka.
9. Prova en verksamhetsadress utanför tillåtna domäner. Sökningen ska nekas.
10. Kontrollera ett tomt resultat, flera mottagare och en period längre än tio dygn. Fördröjning, timeout eller annan felhantering ska inte lämna ett exporterbart delresultat.

**Kontrollpunkt:** dokumentera testkonto, datum, referenser och godkännande enligt er rutin. `Levererat` visar transportstatus och är inget läskvitto.

## Steg 12 – Distribuera endast Handläggare-mappen

Kopiera hela mappen **Handläggare** till användarnas godkända plats. Den ska innehålla exakt:

```text
Handläggare/
  Starta.cmd
  Start-Transportlogg.ps1
  Transportlogg.Client.ps1
  Transportlogg.Core.ps1
  Installningar.json
```

IT hanterar signering, tillåtna skript och uppdateringar enligt ordinarie rutin. Användaren dubbelklickar på **Starta.cmd**. Testa även att den kopierade mappen fungerar utan projektets övriga mappar.

**Färdigt när:** en tilldelad handläggare kan logga in och söka från den distribuerade mappen, ett otilldelat konto nekas och exporterna är verifierade.

## Felsökning

| Symtom | Kontroll/åtgärd |
| --- | --- |
| `az` känns inte igen | Installera Azure CLI på IT:s dator och öppna ett nytt PowerShellfönster. |
| Skriptet blockeras | Följ er signerings-/distributionspolicy. Kontrollera att rätt, granskad projektversion används. |
| `Authorization_RequestDenied` eller 403 under Entra-installationen | Kontrollera rätt tenant, aktiv administrativ roll och administrationsklientens delegerade Graph-behörigheter. Att vara Contributor i Azure räcker inte. Lös inte detta genom att ge handläggarklienten administrativa Graph-rättigheter. |
| Resursdistributionen nekas | Kontrollera Azure-RBAC, resursproviders, region, organisationspolicy och eventuella namnkonflikter i distributionens felrapport. |
| Managed identity ger 404 vid tilldelning | En ny identitet kan behöva tid att synas i Graph. Kontrollera sparade objekt/resurser och återkör samma distribution efter propagation. |
| Engångskodsinloggning blockeras | Kontrollera Entra sign-in logs, rätt klientapp och Conditional Access för device code. Anpassa inloggningsmetoden om policyn kräver det. |
| Användaren nekas efter Microsoftinloggningen | Kontrollera TenantId, ClientId, ApiAppId och tilldelningen av `Trace.Reader` på API:ts Enterprise Application. Logga in igen efter behörighetsändring. |
| Anonymkontrollen ger annat än 401 | Kontrollera Function Apps Authentication, att rätt endpoint används och att ingen proxy ändrar svaret. |
| Session fungerar men sökning misslyckas | Kontrollera funktionens managed identity, Graph-appbehörigheten, Microsofts Message Trace-service principal och propagation. Använd felmeddelandets referens i loggarna. |
| Inga träffar | Kontrollera rätt adress/alias, riktning, svenska datum, serverns tillåtna domäner och fördröjning i spårningen. |
| Stor sökning eller throttling ger fel | Begränsa perioden och ange verksamhetsadress. Tjänsten har högst 10 000 träffar och en tidsbudget. |
| Illegal character in path | Kontrollera JSON-sökvägen i `Handläggare/Installningar.json`. Använd exempelvis `C:/temp`. |

## Förvaltning efter installation

- **Fler handläggare:** Entra → Enterprise applications → API-applikationen → Users and groups → tilldela rollen *Transportlogg – handläggare*. Använd direkt tilldelning eller en godkänd grupp.
- **Ta bort åtkomst:** ta bort rolltilldelningen/gruppmedlemskapet. Redan utfärdade token kan fortsätta vara giltiga tills de löper ut.
- **Ändra domäner:** uppdatera `TL_ALLOWED_DOMAINS` i Function App settings som en JSON-lista eller återkör distributionen med en uppdaterad `AllowedDomains`. Behåll samma namn och sparade Entra-konfiguration. Ändra även er förvaltningsdokumentation så att nästa distribution använder rätt lista.
- **Felsöka ett anrop:** använd referensen från felmeddelandet eller `TjanstReferens` i det interna exportunderlaget. Applikationsloggen innehåller användarens objekt-ID, status och radantal, inte sökadresser, ämnen eller token.
- **Bevara konfigurationen:** förvara `.deployment/` och godkänd klientkonfiguration enligt IT:s rutiner. De genererade filerna är undantagna från Git.
- **Uppdatera lösningen:** kör offline-testerna, bygg paketet och använd samma distributionskonfiguration. Verifiera efter uppdatering med vanligt handläggarkonto. Planera även uppdatering av Azure Functions PowerShell-runtime enligt Microsofts supportcykel.

Ytterligare tekniska detaljer finns i [Azure-guiden](azure/README.md) och [arkitekturbeskrivningen](GRAPH-ARKITEKTUR.md).
