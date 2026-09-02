# Call Listener POT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a working proof of technology to the `CallListener` org that streams call transcription chunks into Salesforce via a Platform Event, displays them live in a Service Console utility-bar LWC filtered to the current agent, persists the final transcript on call close, and includes a runnable Python script that replays a fictive insurance call end-to-end.

**Architecture:** SFDX-managed metadata (custom objects, platform event, Apex REST API, permission set, External Client App, LWC) deployed via `sf project deploy start`; a Python script drives the demo by authenticating with OAuth 2.0 Client Credentials Flow and calling the REST API + publishing platform events directly.

**Tech Stack:** Salesforce DX (API v67.0), Apex, Lightning Web Components + empApi, OAuth 2.0 Client Credentials Flow, Python 3 + `requests`.

**Spec:** `docs/superpowers/specs/2026-08-17-call-listener-pot-design.md`

## Global Constraints

- Target org: CLI alias `CallListener`
- Target Lightning app for the utility bar item: `LightningService` (Service Console)
- API version: `67.0` everywhere (sfdx-project.json, LWC meta, REST endpoints)
- Demo/run-as user: `005gK00006wcklRQAQ`
- Event filtering is **client-side only** — subscribe to the raw `/event/TelephonyTranscription__e` channel and filter in JavaScript by `UserId__c`. Do not build the custom-channel/`PlatformEventChannelMember` filtering approach — it was evaluated and rejected in the spec (100-channel org cap, doesn't scale to 500 agents).
- Apex REST base path: `/services/apexrest/CallListenerPot/v1/calls`
- No placeholder recommendation logic — the LWC's recommendation panel must be visibly static/unimplemented, not stubbed to look functional

---

## Task 1: SFDX Project Scaffold

**Files:**
- Create: `sfdx-project.json`
- Create: `force-app/main/default/` (empty directory structure, populated by later tasks)
- Create: `.gitignore`

**Interfaces:**
- Produces: `force-app/main/default/` as the root all later tasks place metadata under; `sfdx-project.json` with `sourceApiVersion: "67.0"`

- [ ] **Step 1: Create the project structure**

```bash
mkdir -p force-app/main/default/objects
mkdir -p force-app/main/default/classes
mkdir -p force-app/main/default/lwc
mkdir -p force-app/main/default/permissionsets
```

- [ ] **Step 2: Write `sfdx-project.json`**

```json
{
  "packageDirectories": [
    {
      "path": "force-app",
      "default": true
    }
  ],
  "name": "CallListenerPOT",
  "namespace": "",
  "sourceApiVersion": "67.0"
}
```

- [ ] **Step 3: Write `.gitignore`**

```
.sfdx/
.sf/
.vscode/
node_modules/
*.log
```

- [ ] **Step 4: Verify the org connection**

Run: `sf org display --target-org CallListener`
Expected: Connected status, username `trailsignup.dfdf8318b1de86@salesforce.com`

- [ ] **Step 5: Commit**

```bash
git init
git add sfdx-project.json .gitignore force-app
git commit -m "chore: scaffold SFDX project for Call Listener POT"
```

---

## Task 2: `TelephoneCall__c` Custom Object

**Files:**
- Create: `force-app/main/default/objects/TelephoneCall__c/TelephoneCall__c.object-meta.xml`
- Create: `force-app/main/default/objects/TelephoneCall__c/fields/CustomerId__c.field-meta.xml`
- Create: `force-app/main/default/objects/TelephoneCall__c/fields/Status__c.field-meta.xml`

**Interfaces:**
- Produces: `TelephoneCall__c` object with `Name` (Text, caller-supplied — holds `call1`, `call2`, etc.), `CustomerId__c` (Text), `Status__c` (Picklist: `Open`/`Closed`, default `Open`) — consumed by Task 3 (master-detail target), Task 6 (Apex REST), Task 8 (LWC display), Task 11 (Python script body)

- [ ] **Step 1: Generate the object and its Name field**

Use the `platform-custom-object-generate` skill to create the object with these exact specs (if that skill separates object creation from field creation, follow up with `platform-custom-field-generate` for the fields in Step 2):

- API name: `TelephoneCall__c`
- Label: `Telephone Call` / Plural: `Telephone Calls`
- Name field type: **Text** (not Auto Number) — labeled `Call ID`, since call IDs (`call1`, `call2`) are supplied by the caller, not system-generated
- Deployment status: Deployed
- Sharing model: ReadWrite

If hand-writing the XML instead, use this as the object-meta.xml:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <deploymentStatus>Deployed</deploymentStatus>
    <label>Telephone Call</label>
    <pluralLabel>Telephone Calls</pluralLabel>
    <nameField>
        <label>Call ID</label>
        <type>Text</type>
    </nameField>
    <sharingModel>ReadWrite</sharingModel>
</CustomObject>
```

- [ ] **Step 2: Add `CustomerId__c` (Text) and `Status__c` (Picklist)**

```xml
<!-- force-app/main/default/objects/TelephoneCall__c/fields/CustomerId__c.field-meta.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>CustomerId__c</fullName>
    <label>Customer ID</label>
    <length>40</length>
    <type>Text</type>
    <required>false</required>
</CustomField>
```

```xml
<!-- force-app/main/default/objects/TelephoneCall__c/fields/Status__c.field-meta.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Status__c</fullName>
    <label>Status</label>
    <type>Picklist</type>
    <required>true</required>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value>
                <fullName>Open</fullName>
                <default>true</default>
                <label>Open</label>
            </value>
            <value>
                <fullName>Closed</fullName>
                <default>false</default>
                <label>Closed</label>
            </value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
```

- [ ] **Step 3: Deploy and verify**

Run: `sf project deploy start --source-dir force-app/main/default/objects/TelephoneCall__c --target-org CallListener`
Expected: `Status: Succeeded`

Run: `sf sobject describe --sobject TelephoneCall__c --target-org CallListener --json | jq '.fields[] | select(.name=="CustomerId__c" or .name=="Status__c") | {name, type}'`
Expected: both fields present with correct types

- [ ] **Step 4: Commit**

```bash
git add force-app/main/default/objects/TelephoneCall__c
git commit -m "feat: add TelephoneCall__c custom object"
```

---

## Task 3: `TelephoneCallTranscription__c` Custom Object

**Files:**
- Create: `force-app/main/default/objects/TelephoneCallTranscription__c/TelephoneCallTranscription__c.object-meta.xml`
- Create: `force-app/main/default/objects/TelephoneCallTranscription__c/fields/TelephoneCall__c.field-meta.xml` (master-detail)
- Create: `force-app/main/default/objects/TelephoneCallTranscription__c/fields/FullTranscript__c.field-meta.xml`

**Interfaces:**
- Consumes: `TelephoneCall__c` object from Task 2 (master-detail parent)
- Produces: `TelephoneCallTranscription__c` object with `TelephoneCall__c` (Master-Detail lookup field, API name `TelephoneCall__c`) and `FullTranscript__c` (Long Text Area) — consumed by Task 6 (Apex REST close-call insert)

- [ ] **Step 1: Generate the object**

Use the `platform-custom-object-generate` skill, or hand-write:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <deploymentStatus>Deployed</deploymentStatus>
    <label>Telephone Call Transcription</label>
    <pluralLabel>Telephone Call Transcriptions</pluralLabel>
    <nameField>
        <label>Transcription Name</label>
        <type>AutoNumber</type>
        <displayFormat>TRANS-{0000}</displayFormat>
        <startingNumber>1</startingNumber>
    </nameField>
</CustomObject>
```

- [ ] **Step 2: Add the master-detail field to `TelephoneCall__c`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>TelephoneCall__c</fullName>
    <label>Telephone Call</label>
    <type>MasterDetail</type>
    <referenceTo>TelephoneCall__c</referenceTo>
    <relationshipName>Transcriptions</relationshipName>
    <relationshipLabel>Telephone Call Transcriptions</relationshipLabel>
    <writeRequiresMasterRead>false</writeRequiresMasterRead>
</CustomField>
```

- [ ] **Step 3: Add `FullTranscript__c` (Long Text Area)**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>FullTranscript__c</fullName>
    <label>Full Transcript</label>
    <type>LongTextArea</type>
    <length>131072</length>
    <visibleLines>10</visibleLines>
    <required>false</required>
</CustomField>
```

- [ ] **Step 4: Deploy and verify**

Run: `sf project deploy start --source-dir force-app/main/default/objects/TelephoneCallTranscription__c --target-org CallListener`
Expected: `Status: Succeeded`

Run: `sf sobject describe --sobject TelephoneCallTranscription__c --target-org CallListener --json | jq '.fields[] | select(.name=="TelephoneCall__c" or .name=="FullTranscript__c") | {name, type}'`
Expected: `TelephoneCall__c` type `reference`, `FullTranscript__c` type `textarea`

- [ ] **Step 5: Commit**

```bash
git add force-app/main/default/objects/TelephoneCallTranscription__c
git commit -m "feat: add TelephoneCallTranscription__c custom object"
```

---

## Task 4: `TelephonyTranscription__e` Platform Event

**Files:**
- Create: `force-app/main/default/objects/TelephonyTranscription__e/TelephonyTranscription__e.object-meta.xml`
- Create: `force-app/main/default/objects/TelephonyTranscription__e/fields/UserId__c.field-meta.xml`
- Create: `force-app/main/default/objects/TelephonyTranscription__e/fields/CustomerId__c.field-meta.xml`
- Create: `force-app/main/default/objects/TelephonyTranscription__e/fields/CallId__c.field-meta.xml`
- Create: `force-app/main/default/objects/TelephonyTranscription__e/fields/TranscriptionChunk__c.field-meta.xml`

**Interfaces:**
- Produces: `TelephonyTranscription__e` platform event with `UserId__c`, `CustomerId__c`, `CallId__c`, `TranscriptionChunk__c` (all Text) — consumed by Task 8 (LWC empApi subscription) and Task 11 (Python script publish)

- [ ] **Step 1: Generate the platform event object**

Use the `platform-custom-object-generate` skill (it explicitly supports platform events), or hand-write:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <deploymentStatus>Deployed</deploymentStatus>
    <eventType>HighVolume</eventType>
    <publishBehavior>PublishAfterCommit</publishBehavior>
    <label>Telephony Transcription</label>
    <pluralLabel>Telephony Transcriptions</pluralLabel>
</CustomObject>
```

- [ ] **Step 2: Add the four Text fields**

```xml
<!-- UserId__c.field-meta.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>UserId__c</fullName>
    <label>User ID</label>
    <length>18</length>
    <type>Text</type>
    <required>true</required>
</CustomField>
```

```xml
<!-- CustomerId__c.field-meta.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>CustomerId__c</fullName>
    <label>Customer ID</label>
    <length>40</length>
    <type>Text</type>
    <required>true</required>
</CustomField>
```

```xml
<!-- CallId__c.field-meta.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>CallId__c</fullName>
    <label>Call ID</label>
    <length>40</length>
    <type>Text</type>
    <required>true</required>
</CustomField>
```

```xml
<!-- TranscriptionChunk__c.field-meta.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>TranscriptionChunk__c</fullName>
    <label>Transcription Chunk</label>
    <length>255</length>
    <type>Text</type>
    <required>true</required>
</CustomField>
```

- [ ] **Step 3: Deploy and verify**

Run: `sf project deploy start --source-dir force-app/main/default/objects/TelephonyTranscription__e --target-org CallListener`
Expected: `Status: Succeeded`

Run: `sf data query --target-org CallListener --use-tooling-api --query "SELECT DeveloperName, EventType FROM CustomObject WHERE DeveloperName='TelephonyTranscription'" --json | jq '.result.records'`
Expected: one record, confirming the object exists (EventType may not be queryable this way — if the query errors on the `EventType` column, drop it and just confirm the record exists)

- [ ] **Step 4: Commit**

```bash
git add force-app/main/default/objects/TelephonyTranscription__e
git commit -m "feat: add TelephonyTranscription__e platform event"
```

---

## Task 5: Permission Set + Assignment

**Files:**
- Create: `force-app/main/default/permissionsets/Call_Listener_POT.permissionset-meta.xml`

**Interfaces:**
- Consumes: `TelephoneCall__c`, `TelephoneCallTranscription__c` (Task 2, 3), `TelephonyTranscription__e` (Task 4), `CallListenerPotApi` Apex class (Task 6 — this step must run *after* Task 6, or the class-access entry deploys before the class exists and fails; sequence permission set deployment after Task 6 completes)
- Produces: `Call_Listener_POT` permission set, assigned to user `005gK00006wcklRQAQ`, granting object/field CRUD on both custom objects, publish+subscribe on the platform event, and Apex class access to `CallListenerPotApi`

- [ ] **Step 1: Generate the permission set**

Use the `platform-permission-set-generate` skill with these exact grants (or hand-write the XML below):

- Object permissions: `TelephoneCall__c` (Read, Create, Edit), `TelephoneCallTranscription__c` (Read, Create), `TelephonyTranscription__e` (Read, Create — Read enables subscribe, Create enables publish)
- Field permissions: Read+Edit on `TelephoneCall__c.CustomerId__c`, `TelephoneCall__c.Status__c`; Read+Edit on `TelephoneCallTranscription__c.TelephoneCall__c`, `TelephoneCallTranscription__c.FullTranscript__c`; Read+Edit on all four `TelephonyTranscription__e` fields
- Apex class access: `CallListenerPotApi`
- System permissions: `API Enabled`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>Call Listener POT</label>
    <hasActivationRequired>false</hasActivationRequired>
    <classAccesses>
        <apexClass>CallListenerPotApi</apexClass>
        <enabled>true</enabled>
    </classAccesses>
    <objectPermissions>
        <object>TelephoneCall__c</object>
        <allowCreate>true</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <viewAllRecords>false</viewAllRecords>
    </objectPermissions>
    <objectPermissions>
        <object>TelephoneCallTranscription__c</object>
        <allowCreate>true</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>false</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <viewAllRecords>false</viewAllRecords>
    </objectPermissions>
    <objectPermissions>
        <object>TelephonyTranscription__e</object>
        <allowCreate>true</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>false</allowEdit>
        <allowRead>true</allowRead>
    </objectPermissions>
    <fieldPermissions>
        <field>TelephoneCall__c.CustomerId__c</field>
        <readable>true</readable>
        <editable>true</editable>
    </fieldPermissions>
    <fieldPermissions>
        <field>TelephoneCall__c.Status__c</field>
        <readable>true</readable>
        <editable>true</editable>
    </fieldPermissions>
    <fieldPermissions>
        <field>TelephoneCallTranscription__c.TelephoneCall__c</field>
        <readable>true</readable>
        <editable>true</editable>
    </fieldPermissions>
    <fieldPermissions>
        <field>TelephoneCallTranscription__c.FullTranscript__c</field>
        <readable>true</readable>
        <editable>true</editable>
    </fieldPermissions>
    <fieldPermissions>
        <field>TelephonyTranscription__e.UserId__c</field>
        <readable>true</readable>
        <editable>true</editable>
    </fieldPermissions>
    <fieldPermissions>
        <field>TelephonyTranscription__e.CustomerId__c</field>
        <readable>true</readable>
        <editable>true</editable>
    </fieldPermissions>
    <fieldPermissions>
        <field>TelephonyTranscription__e.CallId__c</field>
        <readable>true</readable>
        <editable>true</editable>
    </fieldPermissions>
    <fieldPermissions>
        <field>TelephonyTranscription__e.TranscriptionChunk__c</field>
        <readable>true</readable>
        <editable>true</editable>
    </fieldPermissions>
</PermissionSet>
```

- [ ] **Step 2: Deploy (after Task 6's Apex class exists)**

Run: `sf project deploy start --source-dir force-app/main/default/permissionsets/Call_Listener_POT.permissionset-meta.xml --target-org CallListener`
Expected: `Status: Succeeded`

- [ ] **Step 3: Assign to the demo user**

Run: `sf org assign permset --name Call_Listener_POT --target-org CallListener --on-behalf-of 005gK00006wcklRQAQ`
Expected: assignment confirmation with no error

Run: `sf data query --target-org CallListener --query "SELECT Id FROM PermissionSetAssignment WHERE AssigneeId='005gK00006wcklRQAQ' AND PermissionSetId IN (SELECT Id FROM PermissionSet WHERE Name='Call_Listener_POT')" --json | jq '.result.totalSize'`
Expected: `1`

- [ ] **Step 4: Commit**

```bash
git add force-app/main/default/permissionsets
git commit -m "feat: add Call_Listener_POT permission set"
```

---

## Task 6: Apex REST API (`CallListenerPotApi`)

**Files:**
- Create: `force-app/main/default/classes/CallListenerPotApi.cls`
- Create: `force-app/main/default/classes/CallListenerPotApi.cls-meta.xml`
- Test: `force-app/main/default/classes/CallListenerPotApiTest.cls`
- Test meta: `force-app/main/default/classes/CallListenerPotApiTest.cls-meta.xml`

**Interfaces:**
- Consumes: `TelephoneCall__c` (Name, CustomerId__c, Status__c), `TelephoneCallTranscription__c` (TelephoneCall__c, FullTranscript__c) from Tasks 2-3
- Produces: `POST /services/apexrest/CallListenerPot/v1/calls` (body `{callId, customerId}`) and `PATCH /services/apexrest/CallListenerPot/v1/calls/{callId}/close` (body `{fullTranscript}`) — consumed by Task 11 (Python replay script)

- [ ] **Step 1: Write the test class first**

```apex
@isTest
private class CallListenerPotApiTest {

    @isTest
    static void testCreateCallInsertsOpenTelephoneCall() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/CallListenerPot/v1/calls';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{"callId":"call1","customerId":"customer1"}');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        CallListenerPotApi.createCall();
        Test.stopTest();

        TelephoneCall__c call = [SELECT Name, CustomerId__c, Status__c FROM TelephoneCall__c WHERE Name = 'call1'];
        System.assertEquals('customer1', call.CustomerId__c);
        System.assertEquals('Open', call.Status__c);
        System.assertEquals(201, RestContext.response.statusCode);
    }

    @isTest
    static void testCloseCallCreatesTranscriptionAndClosesCall() {
        TelephoneCall__c call = new TelephoneCall__c(Name = 'call1', CustomerId__c = 'customer1', Status__c = 'Open');
        insert call;

        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/CallListenerPot/v1/calls/call1/close';
        req.httpMethod = 'PATCH';
        req.requestBody = Blob.valueOf('{"fullTranscript":"Agent: Hello. Maria: Hi, I have a question about travel insurance."}');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        CallListenerPotApi.closeCall();
        Test.stopTest();

        TelephoneCall__c updatedCall = [SELECT Status__c FROM TelephoneCall__c WHERE Id = :call.Id];
        System.assertEquals('Closed', updatedCall.Status__c);

        TelephoneCallTranscription__c transcription = [
            SELECT FullTranscript__c FROM TelephoneCallTranscription__c WHERE TelephoneCall__c = :call.Id
        ];
        System.assert(transcription.FullTranscript__c.contains('Maria'));
        System.assertEquals(200, RestContext.response.statusCode);
    }
}
```

```xml
<!-- CallListenerPotApiTest.cls-meta.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>67.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Deploy the test class and confirm it fails (the implementation class doesn't exist yet)**

Run: `sf project deploy start --source-dir force-app/main/default/classes/CallListenerPotApiTest.cls --target-org CallListener`
Expected: FAIL — compile error, `CallListenerPotApi` does not exist

- [ ] **Step 3: Write the implementation class**

```apex
@RestResource(urlMapping='/CallListenerPot/v1/calls/*')
global with sharing class CallListenerPotApi {

    @HttpPost
    global static void createCall() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());
        String callId = (String) body.get('callId');
        String customerId = (String) body.get('customerId');

        TelephoneCall__c call = new TelephoneCall__c(
            Name = callId,
            CustomerId__c = customerId,
            Status__c = 'Open'
        );
        insert call;

        res.statusCode = 201;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'id' => call.Id,
            'callId' => call.Name,
            'status' => call.Status__c
        }));
    }

    @HttpPatch
    global static void closeCall() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        List<String> uriParts = req.requestURI.split('/');
        Integer closeIndex = uriParts.indexOf('close');
        String callId = uriParts[closeIndex - 1];

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());
        String fullTranscript = (String) body.get('fullTranscript');

        TelephoneCall__c call = [SELECT Id FROM TelephoneCall__c WHERE Name = :callId LIMIT 1];
        call.Status__c = 'Closed';
        update call;

        TelephoneCallTranscription__c transcription = new TelephoneCallTranscription__c(
            TelephoneCall__c = call.Id,
            FullTranscript__c = fullTranscript
        );
        insert transcription;

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'callId' => callId,
            'status' => 'Closed',
            'transcriptionId' => transcription.Id
        }));
    }
}
```

```xml
<!-- CallListenerPotApi.cls-meta.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>67.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 4: Deploy both classes and run tests**

