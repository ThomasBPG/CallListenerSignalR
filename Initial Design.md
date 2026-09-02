I need to build a proof of technology (POT) that shows how we in realtime can stream transcriptions of a telephone call into Salesforce via Platform Events and have a Lightning Web Component attached to the stream of the transcription and show relevant Knowledge articles and even propose solutions to the dialog being discussed in the telephone call.

Deploy the solution to the Salesforce org already authenticated with the Salesforce CLI alias "CallListener". 

The following are the elements that I propose to have in the architecture of the POT:

1) The intake of telephone calls and transcription via Platform Events and REST API
Create a custom object named "TelephoneCall__c" with custom fields "customerId" (text field).
The first step in the flow of the POT is that a TelephoneCall__c record is created by the external telephony platform with a REST API call. The standard Name field should be used to store call IDs in the form "call1", "call2" etc.

Create a Platform Event named "TelephonyTranscription" with the following fields:
"userId" (text field) to identify the user in Salesforce and the external telephony system the transcription element belongs to. Assume record IDs from Salesforces User object to be used here.
"customerId" (text field) to identify the customer the transcription element belongs to.
"callId" (text field) to identify the call ID the transcription element belongs to.
"transcriptionChunk" (text field) to store the chunks of transcribed text

2) The Lightning Web Component to show recommended Knowledge articles and proposed solutions
The Lightning Web Component (LWC) should use the Salesforce empAPI to listen to Platform Events created in element 1) above.

I would like the user experience to be like:
When opening the LWC it should say "Listening for ongoing calls...". 
When Platform events start coming in, the LWC should refresh and say something like "Now listening to call "call1" from customer ID "customer1".
Using a Checkbox saying "Show incoming trascription", the user should be able to toggle on and off, whether we want to see the incoming transcription coming in the platform event.

Create a placeholder in the LWC that can show recommendations in the form of Knowledge Articles or actual resolutions. Don't implement this part yet, but keep a placeholder in the LWC where we can implement this later.

Build and add the Lightning Web Component to be in the Utility Bar of the Lightning App named "Service". Use SLDS as design, so it looks like the rest of Salesforce.

3) The replay script and Knowledge Articles. 
This is a POT and I need to be able to demonstrate it easily. Create a fictive script for a telephone in an insurance company where a customer "Maria Jensen" with customer ID "customer1" calls in with questions about travel insurance coverage in the United States. 
Create an External Client app and a simple Python script uses it to submit the telephone call first with a call ID "call1" and customer ID "customer1". Everything for user ID "005gK00006wcklRQAQ". After the API call to create the call, submit platform events as created in element 1) and use a pause of 4 sek. to submit the fictive script transcription in chunks of 10 words.

Other brainstorming points:

Please challenge me in this brainstorm. I want specifically to be challenged on architecture, cost perspectives and scaleability.
