import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import currentUserId from '@salesforce/user/Id';
import SIGNALR_LIB from '@salesforce/resourceUrl/signalRClient';
import getConnectionInfo from '@salesforce/apex/CallListenerSignalRConfig.getConnectionInfo';
import knowledgeSearch from '@salesforce/apex/CallListenerRecommendation.knowledgeSearch';
import resolution from '@salesforce/apex/CallListenerRecommendation.resolution';

const RESOLUTION_CHUNK_INTERVAL = 3;
const TRANSCRIPTION_CHUNK_EVENT = 'TranscriptionChunk';

export default class CallTranscriptionListener extends LightningElement {
    isListening = false;
    currentCallId = '';
    currentCustomerId = '';
    showTranscription = false;
    @track transcriptChunks = [];
    @track knowledgeArticles = [];
    resolutionText = '';
    isResolutionLoading = false;
    chunkCount = 0;
    connection;

    connectedCallback() {
        loadScript(this, SIGNALR_LIB)
            .then(() => getConnectionInfo())
            .then(({ hubUrl, accessToken }) => this.startConnection(hubUrl, accessToken))
            .catch((error) => {
                // eslint-disable-next-line no-console
                console.error('Failed to start SignalR connection', JSON.stringify(error));
            });
    }

    disconnectedCallback() {
        if (this.connection) {
            this.connection.stop();
        }
    }

    startConnection(hubUrl, accessToken) {
        // eslint-disable-next-line no-undef
        this.connection = new signalR.HubConnectionBuilder()
            .withUrl(hubUrl, { accessTokenFactory: () => accessToken, withCredentials: false })
            .withAutomaticReconnect()
            .build();

        this.connection.on(TRANSCRIPTION_CHUNK_EVENT, (payload) => this.handleEvent(payload));
        this.connection.onreconnecting((error) => {
            // eslint-disable-next-line no-console
            console.error('SignalR reconnecting', error);
        });
        this.connection.onclose((error) => {
            // eslint-disable-next-line no-console
            console.error('SignalR connection closed', error);
        });

        return this.connection.start();
    }

    handleEvent(payload) {
        // eslint-disable-next-line no-console
        console.debug('Received transcription chunk', payload);
        if (payload.userId !== currentUserId) {
            return;
        }
        if (this.isListening && payload.callId !== this.currentCallId) {
            this.resetCallState();
        }
        this.isListening = true;
        this.currentCallId = payload.callId;
        this.currentCustomerId = payload.customerId;
        this.transcriptChunks = [...this.transcriptChunks, payload.transcriptionChunk];
        this.chunkCount += 1;

        const fullTranscript = this.transcriptChunks.join(' ');
        this.fetchKnowledgeArticles(fullTranscript);

        if (this.chunkCount % RESOLUTION_CHUNK_INTERVAL === 0) {
            this.fetchResolution(fullTranscript);
        }
    }

    resetCallState() {
        this.transcriptChunks = [];
        this.knowledgeArticles = [];
        this.resolutionText = '';
        this.chunkCount = 0;
    }

    fetchKnowledgeArticles(fullTranscript) {
        knowledgeSearch({ queryText: fullTranscript })
            .then((results) => {
                this.knowledgeArticles = results;
            })
            .catch((error) => {
                // eslint-disable-next-line no-console
                console.error('knowledgeSearch failed', JSON.stringify(error));
            });
    }

    fetchResolution(fullTranscript) {
        this.isResolutionLoading = true;
        resolution({ fullTranscript })
            .then((generatedText) => {
                this.resolutionText = generatedText;
            })
            .catch((error) => {
                // eslint-disable-next-line no-console
                console.error('resolution failed', JSON.stringify(error));
            })
            .finally(() => {
                this.isResolutionLoading = false;
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
