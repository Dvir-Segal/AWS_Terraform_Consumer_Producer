from flask import Flask, request, jsonify
import boto3
import os
import json
from datetime import datetime

app = Flask(__name__)

AWS_REGION = os.getenv("AWS_REGION", "us-west-1")
AWS_ENDPOINT_URL = os.getenv("AWS_ENDPOINT_URL")

boto3_client_params = {
    'region_name': AWS_REGION
}

if AWS_ENDPOINT_URL:
    boto3_client_params['endpoint_url'] = AWS_ENDPOINT_URL

ssm = boto3.client("ssm", **boto3_client_params)
sqs = boto3.client("sqs", **boto3_client_params)

# Load token from SSM once on startup
AUTH_TOKEN = ssm.get_parameter(Name="/microservice1/token", WithDecryption=True)["Parameter"]["Value"]
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL")

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
