public with sharing class CallListenerRecommendation {

    private static final String SEARCH_INDEX = 'Knowledge_Article_Version_index__dlm';
    private static final String CHUNK_DMO = 'Knowledge_Article_Version_chunk__dlm';
    private static final String SOURCE_DMO = 'ssot__KnowledgeArticleVersion__dlm';
    private static final Integer TOP_K = 5;
    private static final String PROMPT_TEMPLATE_NAME = 'CreateCallRecommendation';
    private static final String PROMPT_TEMPLATE_INPUT_KEY = 'Input:transcription';
    private static final String LLM_APPLICATION_NAME = 'PromptTemplateGenerationsInvocable';

    public class KnowledgeArticleResult {
        @AuraEnabled public String articleId;
        @AuraEnabled public String articleNumber;
        @AuraEnabled public String title;
        @AuraEnabled public String url;
        @AuraEnabled public String snippet;
        @AuraEnabled public Decimal score;
    }

    @AuraEnabled
    public static List<KnowledgeArticleResult> knowledgeSearch(String queryText) {
        if (Test.isRunningTest()) {
            KnowledgeArticleResult mockResult = new KnowledgeArticleResult();
            mockResult.articleId = 'ka0xx0000000001AAA';
            mockResult.articleNumber = '000001000';
            mockResult.title = 'Mock Knowledge Article';
            mockResult.url = 'mock-knowledge-article';
            mockResult.snippet = 'Mock chunk text for ' + queryText;
            mockResult.score = 0.9;
            return new List<KnowledgeArticleResult>{ mockResult };
        }

        String sql = 'SELECT v.score__c AS Score__c, c.Chunk__c AS Chunk__c, k.ssot__Id__c AS ArticleId__c, ' +
            'k.ssot__ArticleNumber__c AS ArticleNumber__c, k.ssot__Name__c AS Title__c, k.ssot__URL__c AS Url__c ' +
            'FROM vector_search(TABLE(' + SEARCH_INDEX + '), \'' + queryText.replace('\'', '\'\'') + '\', \'\', ' + TOP_K + ') v ' +
            'JOIN ' + CHUNK_DMO + ' c ON v.RecordId__c = c.RecordId__c ' +
            'JOIN ' + SOURCE_DMO + ' k ON c.SourceRecordId__c = k.ssot__Id__c ' +
            'ORDER BY v.score__c DESC LIMIT ' + TOP_K;

        ConnectApi.CdpQueryInput queryInput = new ConnectApi.CdpQueryInput();
        queryInput.sql = sql;
        ConnectApi.CdpQueryOutput output = ConnectApi.CdpQuery.queryANSISql(queryInput);

        List<KnowledgeArticleResult> results = new List<KnowledgeArticleResult>();
        if (output.data == null) {
            return results;
        }
        for (Object row : output.data) {
            Map<String, Object> rowMap = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(row));
            KnowledgeArticleResult result = new KnowledgeArticleResult();
            result.articleId = (String) rowMap.get('ArticleId__c');
            result.articleNumber = (String) rowMap.get('ArticleNumber__c');
            result.title = (String) rowMap.get('Title__c');
            result.url = (String) rowMap.get('Url__c');
            result.snippet = (String) rowMap.get('Chunk__c');
            result.score = (Decimal) rowMap.get('Score__c');
            results.add(result);
        }
        return results;
    }

    @AuraEnabled
    public static String resolution(String fullTranscript) {
        if (Test.isRunningTest()) {
            return 'Mock resolution for transcript of length ' + fullTranscript.length();
        }

        ConnectApi.EinsteinPromptTemplateGenerationsInput promptInput = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        promptInput.isPreview = false;

        ConnectApi.WrappedValue transcriptValue = new ConnectApi.WrappedValue();
        transcriptValue.value = fullTranscript;

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put(PROMPT_TEMPLATE_INPUT_KEY, transcriptValue);
        promptInput.inputParams = inputParams;

        promptInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        promptInput.additionalConfig.applicationName = LLM_APPLICATION_NAME;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PROMPT_TEMPLATE_NAME, promptInput);

        if (output.generations == null || output.generations.isEmpty()) {
            return null;
        }
        return output.generations[0].text;
    }
}
