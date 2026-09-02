@isTest
private class CallListenerRecommendationTest {

    @isTest
    static void testKnowledgeSearchReturnsMockResultInTestContext() {
        Test.startTest();
        List<CallListenerRecommendation.KnowledgeArticleResult> results =
            CallListenerRecommendation.knowledgeSearch('travel insurance claim');
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('Mock Knowledge Article', results[0].title);
        System.assert(results[0].snippet.contains('travel insurance claim'));
    }

    @isTest
    static void testResolutionReturnsMockTextInTestContext() {
        String transcript = 'Agent: Hello. Maria: Hi, I have a question about travel insurance.';

        Test.startTest();
        String resolutionText = CallListenerRecommendation.resolution(transcript);
        Test.stopTest();

        System.assert(resolutionText.contains(String.valueOf(transcript.length())));
    }
}
