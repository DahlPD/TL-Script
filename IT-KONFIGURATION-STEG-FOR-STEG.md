# IT-guide – enklaste versionen, direkt mot Graph

IT gör konfigurationen i webbläsaren. Handläggaren får fem filer och behöver ingen installation. Ingen Azure Function, Azure-prenumeration, Azure CLI eller PowerShellmodul krävs för den här versionen.

**Flöde:** Handläggare → Microsoftinloggning via er app → Microsoft Graph → lokal rapport.

Guiden följer Microsofts dokumenterade delegerade `ExchangeMessageTrace.Read.All`. Verifiera med ett vanligt testkonto utan Exchange-adminroller innan ni tar lösningen i bruk; åtkomsten har inte testats mot en riktig tenant under utvecklingen.

## 1. Skapa en appregistrering

1. Öppna [Microsoft Entra admin center](https://entra.microsoft.com/) med ett administratörskonto som får registrera appar och ge nödvändigt administratörsgodkännande.
2. Välj rätt tenant.
3. Gå till **App registrations → New registration**.
4. Ange exempelvis **Transportlogg** som namn.
5. Välj **Accounts in this organizational directory only**, alltså single tenant.
6. Lämna Redirect URI tomt för device code-flödet och välj **Register**.
7. Anteckna **Application (client) ID** och **Directory (tenant) ID** från Översikt. Använd inte Object ID i klientinställningarna.

Det skapas också en motsvarande Enterprise Application. Det är er enda egna applikation i denna lösning.

## 2. Tillåt publik klientinloggning

1. Öppna appregistreringen **Transportlogg**.
2. Gå till **Authentication → Advanced settings**.
3. Sätt **Allow public client flows** till **Yes** och spara.

Skapa ingen client secret och inget certifikat. Device code kräver ingen redirect URI. Organisationens Conditional Access måste tillåta detta flöde. Om policyn blockerar det behöver klientens inloggningsmetod anpassas; ändra inte policy på handläggarens dator för att kringgå det. [Microsofts klientkonfiguration](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-registration).

## 3. Ge delegerad Graph-behörighet

1. Öppna **API permissions → Add a permission → Microsoft Graph**.
2. Välj **Delegated permissions**.
3. Sök efter och lägg till **ExchangeMessageTrace.Read.All**.
4. Välj **Grant admin consent** för er tenant och bekräfta som behörig administratör.
5. Kontrollera att raden har typ **Delegated** och att administratörsgodkännandet är beviljat.

Klienten använder även standardscopen `openid profile` för inloggning och ett valfritt kontovisningsnamn. Den anropar inte `/me` och behöver inte `User.Read` för det. Lägg inte till **Application permissions**, `Exchange.ManageAsApp`, administrativa katalogbehörigheter eller klienthemligheter till handläggarapplikationen.

[Microsofts messageTraces v1.0-referens](https://learn.microsoft.com/en-us/graph/api/messagetracingroot-list-messagetraces?view=graph-rest-1.0) anger `ExchangeMessageTrace.Read.All` för delegerad åtkomst.

## 4. Tilldela bara avsedda användare

1. Gå till **Enterprise applications → All applications → Transportlogg**.
2. Öppna **Properties**, sätt **Assignment required?** till **Yes** och spara.
3. Öppna **Users and groups → Add user/group**.
4. Tilldela först en vanlig testhandläggare. Om rollval visas används **Default Access**; den här appen har ingen egen `Trace.Reader`-roll.
5. Tilldela fler användare eller en godkänd grupp efter acceptanstest. Kontrollera licensförutsättningar om gruppbaserad tilldelning används.

Testa tilldelningen med vanliga konton. En Global Administrator är inte ett lämpligt testkonto för tilldelningskravet. [Microsofts instruktion för användarbegränsning](https://learn.microsoft.com/en-us/entra/identity-platform/howto-restrict-your-app-to-a-set-of-users).

## 5. Kontrollera Microsofts Message Trace-förberedelse

Microsoft kräver också att tenantens service principal för deras Message Trace-applikation finns. Det är en Microsoftidentitet, separat från er egen app. Om den redan finns ska ni återanvända den.

IT kan kontrollera och vid behov skapa den via [Microsoft Graph Explorer](https://developer.microsoft.com/en-us/graph/graph-explorer), utan att installera verktyg:

1. Logga in i Graph Explorer i rätt tenant som behörig administratör.
2. Ge Graph Explorer de administrativa rättigheter som behövs för just detta steg, exempelvis `Application.ReadWrite.All` med erforderligt godkännande. Detta gäller **administrationsverktyget**, inte Transportlogg-appen. Följ er vanliga rutin för tillfällig administrativ åtkomst.
3. Kör följande **GET**:

   ```http
   GET https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId eq '8bd644d1-64a1-4d4b-ae52-2e0cbf64e373'
   ```

4. Om `value` innehåller ett objekt finns förberedelsen redan. Om listan är tom, kör följande **POST** med JSON-kroppen:

   ```http
   POST https://graph.microsoft.com/v1.0/servicePrincipals
   Content-Type: application/json
   ```

   ```json
   {
     "appId": "8bd644d1-64a1-4d4b-ae52-2e0cbf64e373"
   }
   ```

5. En ny provisionering kan behöva flera timmar att slå igenom. Hantera administratörens åtkomst till Graph Explorer enligt er ordinarie rutin efteråt.

[Microsofts förberedelser för exchangeMessageTrace](https://learn.microsoft.com/en-us/graph/api/resources/exchangemessagetrace?view=graph-rest-1.0).

## 6. Fyll i klientens enda inställningsfil

Öppna **Handläggare/Installningar.json** och fyll i:

```json
{
  "TenantId": "ER-TENANTS-GUID",
  "ClientId": "TRANSPORTLOGG-APPENS-CLIENT-GUID",
  "VerksamhetensDomaner": ["kommun.se", "bolag.kommun.se"],
  "Exportmapp": ""
}
```

- TenantId och ClientId kommer från appregistreringens Översikt.
- Ange verksamhetens faktiska e-postdomäner. Underdomäner behöver egna poster.
- Tom Exportmapp låter handläggaren välja plats. Alternativt anges exempelvis `C:/GodkandLagring`.
- Använd `/` eller dubbla bakstreck i JSON-sökvägar. Ett ensamt bakstreck i `C:\temp` gör `\t` till en tabulator.
- Inga ApiAppId, ApiBasUrl, funktionsnycklar eller hemligheter behövs.

Domänlistan begränsar sökningen i vårt verktyg. Den är **ingen säkerhetsspärr för användarens övriga Graph-anrop**. Tilldela bara personer som ska ha den underliggande spårningsåtkomsten.

## 7. Prova på en testdator

1. Bekräfta att Windows PowerShell 5.1 och skriptkörning är tillåtna enligt er klientpolicy. Ingen installations- eller körningspolicyändring görs av verktyget.
2. Öppna **Handläggare/Starta.cmd** och välj **Logga in**.
3. Välj **Öppna inloggning**, ange koden på Microsofts sida och logga in som testhandläggaren. Följ eventuell MFA.
4. Återvänd till verktyget. Det gör ett avgränsat anrop mot transportlogg-API:t innan sökknappen aktiveras.
5. Verifiera att kontot **saknar Exchange-adminroller**. En lyckad administratörsinloggning bevisar inte att handläggarflödet fungerar.
6. Sök efter kända testmejl i båda riktningarna och jämför med Exchange admin center. Kontrollera tider, adresser och status.
7. Välj några rader och kontrollera HTML, CSV och det separata interna underlaget. Prova även ämnestillvalet, tomt resultat och en period över tio dygn.
8. Prova ett vanligt konto utan apptilldelning: inloggning/åtkomst ska nekas enligt Entra-konfigurationen.

**Godkänn först när vanligt handläggarkonto kan söka och otilldelat konto nekas.** Om Graph ger 403 trots rätt delegerad behörighet och godkännande behöver IT utreda tenantens åtkomstkrav. Verktyget tilldelar inga Exchange-roller automatiskt.

Valfria offlinekontroller på IT:s dator, utan nätverksanrop:

```powershell
powershell.exe -NoProfile -File .\Test-Transportlogg.ps1
powershell.exe -NoProfile -File .\Test-Graph.ps1
powershell.exe -NoProfile -File .\Test-Client.ps1
```

## 8. Distribuera mappen Handläggare

Distribuera hela mappen med dessa fem filer:

```text
Handläggare/
  Starta.cmd
  Start-Transportlogg.ps1
  Transportlogg.Client.ps1
  Transportlogg.Core.ps1
  Installningar.json
```

IT fyller i inställningarna och hanterar signering/uppdateringar enligt ordinarie rutin. Handläggaren dubbelklickar på **Starta.cmd**. Inga andra projektfiler eller installerade moduler behövs. Provkör den kopierade mappen fristående från projektet före bred distribution.

## Felsökning

| Symtom | Kontroll |
| --- | --- |
| Klient-ID eller tenant-ID saknas | Fyll i GUID:erna från rätt appregistrering. |
| Microsoft kräver en client secret | Kontrollera att appen tillåter public client flows. Denna klient ska inte använda secret. |
| Engångskoden blockeras | Kontrollera public client-inställningen och Conditional Access/sign-in logs för device code. |
| Samtycke krävs | Kontrollera delegerad ExchangeMessageTrace.Read.All och administratörsgodkännande för rätt tenant/app. |
| Användaren är inte tilldelad | Tilldela användaren på Enterprise Application, inte bara som ägare till appregistreringen. |
| Graph ger 401 | Logga in igen; kontrollera även Microsofts Message Trace-service principal och provisionering. |
| Graph ger 403 | Kontrollera samtycke, rätt behörighetstyp, tilldelning och användarens faktiska API-åtkomst. Utred med ett vanligt testkonto. |
| Inga träffar | Kontrollera adresser/alias, riktning, svensk tid, domänlista och spårningsfördröjning. |
| Stor sökning eller throttling | Begränsa period eller verksamhetsadress och försök senare. Klienten avbryter utan delresultat. |
| Illegal character in path | Använd exempelvis C:/temp i JSON-filen. |

## Om ni redan har provat Azure-versionen

Denna version använder inte den gamla Function Appen, API-appregistreringen, managed identity eller Azure-prenumerationen. Inga molnresurser eller behörigheter raderas automatiskt. IT behöver bedöma eventuell avveckling separat enligt sin rutin. Tidigare kod finns i Git-historiken.
