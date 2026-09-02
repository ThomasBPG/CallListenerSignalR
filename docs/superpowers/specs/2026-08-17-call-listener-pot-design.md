# Call Listener POT — Design

**Date:** 2026-08-17
**Target org:** `CallListener` (CLI alias; trailsignup Developer Edition org)
**Target app:** Service Console (`LightningService`)

## Purpose

Prove that call transcriptions from a telephony platform that doesn't support Salesforce's native Service Cloud Voice can still be streamed into Salesforce in near-real-time via Platform Events, displayed live in a console utility item, and eventually used to surface Knowledge Article recommendations. This is a proof of technology, not a production build — several production concerns (multi-agent server-side filtering, transcript durability during the call, recommendation logic) are explicitly deferred; see "Non-goals" below.

## Data Model

### `TelephoneCall__c`

| Field | Type | Notes |
|---|---|---|
| `Name` | Standard (Text) | Call ID, e.g. `call1`, `call2` |
| `CustomerId__c` | Text | External customer identifier, e.g. `customer1` |
| `Status__c` | Picklist (`Open`, `Closed`) | Default `Open`; set to `Closed` when the close-call API is called |

### `TelephoneCallTranscription__c`

| Field | Type | Notes |
|---|---|---|
| Master-Detail | → `TelephoneCall__c` | One transcription record per call |
| `FullTranscript__c` | Long Text Area | Entire call transcript, written once at call close |

Created only when a call closes — there is no incremental persistence of transcript chunks during the call (see Non-goals).

### `TelephonyTranscription__e` (Platform Event)

| Field | Type | Notes |
|---|---|---|
| `UserId__c` | Text | Salesforce User Id of the agent this transcription belongs to |
| `CustomerId__c` | Text | External customer identifier |
| `CallId__c` | Text | Matches `TelephoneCall__c.Name` |
| `TranscriptionChunk__c` | Text | ~10-word chunk of transcribed speech |

New custom platform events are high-volume by default, which is relevant background but doesn't otherwise change anything in this design (see Event Flow below — we're not using the high-volume-only custom-channel filter feature).

## Event Flow & Filtering

Events are **broadcast** on the standard `/event/TelephonyTranscription__e` channel. The LWC subscribes via empApi and filters client-side, comparing `UserId__c` on each incoming event to the current user's Id (`@salesforce/user/Id`).

**Why not server-side filtering:** We evaluated Salesforce's Custom Channels feature (`PlatformEventChannel` + `PlatformEventChannelMember`, GA since API v56.0), which lets a CometD/empApi subscriber receive a server-side filtered stream via a static SOQL-like `filterExpression` (e.g. `UserId__c = '005gK...'`). It works with empApi, but custom channels are capped at **100 per org, flat across all editions including Enterprise** (per Salesforce's Platform Event Allocations documentation), and multiple channel members on one channel don't give per-subscriber isolation — they union. True per-agent isolation would need one channel per agent, and the customer's target scale (up to 500 agents) exceeds the cap by 5x. Client-side filtering has no such ceiling — the limiting factor for 500 concurrent LWC tabs is Streaming API concurrent-client limits, which are comfortably above that (1000 observed on the test org) and not the bottleneck here.

If server-side fan-out reduction becomes a real requirement later (bandwidth or event-delivery-allocation pressure at high concurrency), two options exist without a full redesign: (a) coarser per-team/queue channels instead of per-agent (partial isolation, stays under the 100 cap), or (b) hash-bucketing agents across ~90 channels. Neither is needed for this POT.

## REST API

Single Apex REST class, base path `/services/apexrest/CallListenerPot/v1/calls`:

- **`POST /calls`** — body `{ "callId": "call1", "customerId": "customer1" }` → creates `TelephoneCall__c`
- **`PATCH /calls/{callId}/close`** — body `{ "fullTranscript": "..." }` → creates `TelephoneCallTranscription__c` (master-detail to the matching `TelephoneCall__c`), sets `Status__c = Closed`

Platform events are **not** published through this Apex class — the replay script publishes them directly via the standard `/services/data/vNN.0/sobjects/TelephonyTranscription__e` REST endpoint, matching how a real telephony integration would publish events directly rather than round-tripping through custom Apex.

## Lightning Web Component

Single LWC, added to the Service Console app's Utility Bar.

- **Idle state:** "Listening for ongoing calls..."
- **On first matching event:** "Now listening to call "call1" from customer ID "customer1"" — state persists showing the most recently seen call/customer; there is no call-end detection or auto-reset to idle (out of scope — not needed for a single-call demo, and the LWC only listens to Platform Events, not to `TelephoneCall__c` record changes)
- **Checkbox** "Show incoming transcription" toggles a scrollable feed of chunks (SLDS scrollable panel)
- **Placeholder card** for future Knowledge Article / resolution recommendations — static, clearly marked as unimplemented, no logic wired up
- Built with SLDS (`lightning-card`, `lightning-input` checkbox, `slds-scrollable`) to match the console's look

## External Client App & Authentication

OAuth 2.0 **Client Credentials Flow**. One External Client App (`CallListenerPotIntegration`), run-as user `005gK00006wcklRQAQ` — the same user the LWC listens as, which is a deliberate simplification for this POT (one user plays both "the agent" and "the integration identity"). The Python replay script exchanges client id/secret for a token against `/services/oauth2/token`, then drives everything below with it.

## Replay Script & Knowledge Articles

Python script (`replay_call.py`) demonstrates the full flow for a fictive insurance call:

1. `POST /calls` with `callId=call1`, `customerId=customer1`
2. Publish `TelephonyTranscription__e` events for a scripted dialogue (Maria Jensen calling about US travel insurance coverage), split into ~10-word chunks, one event every 4 seconds
3. `PATCH /calls/call1/close` with the full transcript text

Seed data: 2-3 published Knowledge Articles on US travel insurance coverage (e.g. "Travel Insurance Coverage — United States", "Filing a Claim for Medical Expenses Abroad", "Trip Cancellation and Interruption Coverage — FAQ") — real data for the placeholder panel to eventually query, not wired up yet.

## Testing

- Basic Apex test class for the REST resource (create + close paths) for correctness — not required for deployment coverage on this non-production org, but good practice
- Primary validation is the scripted demo itself: run `replay_call.py` against the deployed org and confirm the LWC transitions from idle → listening → shows transcript chunks as they arrive

## Non-goals (explicitly out of scope for this POT)

- No transcript durability during the call — only the final closed transcript persists (in `TelephoneCallTranscription__c`); mid-call chunks live only on the event bus
- No multi-agent server-side event filtering (see Event Flow rationale above)
- No recommendation/Knowledge-matching logic — placeholder only
- No call-end signal or auto-reset behavior in the LWC
