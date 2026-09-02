import os
import time

import requests

INSTANCE_URL = os.environ["SF_INSTANCE_URL"]
CLIENT_ID = os.environ["SF_CLIENT_ID"]
CLIENT_SECRET = os.environ["SF_CLIENT_SECRET"]
SIGNALR_SERVER_URL = os.environ["SIGNALR_SERVER_URL"]
SIGNALR_ACCESS_TOKEN = os.environ["SIGNALR_ACCESS_TOKEN"]

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


def publish_chunks():
    url = f"{SIGNALR_SERVER_URL}/api/chunks"
    headers = {"X-Api-Key": SIGNALR_ACCESS_TOKEN}
    for chunk in chunk_words(CALL_SCRIPT, size=CHUNK_SIZE):
        payload = {
            "userId": USER_ID,
            "customerId": CUSTOMER_ID,
            "callId": CALL_ID,
            "transcriptionChunk": chunk,
        }
        response = requests.post(url, json=payload, headers=headers, timeout=30)
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
    publish_chunks()
    close_call(session)


if __name__ == "__main__":
    main()
