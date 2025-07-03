import os
import time
import json
import logging
import boto3
from botocore.exceptions import BotoCoreError, ClientError
from datetime import datetime

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

# Load environment variables
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL")
S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME")
AWS_REGION = os.getenv("AWS_REGION", "us-west-1")

if not SQS_QUEUE_URL or not S3_BUCKET_NAME:
    logging.error("Missing required environment variables: SQS_QUEUE_URL or S3_BUCKET_NAME")
    exit(1)

# Initialize AWS clients
sqs = boto3.client("sqs", region_name=AWS_REGION)
s3 = boto3.client("s3", region_name=AWS_REGION)

def process_message(message_body: dict) -> None:
    """Uploads message body to S3 with a timestamp-based key."""
    timestamp = datetime.utcnow().strftime("%Y-%m-%dT%H-%M-%S-%fZ")
    s3_key = f"messages/message-{timestamp}.json"
    try:
        s3.put_object(Bucket=S3_BUCKET_NAME, Key=s3_key, Body=json.dumps(message_body))
        logging.info(f"Uploaded message to S3 at {s3_key}")
    except (BotoCoreError, ClientError) as e:
        logging.error(f"Failed to upload message to S3: {e}")
        raise

def poll_queue():
    """Polls the SQS queue every 15 seconds and processes messages."""
    logging.info("Starting Microservice 2 polling loop...")
    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=5,
                VisibilityTimeout=30
            )

            messages = response.get("Messages", [])
            if not messages:
                logging.info("No messages received. Waiting...")
            else:
                for msg in messages:
                    try:
                        body = json.loads(msg["Body"])
                        process_message(body)
                        sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
                        logging.info("Deleted message from SQS.")
                    except Exception as e:
                        logging.error(f"Error processing message: {e}")

        except (BotoCoreError, ClientError) as e:
            logging.error(f"Polling error: {e}")

        time.sleep(15)

if __name__ == "__main__":
    poll_queue()