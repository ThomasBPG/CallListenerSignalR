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

# Confirm the exact runtime stack name Azure App Service Linux offers for
# .NET 10 before running the next command:
az webapp list-runtimes --os linux | grep -i dotnet
# As of this writing, Azure reports the stack as "DOTNETCORE|10.0" (pipe
# separator) for .NET 10 (LTS) on Linux — NOT "DOTNETCORE:10.0". Use
# whatever the command above actually prints.

az webapp create \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --plan "$PLAN_NAME" \
  --runtime "DOTNETCORE|10.0"

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

**Running the sections below in a new shell session?** `RESOURCE_GROUP`, `APP_NAME`, and `CHUNK_API_KEY` won't be set. Re-export them, e.g.:
```bash
RESOURCE_GROUP="call-listener-signalr-rg"
APP_NAME=$(az webapp list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
CHUNK_API_KEY=$(az webapp config appsettings list --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --query "[?name=='ChunkApiKey'].value" -o tsv)
```

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

## Known limitations (demo-only posture)

**Security — the hub itself has no auth, and the browser gets the write key.**
`/api/chunks` (the publish side) checks `X-Api-Key`, but `MapHub<TranscriptionHub>("/hubs/transcription")`
does not — any client that can reach the hub URL can connect and receive every
broadcast chunk, regardless of the LWC's client-side `userId` filter (that
filter only controls what's *displayed*, not what's *delivered*). CORS is also
wide open (`AllowAnyOrigin`/`AllowAnyHeader`/`AllowAnyMethod`). Separately, the
LWC's `accessTokenFactory` hands the hub the same `ChunkApiKey` used to
authenticate *writes*, so that write-capable secret is visible to any browser
that loads the component (network tab, cached Apex response). The hub ignores
that token, so today it's pure exposure with no offsetting benefit.

This is acceptable **only** because this is a single-user demo/sandbox
component with no untrusted audience. Before this server ever has more than
one trusted user, or leaves a sandbox/demo org:
- Add real auth to the hub (e.g. `[Authorize]` + a proper token), not just the REST endpoint.
- Stop reusing `ChunkApiKey` as the browser's hub credential — mint a separate, read-only token for hub connections.
- Rotate `ChunkApiKey` (see below) once the above is in place.
- Narrow CORS to the actual Salesforce domain instead of `AllowAnyOrigin`.

**`SignalR_Config.Default.md-meta.xml` ships with a placeholder token, on purpose.**
The real `Access_Token__c` value must equal the Azure `ChunkApiKey` app
setting above, but it is never committed to the repo. After deploying
`force-app`, set the real value on the org's `SignalR_Config__mdt` `Default`
record directly (Setup → Custom Metadata Types → SignalR Config → Manage
Records, or `sf data update record`) — do not commit it back into the
metadata file. If a future `sf project deploy start` for this specific file
fails with `UNKNOWN_EXCEPTION (-315522575)` (a reproducible quirk in some
orgs, unrelated to content), fall back to a direct SOAP `updateMetadata`
call against `/services/Soap/m/<version>` instead of retrying the CLI deploy.

**Deploying `force-app` to a fresh org will fail.** `callTranscriptionListener.js`
imports `@salesforce/apex/CallListenerRecommendation.knowledgeSearch` /
`.resolution`. `CallListenerRecommendation.cls` (and its test class) are not
committed anywhere in this repo's git history — they exist only as
uncommitted files in a sibling checkout and as already-deployed, `Active`
Apex in this shared dev org. A clean-room `sf project deploy start` will fail
to compile the LWC until whoever owns that class commits it. Separately,
deploying `force-app/main/default/customMetadata/SignalR_Config.Default.md-meta.xml`
by itself has reproducibly failed with `UNKNOWN_EXCEPTION (-315522575)` in
this org/CLI combination (not content-related — the org's live record already
matches source byte-for-byte); if you hit this, verify with
`sf data query --query "SELECT Hub_Url__c, Access_Token__c FROM SignalR_Config__mdt"`
before assuming the deploy actually failed to apply.

**The Recommendations panel is currently dead in the UI.** The LWC's JS
actively calls `knowledgeSearch`/`resolution` and tracks their results, but
`callTranscriptionListener.html` still renders a static "Not yet
implemented." placeholder and never binds `knowledgeArticles` /
`resolutionText` / `isResolutionLoading`. This is out of this plan's scope
(the HTML template was intentionally left untouched), but means the feature
described in the design spec cannot render from this branch alone, and the
JS does discarded (LLM-backed, for `resolution`) work every few seconds for
nothing until the template is wired up.
