public with sharing class CallListenerSignalRConfig {

    public class ConnectionInfo {
        @AuraEnabled public String hubUrl;
        @AuraEnabled public String accessToken;
    }

    @AuraEnabled(cacheable=true)
    public static ConnectionInfo getConnectionInfo() {
        SignalR_Config__mdt config = SignalR_Config__mdt.getInstance('Default');

        ConnectionInfo info = new ConnectionInfo();
        info.hubUrl = config.Hub_Url__c;
        info.accessToken = config.Access_Token__c;
        return info;
    }
}