Run: `sf project deploy start --source-dir force-app/main/default/classes --target-org CallListener --test-level RunSpecifiedTests --tests CallListenerPotApiTest`
Expected: `Status: Succeeded`, both test methods pass

- [ ] **Step 5: Commit**

```bash
git add force-app/main/default/classes
git commit -m "feat: add CallListenerPotApi REST resource with tests"
```

---

## Task 7: External Client App (Client Credentials Flow)

**Files:**
- Create: metadata determined by whichever skill generates it (likely under `force-app/main/default/connectedApps/` or `force-app/main/default/externalClientApps/` — confirm actual path from the skill's output before committing)

**Interfaces:**
- Consumes: run-as user `005gK00006wcklRQAQ`, `Call_Listener_POT` permission set (Task 5) for scoping what the client can do
- Produces: OAuth Client ID + Client Secret for the Python replay script (Task 11) to authenticate with

- [ ] **Step 1: Generate the External Client App**

Use the `integration-connectivity-connected-app-configure` skill (or `integration-connectivity-generate` if that's the correct one for External Client Apps specifically — check both skill descriptions before picking) with these exact requirements:

- Name: `CallListenerPotIntegration`
- OAuth flow: **Client Credentials Flow**
- Run-as user: `005gK00006wcklRQAQ`
- OAuth scopes: `api` (full REST API access), `refresh_token` omitted (not used in Client Credentials Flow)
- No user-facing login required — this is a machine-to-machine integration

This is flagged as uncertain metadata syntax in the spec — do not hand-write this XML from memory. If the skill cannot produce it, fall back to creating it manually in Setup UI (Setup → App Manager → New External Client App) and note in the commit message that it exists only in the org, not in source.

- [ ] **Step 2: Deploy (if generated as source) or configure manually (if done via Setup UI)**

Run: `sf project deploy start --source-dir <path-from-step-1> --target-org CallListener` (skip if configured manually)
Expected: `Status: Succeeded`, or manual confirmation the app is Active in Setup

- [ ] **Step 3: Retrieve the Client ID and Secret**

In Setup → App Manager → find `CallListenerPotIntegration` → View → Manage Consumer Details. Record the Consumer Key (Client ID) and Consumer Secret for use in Task 11 — do not commit these to git.

- [ ] **Step 4: Verify the Client Credentials Flow works**

Run:
```bash
curl -X POST https://trailsignup-dfdf8318b1de86.my.salesforce.com/services/oauth2/token \
  -d "grant_type=client_credentials" \
  -d "client_id=<CONSUMER_KEY>" \
  -d "client_secret=<CONSUMER_SECRET>"
```
Expected: JSON response containing `access_token`

- [ ] **Step 5: Commit (metadata only, never credentials)**

```bash
git add force-app/main/default/connectedApps force-app/main/default/externalClientApps 2>/dev/null
git commit -m "feat: add CallListenerPotIntegration external client app"
```

---

## Task 8: LWC — `callTranscriptionListener`

**Files:**
- Create: `force-app/main/default/lwc/callTranscriptionListener/callTranscriptionListener.js`
- Create: `force-app/main/default/lwc/callTranscriptionListener/callTranscriptionListener.html`
- Create: `force-app/main/default/lwc/callTranscriptionListener/callTranscriptionListener.js-meta.xml`

**Interfaces:**
- Consumes: `TelephonyTranscription__e` fields `UserId__c`, `CustomerId__c`, `CallId__c`, `TranscriptionChunk__c` (Task 4); current user Id via `@salesforce/user/Id`
- Produces: a utility-bar-exposable LWC — consumed by Task 9 (Utility Bar registration)

- [ ] **Step 1: Write the component JS**

```javascript
import { LightningElement, track } from 'lwc';
import currentUserId from '@salesforce/user/Id';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';

const CHANNEL_NAME = '/event/TelephonyTranscription__e';

export default class CallTranscriptionListener extends LightningElement {
    isListening = false;
    currentCallId = '';
    currentCustomerId = '';
    showTranscription = false;
    @track transcriptChunks = [];
    subscription = {};

    connectedCallback() {
        this.registerErrorListener();
        subscribe(CHANNEL_NAME, -1, (event) => this.handleEvent(event)).then((response) => {
            this.subscription = response;
        });
    }

    disconnectedCallback() {
        unsubscribe(this.subscription, () => {});
    }

    handleEvent(event) {
        const payload = event.data.payload;
        if (payload.UserId__c !== currentUserId) {
            return;
        }
        this.isListening = true;
        this.currentCallId = payload.CallId__c;
        this.currentCustomerId = payload.CustomerId__c;
        this.transcriptChunks = [...this.transcriptChunks, payload.TranscriptionChunk__c];
    }

    registerErrorListener() {
        onError((error) => {
            // eslint-disable-next-line no-console
            console.error('empApi subscription error', JSON.stringify(error));
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

- [ ] **Step 2: Write the template**

```html
<template>
    <lightning-card title="Call Transcription Listener" icon-name="utility:call">
        <div class="slds-p-horizontal_medium slds-p-bottom_medium">
            <p class="slds-text-heading_small">{statusMessage}</p>

            <lightning-input
                type="checkbox"
                label="Show incoming transcription"
                checked={showTranscription}
                onchange={handleToggleTranscription}
            ></lightning-input>

            <template if:true={showTranscriptFeed}>
                <div class="slds-box slds-scrollable_y slds-m-top_small" style="max-height: 200px;">
                    <template for:each={transcriptChunks} for:item="chunk" for:index="index">
                        <p key={index} class="slds-text-body_small">{chunk}</p>
                    </template>
                </div>
            </template>

            <div class="slds-box slds-theme_shade slds-m-top_medium">
                <p class="slds-text-title_caps">Recommendations</p>
                <p class="slds-text-body_small">
                    Knowledge Article and resolution recommendations will appear here. Not yet implemented.
                </p>
            </div>
        </div>
    </lightning-card>
</template>
```

- [ ] **Step 3: Write the meta config, exposing it as a Utility Bar item**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>67.0</apiVersion>
    <isExposed>true</isExposed>
    <targets>
        <target>lightning__UtilityBar</target>
    </targets>
</LightningComponentBundle>
```

- [ ] **Step 4: Deploy and verify**

Run: `sf project deploy start --source-dir force-app/main/default/lwc/callTranscriptionListener --target-org CallListener`
Expected: `Status: Succeeded`

- [ ] **Step 5: Commit**

```bash
git add force-app/main/default/lwc/callTranscriptionListener
git commit -m "feat: add callTranscriptionListener LWC"
```

---

## Task 9: Register the LWC on the Service Console Utility Bar

**Files:**
- Modify: whichever metadata the `platform-lightning-app-coordinate` skill produces/updates for the `LightningService` app's utility bar

**Interfaces:**
- Consumes: `callTranscriptionListener` LWC (Task 8), target app `LightningService`

- [ ] **Step 1: Register the utility item**

This metadata (Utility Bar / App association) is flagged as uncertain in the spec — do not hand-write it. Use the `platform-lightning-app-coordinate` skill to add `callTranscriptionListener` as a utility item on the `LightningService` app, with:

- Icon: `utility:call`
- Label: `Call Transcription Listener`
- Panel width/height: default
- Do not enable "start automatically" — the component should behave the same whether opened manually or auto-started; if the skill requires a choice, pick manual to match the "Listening for ongoing calls..." idle-state UX from the spec

- [ ] **Step 2: Deploy**

Run: `sf project deploy start --source-dir <path-from-step-1> --target-org CallListener`
Expected: `Status: Succeeded`

- [ ] **Step 3: Verify manually in the org**

Open the org (`sf org open --target-org CallListener`), switch to the Service Console app, confirm the utility bar shows a "Call Transcription Listener" item, and clicking it opens the panel showing "Listening for ongoing calls..."

- [ ] **Step 4: Commit**

```bash
git add force-app/main/default/applications force-app/main/default/flexipages 2>/dev/null
git commit -m "feat: register callTranscriptionListener on Service Console utility bar"
```

---

## Task 10: Seed Knowledge Articles

**Files:** None (data only, created via CLI against the org — no metadata to commit)

**Interfaces:**
- Produces: 2-3 published `Knowledge__kav` records used as future input for the LWC's recommendation panel (not wired up yet)

- [ ] **Step 1: Discover the article type's body field**

Run: `sf sobject describe --sobject Knowledge__kav --target-org CallListener --json | jq '.fields[] | select(.custom==true) | {name, type, label}'`

This tells you the actual rich-text/body field name for this org's "Knowledge" article type (it varies per org's Knowledge setup) — use whatever field name comes back in place of `<BODY_FIELD>` below.

- [ ] **Step 2: Create the draft articles**

Run three times with different content (values below; `<BODY_FIELD>` from Step 1):

```bash
sf data create record --sobject Knowledge__kav --target-org CallListener --values "Title='Travel Insurance Coverage — United States' UrlName='travel-insurance-coverage-united-states' Summary='Overview of medical, trip cancellation, and baggage coverage for policyholders traveling to the United States.' <BODY_FIELD>='Policies covering travel to the United States include emergency medical treatment up to \$250,000, trip cancellation reimbursement for covered reasons, and baggage loss protection. Claims can be filed via the mobile app or website.'"
```

```bash
sf data create record --sobject Knowledge__kav --target-org CallListener --values "Title='Filing a Claim for Medical Expenses Abroad' UrlName='filing-claim-medical-expenses-abroad' Summary='Step-by-step guide for policyholders filing a medical expense claim while traveling internationally.' <BODY_FIELD>='To file a medical expense claim, submit itemized receipts and a completed claim form through the mobile app or website. Claims teams typically respond within 48 hours.'"
```

```bash
sf data create record --sobject Knowledge__kav --target-org CallListener --values "Title='Trip Cancellation and Interruption Coverage — FAQ' UrlName='trip-cancellation-interruption-coverage-faq' Summary='Frequently asked questions about what qualifies for trip cancellation or interruption reimbursement.' <BODY_FIELD>='Covered reasons for trip cancellation include family emergencies, sudden illness, and other qualifying events listed in the policy. Reimbursement covers prepaid, non-refundable expenses such as flights and hotel bookings.'"
```

Record the three returned record Ids for Step 3.

- [ ] **Step 3: Publish the articles**

Run (once per article Id from Step 2):

```bash
sf apex run --target-org CallListener --file - <<'EOF'
KbManagement.PublishingService.publishArticle('<ARTICLE_ID>', true);
EOF
```

- [ ] **Step 4: Verify**

Run: `sf data query --target-org CallListener --query "SELECT Title, PublishStatus FROM Knowledge__kav WHERE PublishStatus='Online'" --json | jq '.result.records'`
Expected: 3 records, all `PublishStatus: "Online"`

---

## Task 11: Python Replay Script

**Files:**
- Create: `scripts/replay_call.py`
- Create: `scripts/requirements.txt`
- Test: `scripts/test_replay_call.py`

**Interfaces:**
- Consumes: `CallListenerPotApi` REST endpoints (Task 6), `TelephonyTranscription__e` (Task 4), OAuth credentials from Task 7
- Produces: `chunk_words(text: str, size: int) -> list[str]` (pure function, unit-tested), `main()` entry point that drives the full demo call end-to-end

- [ ] **Step 1: Write the failing test for chunking logic**

```python
# scripts/test_replay_call.py
from replay_call import chunk_words


def test_chunk_words_splits_into_groups_of_ten():
    text = " ".join(f"word{i}" for i in range(25))
    chunks = chunk_words(text, size=10)
    assert len(chunks) == 3
    assert chunks[0] == " ".join(f"word{i}" for i in range(10))
    assert chunks[2] == "word20 word21 word22 word23 word24"


def test_chunk_words_handles_exact_multiple():
    text = " ".join(f"word{i}" for i in range(20))
    chunks = chunk_words(text, size=10)
    assert len(chunks) == 2
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd scripts && python -m pytest test_replay_call.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'replay_call'`

- [ ] **Step 3: Write `scripts/requirements.txt`**

```
requests>=2.31.0
```

- [ ] **Step 4: Write `scripts/replay_call.py`**

```python
import os
import time
import requests

INSTANCE_URL = os.environ["SF_INSTANCE_URL"]
CLIENT_ID = os.environ["SF_CLIENT_ID"]
CLIENT_SECRET = os.environ["SF_CLIENT_SECRET"]
API_VERSION = "v67.0"

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


def publish_chunks(session):
    for chunk in chunk_words(CALL_SCRIPT, size=CHUNK_SIZE):
        url = f"{INSTANCE_URL}/services/data/{API_VERSION}/sobjects/TelephonyTranscription__e"
        payload = {
            "UserId__c": USER_ID,
            "CustomerId__c": CUSTOMER_ID,
            "CallId__c": CALL_ID,
            "TranscriptionChunk__c": chunk,
        }
        response = session.post(url, json=payload, timeout=30)
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
    publish_chunks(session)
    close_call(session)


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `cd scripts && python -m pytest test_replay_call.py -v`
Expected: PASS, both tests

- [ ] **Step 6: Commit**

```bash
git add scripts
git commit -m "feat: add replay_call.py demo script with chunking tests"
```

---

## Task 12: Deploy Everything and Run the End-to-End Demo

**Files:** None (verification-only task)

**Interfaces:**
- Consumes: all previous tasks

- [ ] **Step 1: Full deploy**

Run: `sf project deploy start --source-dir force-app --target-org CallListener`
Expected: `Status: Succeeded`, all components deployed

- [ ] **Step 2: Confirm the permission set assignment survived (re-run Task 5 Step 3's query if needed)**

Run: `sf data query --target-org CallListener --query "SELECT Id FROM PermissionSetAssignment WHERE AssigneeId='005gK00006wcklRQAQ' AND PermissionSetId IN (SELECT Id FROM PermissionSet WHERE Name='Call_Listener_POT')" --json | jq '.result.totalSize'`
Expected: `1`

- [ ] **Step 3: Open the org as the demo user and open the utility bar item**

Run: `sf org open --target-org CallListener`
In the browser: switch to the Service Console app, log in/impersonate as the user tied to `005gK00006wcklRQAQ` if not already, open the "Call Transcription Listener" utility item. Confirm it shows "Listening for ongoing calls..."

- [ ] **Step 4: Run the replay script while watching the LWC**

Set environment variables from Task 7 Step 3, then run:

```bash
export SF_INSTANCE_URL="https://trailsignup-dfdf8318b1de86.my.salesforce.com"
export SF_CLIENT_ID="<CONSUMER_KEY>"
export SF_CLIENT_SECRET="<CONSUMER_SECRET>"
cd scripts && python replay_call.py
```

Since this drives a live UI feature with no automated LWC test in scope, verify manually and describe what you see: within a few seconds of the first published event, the panel should update to `Now listening to call "call1" from customer ID "customer1"`. Toggling "Show incoming transcription" should reveal the chunks arriving roughly every 4 seconds, in script order.

- [ ] **Step 5: Confirm the closed call and transcription record**

Run: `sf data query --target-org CallListener --query "SELECT Name, Status__c FROM TelephoneCall__c WHERE Name='call1'" --json | jq '.result.records'`
Expected: `Status__c: "Closed"`

Run: `sf data query --target-org CallListener --query "SELECT FullTranscript__c FROM TelephoneCallTranscription__c WHERE TelephoneCall__c.Name='call1'" --json | jq '.result.records[0].FullTranscript__c' | head -c 200`
Expected: transcript text starting with "Agent: Thank you for calling Global Shield Insurance..."

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "chore: complete Call Listener POT end-to-end verification"
```
