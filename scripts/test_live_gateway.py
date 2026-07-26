import os
import sys
import json
import urllib.request

def send_chat_completion():
    port = os.environ.get("GATEWAY_PORT", "4000")
    master_key = os.environ.get("GATEWAY_MASTER_KEY", "sk-glm52-master-secret-key-change-me")
    url = f"http://localhost:{port}/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {master_key}",
        "Content-Type": "application/json"
    }
    payload = {
        "model": "glm-5.2-moe",
        "messages": [{"role": "user", "content": "Explain the significance of BigQuery audit trajectory sinks in sovereign AI serving in 2 sentences."}],
        "temperature": 0.2,
        "max_tokens": 100
    }
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
            content = data["choices"][0]["message"]["content"]
            print(f"[OK] Live Chat completion output:\n{content.strip()}")
            return 0
    except Exception as e:
        print(f"[FAIL] Request error: {e}")
        return 1

if __name__ == "__main__":
    sys.exit(send_chat_completion())
