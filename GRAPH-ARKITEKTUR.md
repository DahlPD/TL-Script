# Graph och Azure Function

Implementerat: modulfria REST-anrop i Windowsklienten, Entra-inloggning med device code, Azure Function med åtkomstkontroll, managed identity för Graph samt paket- och distributionsskript. Ingen tenantanslutning eller faktisk Azure-distribution har utförts under utvecklingen.

## Flöde och identiteter

1. Windowsklienten begär en engångskod och scopet `api://<ApiAppId>/Transportlogg.Access` för tenantens publika klientapplikation. Den begär inga Graph-behörigheter.
2. Handläggaren loggar in hos Microsoft. Användartoken hålls i processens minne.
3. Klienten skickar POST till `/api/transportlogg`. Azure App Service Authentication (Easy Auth) verifierar token, issuer, audience och tillåten klient. Anonyma anrop nekas före funktionen.
4. Funktionen kräver rätt tenant, klient-ID, användarens objekt-ID, scopet `Transportlogg.Access` och approllen `Trace.Reader`.
5. Funktionens managed identity hämtar ett separat Graph-token med applikationsbehörigheten `ExchangeMessageTrace.Read.All`.
6. Funktionen söker via Graph v1.0, filtrerar på serverns domäner och gränser och skickar endast avsedda fält till klienten. Ämne utesluts om det inte begärts. Klienten väljer och exporterar raderna.

Två App registrations och Enterprise Applications används: publik skrivbordsklient samt skyddat API. API:ts Enterprise Application kräver användartilldelning. Function Apps managed identity har Graph-behörigheten. Microsofts separata Message Trace-service principal måste också finnas enligt API:ts förberedelser.

## Säkerhetsgränser

HTTP-triggerns `authLevel: anonymous` innebär att ingen gemensam funktionsnyckel ska finnas hos klienten. **Easy Auth måste alltid vara aktiverad och kräva autentisering för alla anrop.** Bicep-mallen ställer in detta. Exponera inte koden utanför Azure bakom en tjänst som släpper igenom användarskapade `X-MS-CLIENT-PRINCIPAL`-headers. Huvudets Base64-data är ingen egen JWT-verifiering; funktionen litar på plattformens verifiering och headerhantering.

Klienten kan inte skicka egna Graph-URL:er, kommandon, Graph-token eller utökade domäner/radgränser till funktionen. Sidlänkar kontrolleras före varje Graph-anrop. Endast HTTPS, graph.microsoft.com, standardport och rätt v1.0-route accepteras.

Token, sökadresser, ämnen och råa Graph-fel skrivs inte till applikationsloggar. Central loggning omfattar anropsreferens, användarens objekt-ID, status och antal träffar. Storageanslutning och övrig serverkonfiguration lämnar inte servern. Inga klienthemligheter eller certifikat skapas för Graph.

## Drift

Mallen väljer Windows Consumption, PowerShell 7.4, en instans och en worker. HTTP-kö och samtidighet begränsas. Graph-anrop glesas ut; 429/503/504 hanteras med begränsade återförsök och `Retry-After`. Tenantens kvot delas med annan automation. När väntan inte ryms i tidsbudgeten avbryts sökningen utan partiellt resultat. Ingen beständig tenantkö eller asynkron jobblagring ingår.

Device code-flödet måste vara tillåtet av organisationens Conditional Access. Om det förbjuds behöver inloggningen anpassas; verktyget kringgår inga policyer.

## Microsoftkällor, kontrollerade 2026-10-27

- [Graph messageTraces v1.0](https://learn.microsoft.com/en-us/graph/api/messagetracingroot-list-messagetraces?view=graph-rest-1.0)
- [Förberedelser för Graph Message Trace](https://learn.microsoft.com/en-us/exchange/monitoring/trace-an-email-message/graph-api-message-trace)
- [Device code-protokollet](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Identitetshuvuden från App Service](https://learn.microsoft.com/en-us/azure/app-service/configure-authentication-user-identities)
- [Managed identity och dess REST-endpoint](https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity)
- [Functions PowerShell-runtime](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell)
- [AuthsettingsV2](https://learn.microsoft.com/en-us/azure/templates/microsoft.web/sites/config-authsettingsv2)

Se [installationsguiden](azure/README.md) för kommandon och acceptanstest.
