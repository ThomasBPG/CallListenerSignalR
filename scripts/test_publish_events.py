"""
Ad-hoc manual test: publishes a few transcription chunks directly to the
SignalR server's /api/chunks endpoint, bypassing create_call/close_call.
Use this to verify the callTranscriptionListener LWC receives and renders
live events end-to-end, independent of the Salesforce call-bookkeeping flow.

Not part of the plan's committed deliverables - run manually.
"""
import time

import requests

from replay_call import (
    CALL_SCRIPT,
    USER_ID,
    CUSTOMER_ID,
    CALL_ID,
    CHUNK_SIZE,
    SIGNALR_SERVER_URL,
    SIGNALR_ACCESS_TOKEN,
    chunk_words,
)

NUM_CHUNKS_TO_SEND = 3
DELAY_SECONDS = 3


def publish_chunk(chunk):
    url = f"{SIGNALR_SERVER_URL}/api/chunks"
    headers = {"X-Api-Key": SIGNALR_ACCESS_TOKEN}
    payload = {
        "userId": USER_ID,
        "customerId": CUSTOMER_ID,
        "callId": CALL_ID,
        "transcriptionChunk": chunk,
    }
    response = requests.post(url, json=payload, headers=headers, timeout=30)
    response.raise_for_status()
    print(f"Published: {chunk}")


def main():
    chunks = chunk_words(CALL_SCRIPT, size=CHUNK_SIZE)[:NUM_CHUNKS_TO_SEND]
    for chunk in chunks:
        publish_chunk(chunk)
        time.sleep(DELAY_SECONDS)


if __name__ == "__main__":
    main()
