# SignalR Transcription Streaming — Design

**Date:** 2026-09-01
**Target org:** `CallListener` (CLI alias; trailsignup Developer Edition org)
**Supersedes:** the event-flow portion of [2026-08-17-call-listener-pot-design.md](2026-08-17-call-listener-pot-design.md) — everything in that doc about `TelephoneCall__c`, `TelephoneCallTranscription__c`, the REST API, and the External Client App / OAuth flow is unchanged and still applies. Only the `TelephonyTranscription__e` Platform Event and the LWC's empApi subscription are replaced.

## Purpose

Replace Salesforce Platform Events as the live transcription-delivery mechanism with a self-hosted SignalR server, to demo an alternative real-time push architecture that doesn't depend on Salesforce's event bus. This is a proof of technology, same spirit as the POT this supersedes — the SignalR server is a demo artifact, not a production service.

## Non-goals

- Replacing `CallListenerPotApi` (call open/close bookkeeping in Salesforce) — it stays exactly as-is.
- Replacing or changing `CallListenerRecommendation` (Knowledge Article search, resolution generation) — it stays exactly as-is; the LWC calls it the same way, just triggered by SignalR events instead of platform events.
- Production-grade hub security (per-user auth, connection-level authorization, rate limiting) — a single shared secret is sufficient for a demo with synthetic data.
- Automated LWC tests — none exist in this repo today; verification stays manual (see Testing).
- Server-side fan-out filtering by agent — same rationale as the superseded doc: broadcast to all connected clients, filter client-side by `userId`. Scale concerns that motivated evaluating (and rejecting) Custom Channels don't change here.

## Components

### 1. SignalR server (new: `signalr-server/`)

A minimal ASP.NET Core Web API project, at repo root alongside `force-app/` and `scripts/`.

- **`TranscriptionHub : Hub`** — clients only receive; no client-invokable hub methods. Mapped at `/hubs/transcription`.
- **`POST /api/chunks`** — plain REST endpoint (not a hub method) that:
  1. Validates a shared-secret header `X-Api-Key` against an App Setting (`ChunkApiKey`); returns `401` if missing/wrong.
  2. Validates the JSON body deserializes to the expected shape; returns `400` if not.
  3. Calls `IHubContext<TranscriptionHub>.Clients.All.SendAsync("TranscriptionChunk", payload)`.
- **CORS**: `AllowAnyOrigin()` for the negotiate/handshake requests. Acceptable because the endpoint that actually injects data (`/api/chunks`) is already token-gated; the hub itself only broadcasts, it doesn't accept arbitrary client-authored messages.
- **Config**: `ChunkApiKey` lives in Azure App Service Application Settings (env var `ChunkApiKey`), never committed to the repo. Local dev uses `dotnet user-secrets` or an ignored `appsettings.Development.json`.
- **Payload shape** (JSON, camelCase — this is the wire format for both `/api/chunks` and the `TranscriptionChunk` broadcast to clients):
  ```json
  {
    "userId": "005gK00006wcklRQAQ",
    "customerId": "customer1",
    "callId": "call1",
    "transcriptionChunk": "Agent: Thank you for calling..."
  }
  ```

### 2. Hosting

Deployed to Azure App Service under the existing Azure account.

- One-time provisioning (documented in `signalr-server/README.md`): resource group, App Service plan (Free/Basic tier — no traffic scale needed for a demo), and the Web App itself.
- Redeploy via `az webapp deploy --type zip` (or `az webapp up` for the first deploy) from a `dotnet publish` output.
- The App Service URL is stable across restarts/redeploys, so the Salesforce CSP Trusted Site and the Python script's `SIGNALR_SERVER_URL` env var only need to be set once.
- Set `ChunkApiKey` as an App Setting after provisioning, before the first demo run.

### 3. Salesforce metadata additions

