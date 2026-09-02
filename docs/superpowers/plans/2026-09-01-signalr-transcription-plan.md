# SignalR Transcription Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Salesforce Platform Events + empApi with a self-hosted SignalR server (Azure App Service) as the live transcription-delivery mechanism for the `callTranscriptionListener` LWC.

**Architecture:** A minimal ASP.NET Core Web API (`signalr-server/`) hosts a SignalR hub and a token-gated `POST /api/chunks` REST endpoint that broadcasts to it; `replay_call.py` posts chunks there instead of publishing a Platform Event; the LWC connects to the hub directly as a SignalR client (via a vendored JS static resource) instead of subscribing via empApi. Call bookkeeping (`CallListenerPotApi`) and recommendation logic (`CallListenerRecommendation`) are untouched.

**Tech Stack:** ASP.NET Core (.NET 10) + SignalR, xUnit, Azure App Service, Salesforce DX (Apex, LWC, Custom Metadata Type, CspTrustedSite, StaticResource), Python (`requests`).

**Spec:** [docs/superpowers/specs/2026-09-01-signalr-transcription-design.md](../specs/2026-09-01-signalr-transcription-design.md)

## Global Constraints

- Salesforce API version for all new/modified metadata: `67.0` (matches existing `sfdx-project.json` and Apex/LWC meta files).
- Do not modify `CallListenerPotApi.cls` or `CallListenerRecommendation.cls` — call bookkeeping and recommendation logic are out of scope.
- No automated LWC tests exist in this repo and none are added — LWC verification is manual.
- Broadcast to all connected SignalR clients; filter by `userId` client-side in the LWC — no server-side fan-out filtering.
- Wire payload for both `POST /api/chunks` and the `TranscriptionChunk` hub broadcast is camelCase JSON: `{ userId, customerId, callId, transcriptionChunk }`.
- Shared-secret header on `POST /api/chunks` is `X-Api-Key`; the expected value is read from configuration key `ChunkApiKey` (Azure App Service Application Setting in production, `dotnet user-secrets` locally).
- .NET target framework: `net10.0` (matches the only .NET SDK/runtime installed on the development machine, confirmed via `dotnet --list-sdks` / `dotnet --list-runtimes`; the original design targeted net8.0 but that SDK could not be installed side-by-side without an interactive sudo prompt, so the plan was retargeted — see ledger ruling).
- Vendored SignalR JS client: `@microsoft/signalr@10.0.0` browser UMD bundle (minified), global variable `signalR`.

---

### Task 1: SignalR server — hub and chunks endpoint

**Files:**
- Create: `signalr-server/TranscriptionServer.csproj`
- Create: `signalr-server/AssemblyInfo.cs`
- Create: `signalr-server/Program.cs`
- Create: `signalr-server/Hubs/TranscriptionHub.cs`
- Create: `signalr-server/TranscriptionServer.Tests/TranscriptionServer.Tests.csproj`
- Create: `signalr-server/TranscriptionServer.Tests/ChunksEndpointTests.cs`

**Interfaces:**
- Produces: `POST /api/chunks` — header `X-Api-Key: <string>`, JSON body `{ userId, customerId, callId, transcriptionChunk }` (all strings). Returns `200 OK` on success, `401 Unauthorized` if the header is missing/wrong, `400 Bad Request` if the body doesn't parse or `callId` is empty.
- Produces: SignalR hub at `/hubs/transcription`, broadcasting event name `TranscriptionChunk` with the same payload shape to all connected clients.
- Produces: configuration key `ChunkApiKey` (read via `IConfiguration`), which Task 2 sets as an Azure App Setting.

- [ ] **Step 1: Scaffold the web project (no `/api/chunks` yet)**

`signalr-server/TranscriptionServer.csproj`:
```xml
<Project Sdk="Microsoft.NET.Sdk.Web">

  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>

</Project>
```

`signalr-server/AssemblyInfo.cs`:
```csharp
using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("TranscriptionServer.Tests")]
```

`signalr-server/Hubs/TranscriptionHub.cs`:
```csharp
using Microsoft.AspNetCore.SignalR;

namespace TranscriptionServer.Hubs;

public class TranscriptionHub : Hub
{
}
```

