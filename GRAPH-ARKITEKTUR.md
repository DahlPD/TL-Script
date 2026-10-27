# Direktanslutning till Microsoft Graph

Klienten använder Windows PowerShell 5.1/.NET och Microsofts device code-flöde. En egen single-tenant appregistrering med tillhörande Enterprise Application används. Scopen är `https://graph.microsoft.com/ExchangeMessageTrace.Read.All openid profile`, med administratörsgodkänd delegerad spårningsbehörighet.

Efter Microsoftinloggning gör klienten ett avgränsat provanrop mot `GET /v1.0/admin/exchange/tracing/messageTraces`. Sökningen aktiveras bara om anropet lyckas. Ett faktiskt vanligt handläggarkonto utan Exchange-adminroller måste verifieras i tenantens acceptanstest.

All Graph-kod ligger i `Handläggare/Transportlogg.Client.ps1`. Åtkomsttoken hålls i minnet, avkodas inte och skickas endast till den förväntade HTTPS-routen på graph.microsoft.com. Den separata ID-token för vår egen klient används enbart för ett valfritt visningsnamn, inte för behörighetsbeslut.

Långa perioder delas upp i högst tio dygn. Alla resultatsidor hämtas med `@odata.nextLink`; främmande och upprepade sidlänkar nekas. Fel, utgången token och för stort resultat ger inget exporterbart delresultat. Graphs Retry-After respekteras och längre väntan avbryter i stället för att försöka för tidigt.

Enterprise Application används för användartilldelning och Microsofts åtkomstkontroll. Lokala domänfilter är inte en central säkerhetsgräns. Ingen Azure Function, app-only-identitet, klienthemlighet, central kö eller egen serverloggning ingår. Ämne kan returneras av Graph men rensas ur det färdiga klientresultatet när tillvalet är avstängt.

Microsofts separata Message Trace-service principal måste finnas i tenantens konfiguration. Se [IT-guiden](IT-KONFIGURATION-STEG-FOR-STEG.md).

Källor kontrollerade 2026-10-27:

- [messageTraces v1.0, behörigheter och sidindelning](https://learn.microsoft.com/en-us/graph/api/messagetracingroot-list-messagetraces?view=graph-rest-1.0)
- [Message Trace-förberedelser](https://learn.microsoft.com/en-us/graph/api/resources/exchangemessagetrace?view=graph-rest-1.0)
- [Device code](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Publik skrivbordsklient](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-registration)
- [Tilldelning av användare](https://learn.microsoft.com/en-us/entra/identity-platform/howto-restrict-your-app-to-a-set-of-users)
