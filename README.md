# Call Listener POT

A proof-of-technology for streaming live telephone-call transcriptions into
Salesforce and surfacing Knowledge Article recommendations / suggested
resolutions in real time, in a Lightning Web Component pinned to the
Service Console utility bar.

Built for a telephony platform that doesn't support Service Cloud Voice
natively — transcription chunks are pushed in from an external system and
fanned out to the browser over a self-hosted SignalR server rather than
Salesforce's Platform Event bus (see [Architecture](#architecture) for why).

> **This is a demo/POT, not a production build.** Auth is a single shared
> secret, there's no per-user hub authorization, and the "Recommendations"
> panel UI isn't fully wired up yet. See
> [Known limitations](#known-limitations) before showing this to anyone
> outside a sandbox.

## Architecture

```
                 POST /calls, PATCH /calls/{id}/close
 replay_call.py ────────────────────────────────────────▶ Salesforce REST API
       │                                                   (CallListenerPotApi)
       │ POST /api/chunks  (X-Api-Key)                            │
       ▼                                                          │ creates/closes
 SignalR server (Azure App Service)                                TelephoneCall__c /
  - TranscriptionHub (WebSocket broadcast)                        TelephoneCallTranscription__c
  - /api/chunks REST endpoint (shared-secret gated)
       │
       │ WSS broadcast: "TranscriptionChunk"
       ▼
 Lightning Web Component (callTranscriptionListener)
  - Service Console utility bar
  - filters by userId client-side
  - drives Data Cloud vector search (Knowledge Articles)
  - drives a GenAI prompt template (suggested resolution)
```

**Why SignalR instead of Platform Events:** the original design used a
custom Platform Event (`TelephonyTranscription__e`) broadcast on the
standard event bus. That's superseded — this repo now uses a small
self-hosted SignalR server as an alternative real-time push mechanism that
doesn't depend on Salesforce's event bus. The Platform Event object and its
REST-publish path are still in `force-app` but no longer used by the LWC.
Full rationale: [docs/superpowers/specs/2026-09-01-signalr-transcription-design.md](docs/superpowers/specs/2026-09-01-signalr-transcription-design.md).

## Repository layout

```
force-app/            Salesforce DX source (objects, Apex, LWC, metadata)
signalr-server/        ASP.NET Core SignalR server (deployed to Azure App Service)
scripts/                Python replay script that plays back a fictive call
docs/superpowers/       Design specs and implementation plans for both build phases
```

## Components

### Salesforce (`force-app/`)

- **`TelephoneCall__c`** / **`TelephoneCallTranscription__c`** — call
  bookkeeping. A call opens as `Open`, closes to `Closed` with the full
  transcript attached.
- **`CallListenerPotApi`** — Apex REST resource, base path
  `/services/apexrest/CallListenerPot/v1/calls`. `POST` creates a call,
  `PATCH .../{callId}/close` closes it with the full transcript.
- **`CallListenerSignalRConfig`** — `@AuraEnabled(cacheable=true)` method the
  LWC calls to get the SignalR hub URL + access token, read from the
  `SignalR_Config__mdt` Custom Metadata Type.
- **`CallListenerRecommendation`** — Data Cloud vector search over Knowledge
  Article chunks (`knowledgeSearch`) and a GenAI prompt-template call
  (`resolution`) that proposes a resolution from the transcript so far.
- **`callTranscriptionListener` (LWC)** — connects to the SignalR hub on
  load, shows "Listening for ongoing calls...", then "Now listening to call
  "call1" from customer ID "customer1"" once a chunk for the current user
  arrives. A checkbox toggles a live transcript feed. Pinned to the
  `LightningService` app's utility bar.
- **`TelephonyTranscription__e`** — the original Platform Event design.
  Kept for reference; no longer in the live data path (see Architecture).
- **`CallListenerPotIntegration`** (External Client App) — OAuth 2.0 Client
  Credentials Flow app the Python replay script authenticates with.

### SignalR server (`signalr-server/`)

Minimal ASP.NET Core Web API (.NET 10):

- `TranscriptionHub` — clients only receive; no client-invokable methods.
  Mapped at `/hubs/transcription`.
- `POST /api/chunks` — validates a shared-secret header (`X-Api-Key`
  against the `ChunkApiKey` app setting), then broadcasts the chunk to all
  connected hub clients via `TranscriptionChunk`.

Deployment steps and the demo-only security posture are documented in
[signalr-server/README.md](signalr-server/README.md) — read that before
deploying.

### Replay script (`scripts/`)

`replay_call.py` plays back a fictive insurance call — "Maria Jensen"
calling about US travel insurance coverage — split into ~10-word chunks,
one every 4 seconds, so the demo has something to watch.

## Deploying

### Prerequisites

- Salesforce CLI (`sf`) authenticated against a target org
- Azure CLI (`az`), logged in, for the SignalR server
- .NET 10 SDK, for building/publishing the SignalR server
- Python 3.9+, for the replay script

### 1. Deploy Salesforce metadata

```bash
sf project deploy start -o <your-org-alias>
```

Then assign the permission set so the running/integration user can read the
custom objects and call the Apex classes:

```bash
sf org assign permset -n Call_Listener_POT -o <your-org-alias>
```

**If the deploy fails on `SignalR_Config.Default.md-meta.xml` with
`UNKNOWN_EXCEPTION (-315522575)`:** that's a reproducible CLI/org quirk,
unrelated to content. Deploy everything else, then set the record's fields
directly — either in Setup → Custom Metadata Types → SignalR Config →
Manage Records, or via a direct SOAP `updateMetadata` call against
`/services/Soap/m/<version>` if you need it scripted.

### 2. Deploy the SignalR server

Follow [signalr-server/README.md](signalr-server/README.md) — it covers
one-time Azure provisioning, `dotnet publish` + `az webapp deploy`, and a
smoke test for `/api/chunks`.

### 3. Wire the two together

The repo already ships `CspTrustedSite` records pointed at
`call-listener-signalr-a7c9a555.azurewebsites.net` — **update the endpoint
URLs in `force-app/main/default/cspTrustedSites/` to your own App Service
hostname** before deploying, or the LWC won't be allowed to connect.

The `SignalR_Config__mdt` `Default` record ships with a placeholder
`Access_Token__c`. After deploying, set its real value (matching the
`ChunkApiKey` app setting from step 2) directly on the org record — **do
not commit the real token back into the metadata file.**

### 4. Add the LWC to a console app

The LWC is already placed in `LightningService_UtilityBar.flexipage-meta.xml`.
If you're deploying into an org without a `LightningService` app, add
`callTranscriptionListener` to your own console app's utility bar via
Setup → App Manager, or a FlexiPage of your own.

## Running the demo (replay)

The replay script needs Salesforce OAuth client credentials (from the
`CallListenerPotIntegration` External Client App) and the SignalR server's
URL + API key.

```bash
cd scripts
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Create a `credentials` file (already gitignored — never commit real
secrets here) with:

```fish
set -x SF_INSTANCE_URL "https://<your-org>.my.salesforce.com"
set -x SF_CLIENT_ID "<consumer key from CallListenerPotIntegration>"
set -x SF_CLIENT_SECRET "<consumer secret from CallListenerPotIntegration>"
set -x SIGNALR_SERVER_URL "https://<your-app-name>.azurewebsites.net"
set -x SIGNALR_ACCESS_TOKEN "<ChunkApiKey value>"
```

(Using bash/zsh instead of fish? Use `export VAR="value"` lines instead.)

Then run it with the org open in a browser tab (Service Console, so the
utility bar LWC is visible):

```bash
source credentials   # or: . credentials  /  set -a; source credentials
python3 replay_call.py
```

Expected sequence in the LWC:

1. **"Listening for ongoing calls..."** on load.
2. `POST /calls` fires → call record created (not visible in the LWC yet,
   it only reacts to transcription chunks).
3. First chunk arrives → **"Now listening to call "call1" from customer ID
   "customer1""**, transcript feed starts filling in (toggle the checkbox
   to watch it live), Knowledge Article search kicks off per chunk.
4. `PATCH /calls/call1/close` fires at the end → call closes with the full
   transcript in Salesforce (again, not reflected live in the LWC).

## Known limitations

- **Hub has no auth; browser holds a write-capable secret.** `/api/chunks`
  checks `X-Api-Key`, but the hub itself doesn't gate connections, and CORS
  is wide open. Fine for a single-user sandbox demo, not fine beyond that.
  Full detail: [signalr-server/README.md](signalr-server/README.md#known-limitations-demo-only-posture).
- **The Recommendations panel isn't wired up in the UI.** The LWC's JS calls
  `knowledgeSearch`/`resolution` and tracks results, but the template still
  renders a static "Not yet implemented" placeholder.
- **No transcript durability during the call.** Only the final closed
  transcript persists; mid-call chunks live only in-memory on the SignalR
  broadcast.
- **No per-agent server-side fan-out filtering.** The server broadcasts to
  every connected client; the LWC filters by `userId` client-side. Fine at
  demo scale; see the design docs if this needs to scale to hundreds of
  concurrent agents.

## Further reading

- [Initial Design.md](Initial%20Design.md) — the original brainstorm prompt
- [docs/superpowers/specs/2026-08-17-call-listener-pot-design.md](docs/superpowers/specs/2026-08-17-call-listener-pot-design.md) — original Platform Events design
- [docs/superpowers/specs/2026-09-01-signalr-transcription-design.md](docs/superpowers/specs/2026-09-01-signalr-transcription-design.md) — SignalR migration design
- [signalr-server/README.md](signalr-server/README.md) — SignalR server deployment + security posture