- **`CspTrustedSite`** record for the App Service URL (e.g. `https://<app-name>.azurewebsites.net`), so the LWC is permitted to open a connection to it. Context must cover `connect-src` (WebSocket/fetch), which is the default for a Trusted Site with no restricted contexts specified.
- **Static resource**: `@microsoft/signalr` browser UMD bundle, downloaded once and checked into `force-app/main/default/staticresources/` as a vendored third-party asset (not npm-installed — LWC bundles can't import npm packages directly). Loaded at runtime via `lightning/platformResourceLoader`'s `loadScript`.
- **New Apex class `CallListenerSignalRConfig`**: one method,
  ```apex
  @AuraEnabled(cacheable=true)
  public static ConnectionInfo getConnectionInfo()
  ```
  returning `{ hubUrl, accessToken }`, both read from a new Custom Metadata Type (`SignalR_Config__mdt`, fields `Hub_Url__c` and `Access_Token__c`). This keeps the secret out of the LWC bundle's source/version control. It's still visible in the browser at runtime to anyone inspecting network traffic — an accepted tradeoff for a demo, per the auth-level decision.

### 4. LWC changes (`callTranscriptionListener`)

- Remove the `lightning/empApi` import (`subscribe`/`unsubscribe`/`onError`) and the `CHANNEL_NAME` constant entirely.
- Remove `subscription` tracking property; add a `connection` property (the SignalR `HubConnection` instance).
- `connectedCallback`:
  1. `loadScript(this, signalrLib)` to bring in the vendored UMD bundle (exposes global `signalR`).
  2. Call `getConnectionInfo()` (imperative Apex) to get `{ hubUrl, accessToken }`.
  3. Build the connection:
     ```js
     this.connection = new signalR.HubConnectionBuilder()
         .withUrl(hubUrl, { accessTokenFactory: () => accessToken })
         .withAutomaticReconnect()
         .build();
     this.connection.on('TranscriptionChunk', (payload) => this.handleEvent(payload));
     this.connection.start().catch((error) => console.error('SignalR connection failed', error));
     ```
- `disconnectedCallback`: `this.connection?.stop();`
- `handleEvent(payload)` keeps its existing logic (filter by user, accumulate chunks, trigger knowledge search / resolution) unchanged except field access moves from Platform Event `__c` naming to the camelCase JSON shape:
  - `payload.UserId__c` → `payload.userId`
  - `payload.CustomerId__c` → `payload.customerId`
  - `payload.CallId__c` → `payload.callId`
  - `payload.TranscriptionChunk__c` → `payload.transcriptionChunk`
  - Note the payload is no longer wrapped in `event.data.payload` — SignalR delivers the object directly as the callback argument.
- Error handling stays console-only, matching the existing `registerErrorListener`/`onError` style — `onreconnecting`/`onclose` handlers just `console.error`, no new UI error state.

### 5. `scripts/replay_call.py` changes

- `create_call` / `close_call` stay exactly as they are today (Salesforce REST, unchanged).
- `publish_chunks` changes from posting to `/services/data/{API_VERSION}/sobjects/TelephonyTranscription__e` to:
  ```python
  url = f"{SIGNALR_SERVER_URL}/api/chunks"
  headers = {"X-Api-Key": SIGNALR_ACCESS_TOKEN}
  payload = {
      "userId": USER_ID,
      "customerId": CUSTOMER_ID,
      "callId": CALL_ID,
      "transcriptionChunk": chunk,
  }
  response = requests.post(url, json=payload, headers=headers, timeout=30)
  ```
  No new dependency — still plain `requests`.
- New required env vars: `SIGNALR_SERVER_URL`, `SIGNALR_ACCESS_TOKEN`.
- While touching this file: restore `INSTANCE_URL`/`CLIENT_ID`/`CLIENT_SECRET` to reading from `os.environ[...]` — the current uncommitted working copy has these hardcoded to live values, which must not be committed. This is a pre-existing issue on this branch, not introduced by this change, but it's in the same function being edited so it gets fixed here.
- `scripts/test_publish_events.py` gets the equivalent change (it duplicates the chunk-publish call for ad-hoc testing).

## Data Flow

1. `replay_call.py` → `POST /calls` on Salesforce (unchanged) → creates `TelephoneCall__c`.
2. For each ~10-word chunk: `replay_call.py` → `POST /api/chunks` on the Azure server (with `X-Api-Key`) → server validates → broadcasts `TranscriptionChunk` to all connected SignalR clients.
3. The LWC, already connected to the hub since `connectedCallback`, receives the event, filters by `userId === currentUserId`, updates `transcriptChunks`, and drives the existing `knowledgeSearch`/`resolution` Apex calls exactly as before.
4. `replay_call.py` → `PATCH /calls/{callId}/close` on Salesforce (unchanged) → creates `TelephoneCallTranscription__c`, sets `Status__c = Closed`.

## Testing

- Existing Apex tests (`CallListenerRecommendationTest`, `CallListenerPotApiTest`) are unaffected — no changes.
- New: a small ASP.NET Core test for `POST /api/chunks` using `WebApplicationFactory` — covers missing/wrong `X-Api-Key` (401), malformed body (400), and a valid request resulting in a hub broadcast.
- No LWC Jest tests exist in this repo, and none are being added — primary validation is the scripted demo: deploy the server and metadata, run `replay_call.py` against the deployed Azure URL, confirm the utility bar LWC goes idle → listening → shows live transcript chunks, same as the original POT's validation approach.

## Non-goals recap (explicit, from Purpose section)

- No change to call bookkeeping, Knowledge Article search, or resolution generation.
- No hub-level per-user authorization — one shared secret, demo-appropriate.
- No server-side fan-out filtering — client-side filtering by `userId`, same as before.