`signalr-server/Program.cs` (hub mapped, `/api/chunks` deliberately not implemented yet — this makes Step 3's tests fail for the right reason):
```csharp
using TranscriptionServer.Hubs;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSignalR();
builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
        policy.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod());
});

var app = builder.Build();

app.UseCors();

app.MapHub<TranscriptionHub>("/hubs/transcription");

app.Run();
```

- [ ] **Step 2: Scaffold the test project**

Do not hand-write the test project's `.csproj` — the exact NuGet package versions compatible with net10.0 aren't knowable without querying NuGet, so scaffold it via the `dotnet` CLI, which resolves compatible versions automatically:

```bash
cd signalr-server
dotnet new xunit -n TranscriptionServer.Tests -o TranscriptionServer.Tests
cd TranscriptionServer.Tests
dotnet add package Microsoft.AspNetCore.Mvc.Testing
dotnet add reference ../TranscriptionServer.csproj
rm UnitTest1.cs
cd ../..
```

`dotnet new xunit` already wires up `Microsoft.NET.Test.Sdk`, `xunit`, and `xunit.runner.visualstudio` at compatible versions and sets `TargetFramework` to match the installed SDK (net10.0 here) — no need to add those manually. `dotnet add package` without a version pin resolves the latest version compatible with the project's target framework.

- [ ] **Step 3: Write the failing tests**

`signalr-server/TranscriptionServer.Tests/ChunksEndpointTests.cs`:
```csharp
using System.Net;
using System.Net.Http.Json;
using System.Text;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

public class ChunksEndpointTests
{
    private static readonly object ValidPayload = new
    {
        userId = "u1",
        customerId = "c1",
        callId = "call1",
        transcriptionChunk = "hello"
    };

    private static WebApplicationFactory<Program> CreateFactory(string apiKey = "test-key")
    {
        return new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
        {
            builder.UseSetting("ChunkApiKey", apiKey);
        });
    }

    [Fact]
    public async Task PostChunk_WithoutApiKey_Returns401()
    {
        var client = CreateFactory().CreateClient();

        var response = await client.PostAsJsonAsync("/api/chunks", ValidPayload);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task PostChunk_WithWrongApiKey_Returns401()
    {
        var client = CreateFactory().CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "wrong-key");

        var response = await client.PostAsJsonAsync("/api/chunks", ValidPayload);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task PostChunk_WithMalformedBody_Returns400()
    {
        var client = CreateFactory().CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "test-key");

        var response = await client.PostAsync(
            "/api/chunks",
            new StringContent("not json", Encoding.UTF8, "application/json"));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task PostChunk_WithValidRequestAndApiKey_Returns200()
    {
        var client = CreateFactory().CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "test-key");

        var response = await client.PostAsJsonAsync("/api/chunks", ValidPayload);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}
```

- [ ] **Step 4: Run the tests and confirm they fail**

Run: `dotnet test signalr-server/TranscriptionServer.Tests/TranscriptionServer.Tests.csproj`
Expected: all 4 tests FAIL — the without/wrong-key tests fail because they get `404 Not Found` instead of `401`, and the malformed-body/valid-request tests fail because they get `404` instead of `400`/`200`. (First run will also restore NuGet packages; that's expected.)

- [ ] **Step 5: Implement `/api/chunks`**

Replace `signalr-server/Program.cs` with:
```csharp
using System.Text.Json;
using Microsoft.AspNetCore.SignalR;
using TranscriptionServer.Hubs;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSignalR();
builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
        policy.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod());
});

var app = builder.Build();

app.UseCors();

app.MapHub<TranscriptionHub>("/hubs/transcription");

app.MapPost("/api/chunks", async (
    HttpRequest request,
    IHubContext<TranscriptionHub> hubContext,
    IConfiguration configuration) =>
{
    string? apiKey = request.Headers["X-Api-Key"];
    string? expectedKey = configuration["ChunkApiKey"];
    if (string.IsNullOrEmpty(expectedKey) || apiKey != expectedKey)
    {
        return Results.Unauthorized();
    }

    ChunkPayload? chunk;
    try
    {
        chunk = await request.ReadFromJsonAsync<ChunkPayload>();
    }
    catch (JsonException)
    {
        return Results.BadRequest();
    }

    if (chunk is null || string.IsNullOrEmpty(chunk.CallId))
    {
        return Results.BadRequest();
    }

    await hubContext.Clients.All.SendAsync("TranscriptionChunk", chunk);
    return Results.Ok();
});

app.Run();

public record ChunkPayload(string UserId, string CustomerId, string CallId, string TranscriptionChunk);
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `dotnet test signalr-server/TranscriptionServer.Tests/TranscriptionServer.Tests.csproj`
Expected: all 4 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add signalr-server/
git commit -m "feat: add SignalR transcription server with token-gated chunks endpoint"
```

---

### Task 2: Deploy the server to Azure App Service

**Files:**
- Create: `signalr-server/README.md`

**Interfaces:**
- Consumes: `signalr-server/TranscriptionServer.csproj` (Task 1).
- Produces: a live HTTPS URL (`https://<app-name>.azurewebsites.net`) that Task 3 (CSP Trusted Site), Task 4 (Custom Metadata record), and Task 6 (`replay_call.py` env var) all depend on. Also produces the real value of the `ChunkApiKey` secret that those same tasks need.

- [ ] **Step 1: Write the deployment README**

`signalr-server/README.md`:
```markdown
# SignalR Transcription Server — Deployment

## One-time provisioning

```bash
RESOURCE_GROUP="call-listener-signalr-rg"
LOCATION="eastus"
PLAN_NAME="call-listener-signalr-plan"
APP_NAME="call-listener-signalr-$(openssl rand -hex 4)"  # must be globally unique

az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

az appservice plan create \
  --name "$PLAN_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --sku F1 \
  --is-linux


# [UNKNOWN] Confirm the exact runtime stack name Azure App Service Linux
# offers for .NET 10 before running this — list available stacks and pick
# the matching one (the plan assumes "DOTNETCORE:10.0" but the exact string
# is unverified from this environment):
az webapp list-runtimes --os linux | grep -i dotnet

az webapp create \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --plan "$PLAN_NAME" \
  --runtime "DOTNETCORE:10.0"

# Generate and store the shared secret the /api/chunks endpoint requires
CHUNK_API_KEY=$(openssl rand -hex 32)
az webapp config appsettings set \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --settings ChunkApiKey="$CHUNK_API_KEY"

echo "App URL:    https://$APP_NAME.azurewebsites.net"
echo "API key:    $CHUNK_API_KEY"
```

Save the printed URL and API key — Task 3, Task 4, and Task 6 of the implementation plan need both.

## Deploy / redeploy

Run from `signalr-server/`:

```bash
dotnet publish TranscriptionServer.csproj -c Release -o publish
cd publish && zip -r ../publish.zip . && cd ..

az webapp deploy \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --src-path publish.zip \
  --type zip
```

## Smoke test

```bash
# Missing key -> expect 401
curl -i -X POST "https://$APP_NAME.azurewebsites.net/api/chunks" \
  -H "Content-Type: application/json" \
  -d '{"userId":"u1","customerId":"c1","callId":"call1","transcriptionChunk":"hello"}'

# Valid key -> expect 200
curl -i -X POST "https://$APP_NAME.azurewebsites.net/api/chunks" \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $CHUNK_API_KEY" \
  -d '{"userId":"u1","customerId":"c1","callId":"call1","transcriptionChunk":"hello"}'
```
```

- [ ] **Step 2: Run the provisioning commands**

Run the "One-time provisioning" block from the README above with your actual Azure subscription active (`az account show` to confirm). Record the printed `App URL` and `API key` — you'll need both for the tasks below.

- [ ] **Step 3: Publish and deploy**

Run the "Deploy / redeploy" block from the README above.

- [ ] **Step 4: Smoke test**

Run the "Smoke test" block from the README above.
Expected: first `curl` prints `HTTP/1.1 401 Unauthorized`; second prints `HTTP/1.1 200 OK`.

- [ ] **Step 5: Commit**

```bash
git add signalr-server/README.md
git commit -m "docs: add Azure App Service deployment instructions for SignalR server"
```

---

### Task 3: Salesforce CSP Trusted Site and vendored SignalR client

**Files:**
- Create: `force-app/main/default/cspTrustedSites/Call_Listener_SignalR.cspTrustedSite-meta.xml`
- Create: `force-app/main/default/staticresources/signalRClient.js`
- Create: `force-app/main/default/staticresources/signalRClient.resource-meta.xml`

**Interfaces:**
- Consumes: the Azure App Service URL from Task 2.
- Produces: a static resource named `signalRClient`, importable in LWC as `import SIGNALR_LIB from '@salesforce/resourceUrl/signalRClient';`, which exposes the global `signalR` object (with `HubConnectionBuilder`) once loaded via `loadScript`. Consumed by Task 5.

- [ ] **Step 1: Add the CSP Trusted Site**

`force-app/main/default/cspTrustedSites/Call_Listener_SignalR.cspTrustedSite-meta.xml` — replace `<app-name>` with the actual App Service name from Task 2:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CspTrustedSite xmlns="http://soap.sforce.com/2006/04/metadata">
    <context>All</context>
    <endpointUrl>https://<app-name>.azurewebsites.net</endpointUrl>
    <isActive>true</isActive>
    <isApplicableToConnectSrc>true</isApplicableToConnectSrc>
</CspTrustedSite>
```

- [ ] **Step 2: Vendor the SignalR JS client**

```bash
curl -o force-app/main/default/staticresources/signalRClient.js \
  https://unpkg.com/@microsoft/signalr@10.0.0/dist/browser/signalr.min.js
```

- [ ] **Step 3: Add the static resource metadata**

`force-app/main/default/staticresources/signalRClient.resource-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<StaticResource xmlns="http://soap.sforce.com/2006/04/metadata">
    <cacheControl>Public</cacheControl>
    <contentType>text/javascript</contentType>
    <description>Vendored @microsoft/signalr browser UMD bundle (v10.0.0) for callTranscriptionListener.</description>
</StaticResource>
```

- [ ] **Step 4: Deploy and verify**

Run: `sf project deploy start --source-dir force-app/main/default/cspTrustedSites --source-dir force-app/main/default/staticresources`
Expected: deploy succeeds (`Status: Succeeded`).

- [ ] **Step 5: Commit**

```bash
git add force-app/main/default/cspTrustedSites force-app/main/default/staticresources
git commit -m "feat: trust the SignalR server endpoint and vendor the SignalR JS client"
```

---

### Task 4: SignalR connection config (Custom Metadata Type + Apex)

**Files:**
- Create: `force-app/main/default/objects/SignalR_Config__mdt/SignalR_Config__mdt.object-meta.xml`
- Create: `force-app/main/default/objects/SignalR_Config__mdt/fields/Hub_Url__c.field-meta.xml`
- Create: `force-app/main/default/objects/SignalR_Config__mdt/fields/Access_Token__c.field-meta.xml`
- Create: `force-app/main/default/customMetadata/SignalR_Config.Default.md-meta.xml`
- Create: `force-app/main/default/classes/CallListenerSignalRConfig.cls`
- Create: `force-app/main/default/classes/CallListenerSignalRConfig.cls-meta.xml`
- Create: `force-app/main/default/classes/CallListenerSignalRConfigTest.cls`
- Create: `force-app/main/default/classes/CallListenerSignalRConfigTest.cls-meta.xml`
- Modify: `force-app/main/default/permissionsets/Call_Listener_POT.permissionset-meta.xml`

**Interfaces:**
- Consumes: the Azure App Service hub URL and `ChunkApiKey` value from Task 2.
- Produces: `@AuraEnabled(cacheable=true) CallListenerSignalRConfig.getConnectionInfo()` returning an object with `hubUrl` (String) and `accessToken` (String) properties. Consumed by Task 5.

- [ ] **Step 1: Define the Custom Metadata Type**

`force-app/main/default/objects/SignalR_Config__mdt/SignalR_Config__mdt.object-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>SignalR Config</label>
    <pluralLabel>SignalR Configs</pluralLabel>
    <visibility>Public</visibility>
    <description>Connection settings for the demo SignalR transcription server.</description>
</CustomObject>
```

`force-app/main/default/objects/SignalR_Config__mdt/fields/Hub_Url__c.field-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Hub_Url__c</fullName>
    <label>Hub Url</label>
    <type>Url</type>
    <required>true</required>
</CustomField>
```

`force-app/main/default/objects/SignalR_Config__mdt/fields/Access_Token__c.field-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Access_Token__c</fullName>
    <label>Access Token</label>
    <type>Text</type>
    <length>255</length>
    <required>true</required>
</CustomField>
```

- [ ] **Step 2: Add the config record**

`force-app/main/default/customMetadata/SignalR_Config.Default.md-meta.xml` — replace both values with the real ones from Task 2 (hub URL is the App Service base URL + `/hubs/transcription`; access token is the `ChunkApiKey` value):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" fieldTypes="Metadata">
    <label>Default</label>
    <protected>false</protected>
    <values>
        <field>Hub_Url__c</field>
        <value xsi:type="xsd:string">https://<app-name>.azurewebsites.net/hubs/transcription</value>
    </values>
    <values>
        <field>Access_Token__c</field>
        <value xsi:type="xsd:string"><chunk-api-key-value></value>
    </values>
</CustomMetadata>
```

- [ ] **Step 3: Write the failing Apex test**

`force-app/main/default/classes/CallListenerSignalRConfigTest.cls`:
```apex
@isTest
private class CallListenerSignalRConfigTest {

    @isTest
    static void testGetConnectionInfoReturnsConfiguredValues() {
        Test.startTest();
        CallListenerSignalRConfig.ConnectionInfo info = CallListenerSignalRConfig.getConnectionInfo();
        Test.stopTest();

        System.assertNotEquals(null, info.hubUrl);
        System.assertNotEquals(null, info.accessToken);
    }
}
```

`force-app/main/default/classes/CallListenerSignalRConfigTest.cls-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>67.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 4: Deploy the metadata and test file, confirm the test fails to compile**

Run: `sf project deploy start --source-dir force-app/main/default/objects/SignalR_Config__mdt --source-dir force-app/main/default/customMetadata --source-dir force-app/main/default/classes/CallListenerSignalRConfigTest.cls`
Expected: deploy FAILS with a compile error referencing the undefined `CallListenerSignalRConfig` class.

- [ ] **Step 5: Implement the Apex class**

`force-app/main/default/classes/CallListenerSignalRConfig.cls`:
```apex
public with sharing class CallListenerSignalRConfig {

    public class ConnectionInfo {
        @AuraEnabled public String hubUrl;
        @AuraEnabled public String accessToken;
    }

    @AuraEnabled(cacheable=true)
    public static ConnectionInfo getConnectionInfo() {
        SignalR_Config__mdt config = SignalR_Config__mdt.getInstance('Default');

        ConnectionInfo info = new ConnectionInfo();
        info.hubUrl = config.Hub_Url__c;
        info.accessToken = config.Access_Token__c;
        return info;
    }
}
```

`force-app/main/default/classes/CallListenerSignalRConfig.cls-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>67.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 6: Grant permission set access**

Add a `classAccesses` entry to `force-app/main/default/permissionsets/Call_Listener_POT.permissionset-meta.xml`, immediately after the existing `CallListenerPotApi` entry:
```xml
    <classAccesses>
        <apexClass>CallListenerSignalRConfig</apexClass>
        <enabled>true</enabled>
    </classAccesses>
```

- [ ] **Step 7: Deploy everything and run the test**

Run: `sf project deploy start --source-dir force-app/main/default/objects/SignalR_Config__mdt --source-dir force-app/main/default/customMetadata --source-dir force-app/main/default/classes --source-dir force-app/main/default/permissionsets --test-level RunSpecifiedTests --tests CallListenerSignalRConfigTest`
Expected: deploy succeeds and `CallListenerSignalRConfigTest.testGetConnectionInfoReturnsConfiguredValues` passes.

- [ ] **Step 8: Commit**

```bash
git add force-app/main/default/objects/SignalR_Config__mdt force-app/main/default/customMetadata \
  force-app/main/default/classes/CallListenerSignalRConfig.cls force-app/main/default/classes/CallListenerSignalRConfig.cls-meta.xml \
  force-app/main/default/classes/CallListenerSignalRConfigTest.cls force-app/main/default/classes/CallListenerSignalRConfigTest.cls-meta.xml \
  force-app/main/default/permissionsets/Call_Listener_POT.permissionset-meta.xml
git commit -m "feat: add SignalR connection config metadata and Apex accessor"
```

---

### Task 5: LWC — replace empApi with a SignalR connection

**Files:**
- Modify: `force-app/main/default/lwc/callTranscriptionListener/callTranscriptionListener.js`

**Interfaces:**
- Consumes: `@salesforce/resourceUrl/signalRClient` (Task 3), `CallListenerSignalRConfig.getConnectionInfo()` returning `{ hubUrl, accessToken }` (Task 4).
- Produces: no change to the component's public template bindings (`statusMessage`, `showTranscriptFeed`, `transcriptChunks`, `knowledgeArticles`, `resolutionText`, `isResolutionLoading`, `handleToggleTranscription`) — the HTML template is untouched.

- [ ] **Step 1: Replace the JS implementation**

Replace the full contents of `force-app/main/default/lwc/callTranscriptionListener/callTranscriptionListener.js`:
```javascript
import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import currentUserId from '@salesforce/user/Id';
import SIGNALR_LIB from '@salesforce/resourceUrl/signalRClient';
import getConnectionInfo from '@salesforce/apex/CallListenerSignalRConfig.getConnectionInfo';
import knowledgeSearch from '@salesforce/apex/CallListenerRecommendation.knowledgeSearch';
import resolution from '@salesforce/apex/CallListenerRecommendation.resolution';

const RESOLUTION_CHUNK_INTERVAL = 3;
const TRANSCRIPTION_CHUNK_EVENT = 'TranscriptionChunk';

export default class CallTranscriptionListener extends LightningElement {
    isListening = false;
    currentCallId = '';
    currentCustomerId = '';
    showTranscription = false;
    @track transcriptChunks = [];
    @track knowledgeArticles = [];
    resolutionText = '';
    isResolutionLoading = false;
    chunkCount = 0;
    connection;

    connectedCallback() {
        loadScript(this, SIGNALR_LIB)
            .then(() => getConnectionInfo())
            .then(({ hubUrl, accessToken }) => this.startConnection(hubUrl, accessToken))
            .catch((error) => {
                // eslint-disable-next-line no-console
                console.error('Failed to start SignalR connection', JSON.stringify(error));
            });
    }

    disconnectedCallback() {
        if (this.connection) {
            this.connection.stop();
        }
    }

    startConnection(hubUrl, accessToken) {
        // eslint-disable-next-line no-undef
        this.connection = new signalR.HubConnectionBuilder()
            .withUrl(hubUrl, { accessTokenFactory: () => accessToken })
            .withAutomaticReconnect()
            .build();

        this.connection.on(TRANSCRIPTION_CHUNK_EVENT, (payload) => this.handleEvent(payload));
        this.connection.onreconnecting((error) => {
            // eslint-disable-next-line no-console
            console.error('SignalR reconnecting', error);
        });
        this.connection.onclose((error) => {
            // eslint-disable-next-line no-console
            console.error('SignalR connection closed', error);
        });

        return this.connection.start();
    }

    handleEvent(payload) {
        if (payload.userId !== currentUserId) {
            return;
        }
        if (this.isListening && payload.callId !== this.currentCallId) {
            this.resetCallState();
        }
        this.isListening = true;
        this.currentCallId = payload.callId;
        this.currentCustomerId = payload.customerId;
        this.transcriptChunks = [...this.transcriptChunks, payload.transcriptionChunk];
        this.chunkCount += 1;

        const fullTranscript = this.transcriptChunks.join(' ');
        this.fetchKnowledgeArticles(fullTranscript);

        if (this.chunkCount % RESOLUTION_CHUNK_INTERVAL === 0) {
            this.fetchResolution(fullTranscript);
        }
    }

    resetCallState() {
        this.transcriptChunks = [];
        this.knowledgeArticles = [];
        this.resolutionText = '';
        this.chunkCount = 0;
    }

    fetchKnowledgeArticles(fullTranscript) {
        knowledgeSearch({ queryText: fullTranscript })
            .then((results) => {
                this.knowledgeArticles = results;
            })
            .catch((error) => {
                // eslint-disable-next-line no-console
                console.error('knowledgeSearch failed', JSON.stringify(error));
            });
    }

    fetchResolution(fullTranscript) {
        this.isResolutionLoading = true;
        resolution({ fullTranscript })
            .then((generatedText) => {
                this.resolutionText = generatedText;
            })
            .catch((error) => {
                // eslint-disable-next-line no-console
                console.error('resolution failed', JSON.stringify(error));
            })
            .finally(() => {
                this.isResolutionLoading = false;
            });
    }

    handleToggleTranscription(event) {
        this.showTranscription = event.target.checked;
    }

    get statusMessage() {
        return this.isListening
            ? `Now listening to call "${this.currentCallId}" from customer ID "${this.currentCustomerId}"`
            : 'Listening for ongoing calls...';
    }

    get showTranscriptFeed() {
        return this.showTranscription && this.isListening;
    }
}
```

- [ ] **Step 2: Validate the deploy**

Run: `sf project deploy validate --source-dir force-app/main/default/lwc/callTranscriptionListener`
Expected: validation succeeds (this catches JS/meta syntax errors; there's no Jest suite in this repo to run — full behavioral verification happens in Task 7).

- [ ] **Step 3: Commit**

```bash
git add force-app/main/default/lwc/callTranscriptionListener/callTranscriptionListener.js
git commit -m "feat: connect callTranscriptionListener to the SignalR hub instead of empApi"
```

---

### Task 6: Update the Python publisher scripts

**Files:**
- Modify: `scripts/replay_call.py`
- Modify: `scripts/test_publish_events.py`

**Interfaces:**
- Consumes: env vars `SIGNALR_SERVER_URL`, `SIGNALR_ACCESS_TOKEN` (new), and the already-existing `SF_INSTANCE_URL`, `SF_CLIENT_ID`, `SF_CLIENT_SECRET`.

- [ ] **Step 1: Rewrite `replay_call.py`**

Replace the full contents of `scripts/replay_call.py`:
```python
import os
import time

import requests

INSTANCE_URL = os.environ["SF_INSTANCE_URL"]
CLIENT_ID = os.environ["SF_CLIENT_ID"]
CLIENT_SECRET = os.environ["SF_CLIENT_SECRET"]
SIGNALR_SERVER_URL = os.environ["SIGNALR_SERVER_URL"]
SIGNALR_ACCESS_TOKEN = os.environ["SIGNALR_ACCESS_TOKEN"]

USER_ID = "005gK00006wcklRQAQ"
CALL_ID = "call1"
CUSTOMER_ID = "customer1"
CHUNK_SIZE = 10
CHUNK_DELAY_SECONDS = 4

CALL_SCRIPT = (
    "Agent: Thank you for calling Global Shield Insurance, this is Alex speaking, "
    "how can I help you today? "
    "Maria: Hi Alex, this is Maria Jensen, I'm calling about my travel insurance "
    "policy for a trip to the United States next month. "
    "Agent: Of course Maria, I can help with that. Can you confirm your policy "
    "number and customer ID for me? "
    "Maria: Yes, my customer ID is customer1 and I believe my policy number is "
    "on file under my name. "
    "Agent: Perfect, I have your policy open now. What specifically would you "
    "like to know about your coverage in the United States? "
    "Maria: I'm mainly worried about medical expenses. If I get sick or injured "
    "while I'm in the US, what exactly is covered under my plan? "
    "Agent: Good question. Your policy covers emergency medical treatment up to "
    "two hundred and fifty thousand dollars, including hospital stays, doctor "
    "visits, and prescribed medication while you are traveling in the United States. "
    "Maria: That's a relief. What about if I need to cancel my trip because of "
    "a family emergency? "
    "Agent: Trip cancellation is also covered. If you need to cancel for a "
    "covered reason, such as a family emergency or sudden illness, you can be "
    "reimbursed for prepaid, non-refundable expenses like flights and hotel bookings. "
    "Maria: Great, and how do I actually file a claim if something happens "
    "while I'm there? "
    "Agent: You can file a claim through our mobile app or our website as soon "
    "as possible after the incident, and our claims team typically responds "
    "within forty eight hours. "
    "Maria: That's very helpful, thank you so much for explaining all of this to me. "
    "Agent: You're very welcome Maria, is there anything else I can help you "
    "with today? "
    "Maria: No, that covers everything I needed to know. Thank you Alex. "
    "Agent: You're welcome, have a wonderful trip and please don't hesitate to "
    "call us again if you need anything."
)


def chunk_words(text, size=10):
    words = text.split()
    return [" ".join(words[i:i + size]) for i in range(0, len(words), size)]


def get_access_token():
    response = requests.post(
        f"{INSTANCE_URL}/services/oauth2/token",
        data={
            "grant_type": "client_credentials",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
        },
        timeout=30,
    )
    response.raise_for_status()
    return response.json()["access_token"]


def create_call(session):
    url = f"{INSTANCE_URL}/services/apexrest/CallListenerPot/v1/calls"
    response = session.post(url, json={"callId": CALL_ID, "customerId": CUSTOMER_ID}, timeout=30)
    response.raise_for_status()
    print(f"Created call {CALL_ID}: {response.json()}")


def publish_chunks():
    url = f"{SIGNALR_SERVER_URL}/api/chunks"
    headers = {"X-Api-Key": SIGNALR_ACCESS_TOKEN}
    for chunk in chunk_words(CALL_SCRIPT, size=CHUNK_SIZE):
        payload = {
            "userId": USER_ID,
            "customerId": CUSTOMER_ID,
            "callId": CALL_ID,
            "transcriptionChunk": chunk,
        }
        response = requests.post(url, json=payload, headers=headers, timeout=30)
        response.raise_for_status()
        print(f"Published chunk: {chunk}")
        time.sleep(CHUNK_DELAY_SECONDS)


def close_call(session):
    url = f"{INSTANCE_URL}/services/apexrest/CallListenerPot/v1/calls/{CALL_ID}/close"
    response = session.patch(url, json={"fullTranscript": CALL_SCRIPT}, timeout=30)
    response.raise_for_status()
    print(f"Closed call {CALL_ID}: {response.json()}")


def main():
    token = get_access_token()
    session = requests.Session()
    session.headers.update({
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })

    create_call(session)
    publish_chunks()
    close_call(session)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Rewrite `test_publish_events.py`**

Replace the full contents of `scripts/test_publish_events.py`:
```python
"""
Ad-hoc manual test: publishes a few transcription chunks directly to the
SignalR server's /api/chunks endpoint, bypassing create_call/close_call.
Use this to verify the callTranscriptionListener LWC receives and renders
live events end-to-end, independent of the Salesforce call-bookkeeping flow.

Not part of the plan's committed deliverables - run manually.
"""
import time

import requests

from replay_call import (
    CALL_SCRIPT,
    USER_ID,
    CUSTOMER_ID,
    CALL_ID,
    CHUNK_SIZE,
    SIGNALR_SERVER_URL,
    SIGNALR_ACCESS_TOKEN,
    chunk_words,
)

NUM_CHUNKS_TO_SEND = 3
DELAY_SECONDS = 3


def publish_chunk(chunk):
    url = f"{SIGNALR_SERVER_URL}/api/chunks"
    headers = {"X-Api-Key": SIGNALR_ACCESS_TOKEN}
    payload = {
        "userId": USER_ID,
        "customerId": CUSTOMER_ID,
        "callId": CALL_ID,
        "transcriptionChunk": chunk,
    }
    response = requests.post(url, json=payload, headers=headers, timeout=30)
    response.raise_for_status()
    print(f"Published: {chunk}")


def main():
    chunks = chunk_words(CALL_SCRIPT, size=CHUNK_SIZE)[:NUM_CHUNKS_TO_SEND]
    for chunk in chunks:
        publish_chunk(chunk)
        time.sleep(DELAY_SECONDS)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Test against the deployed server**

Set the two new env vars to the real values from Task 2 (e.g. `export SIGNALR_SERVER_URL="https://<app-name>.azurewebsites.net"` and `export SIGNALR_ACCESS_TOKEN="<chunk-api-key-value>"`), then run:
```bash
python scripts/test_publish_events.py
```
Expected: prints `Published: ...` three times with no exceptions (a failed request raises via `raise_for_status()`).

- [ ] **Step 4: Commit**

```bash
git add scripts/replay_call.py scripts/test_publish_events.py
git commit -m "feat: publish transcription chunks to the SignalR server instead of Platform Events"
```

---

### Task 7: End-to-end verification

**Files:** none (verification only — no code changes, no commit for this task).

**Interfaces:**
- Consumes: everything produced by Tasks 1-6.

- [ ] **Step 1: Confirm all metadata is deployed**

Run: `sf project deploy start --source-dir force-app` (deploys everything, including anything not yet pushed from earlier tasks).
Expected: `Status: Succeeded`.

- [ ] **Step 2: Confirm the LWC is on a page you can see**

Open the target Salesforce app (Service Console) as the org user matching `USER_ID` in `replay_call.py` (`005gK00006wcklRQAQ`), and confirm the "Call listener" utility bar item is present and shows "Listening for ongoing calls...".

- [ ] **Step 3: Run the full replay script**

With all five env vars set (`SF_INSTANCE_URL`, `SF_CLIENT_ID`, `SF_CLIENT_SECRET`, `SIGNALR_SERVER_URL`, `SIGNALR_ACCESS_TOKEN`):
```bash
python scripts/replay_call.py
```

- [ ] **Step 4: Observe the LWC live**

While the script runs, confirm in the browser:
- Status line changes to `Now listening to call "call1" from customer ID "customer1"`.
- Checking "Show incoming transcription" reveals chunks appearing every ~4 seconds.
- The "Recommendations" panel shows Knowledge Articles and, every 3rd chunk, an updated Suggested Resolution.

- [ ] **Step 5: Confirm Salesforce-side bookkeeping is unaffected**

Query the created records to confirm `CallListenerPotApi` still works exactly as before:
```bash
sf data query --query "SELECT Name, Status__c FROM TelephoneCall__c WHERE Name = 'call1' ORDER BY CreatedDate DESC LIMIT 1"
sf data query --query "SELECT FullTranscript__c FROM TelephoneCallTranscription__c WHERE TelephoneCall__r.Name = 'call1' ORDER BY CreatedDate DESC LIMIT 1"
```
Expected: `Status__c` is `Closed` and a `TelephoneCallTranscription__c` record exists with the full call script text — unchanged from the original POT's behavior.
