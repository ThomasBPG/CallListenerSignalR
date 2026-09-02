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
