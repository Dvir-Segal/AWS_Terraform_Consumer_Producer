from flask import Flask, request, jsonify
import boto3
import os
import json
from datetime import datetime
from prometheus_client import generate_latest, Counter, Histogram, Gauge

app = Flask(__name__)

ssm = boto3.client("ssm", region_name=os.getenv("AWS_REGION", "us-west-1"))
sqs = boto3.client("sqs", region_name=os.getenv("AWS_REGION", "us-west-1"))

# Load token from SSM once on startup
AUTH_TOKEN = ssm.get_parameter(Name="/microservice1/token", WithDecryption=True)["Parameter"]["Value"]
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL")

# --- START OF PROMETHEUS METRICS DEFINITIONS ---
REQUEST_COUNT = Counter(
    'http_requests_total', 'Total HTTP Requests', ['method', 'endpoint']
)
REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds', 'HTTP Request Latency', ['method', 'endpoint']
)
SQS_MESSAGES_SENT = Counter(
    'sqs_messages_sent_total', 'Total messages sent to SQS'
)
UNAUTHORIZED_ACCESS_COUNT = Counter(
    'unauthorized_access_total', 'Total unauthorized access attempts'
)
HEALTH_STATUS = Gauge('app_health_status', 'Application Health Status (1=OK, 0=Degraded)')
# --- END OF PROMETHEUS METRICS DEFINITIONS ---

# --- NEW ENDPOINT FOR PROMETHEUS SCRAPING ---
@app.route("/metrics")
def metrics():
    """
    Exposes Prometheus metrics for scraping.
    """
    return generate_latest(), 200, {'Content-Type': 'text/plain; version=0.0.4; charset=utf-8'}
# --- END NEW ENDPOINT ---

@app.route("/message", methods=["POST"])
def receive_message():
    try:
        data = request.get_json()
        if not data or "data" not in data or "token" not in data:
            return jsonify({"error": "Invalid request format"}), 400

        token = data["token"]
        message_data = data["data"]

        # Validate token
        if token != AUTH_TOKEN:
            return jsonify({"error": "Unauthorized"}), 401

        # Validate timestamp
        if "email_timestamp" not in message_data:
            return jsonify({"error": "Missing email_timestamp"}), 400
        try:
            timestamp = int(message_data["email_timestamp"])
            datetime.fromtimestamp(timestamp)  # validation
        except ValueError:
            return jsonify({"error": "Invalid email_timestamp"}), 400

        # Send to SQS
        sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(message_data)
        )

        return jsonify({"status": "Message sent to SQS"}), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/", methods=["GET"])
def health_check():
    return "Microservice 1 OK", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
