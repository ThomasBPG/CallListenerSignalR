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
