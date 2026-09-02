@isTest
private class CallListenerSignalRConfigTest {

    @isTest
    static void testGetConnectionInfoReturnsConfiguredValues() {
        Test.startTest();
        CallListenerSignalRConfig.ConnectionInfo info = CallListenerSignalRConfig.getConnectionInfo();
        Test.stopTest();

        System.assertNotEquals(null, info.hubUrl);
        System.assertNotEquals(null, info.accessToken);
    }
}
