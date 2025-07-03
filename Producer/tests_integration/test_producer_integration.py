import unittest
import os
import sys
import json
import boto3
from datetime import datetime, UTC  # Python 3.9+ for UTC

# Add parent directory to Python path to import 'app' module
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
import app as producer_app  # Import your Producer's Flask app module

# --- Environment Setup for LocalStack Connection ---
# These environment variables will be picked up by your modified app.py
# and by boto3 clients used within this test file.
os.environ["AWS_ACCESS_KEY_ID"] = "test"
os.environ["AWS_SECRET_ACCESS_KEY"] = "test"
os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
os.environ["AWS_ENDPOINT_URL"] = "http://localhost:4566"  # LocalStack endpoint

# Define the SQS Queue URL that your Producer will use.
# LocalStack uses '000000000000' as the default AWS Account ID.
TEST_SQS_QUEUE_URL = f"{os.environ['AWS_ENDPOINT_URL']}/000000000000/producer-integration-test-queue"
os.environ["SQS_QUEUE_URL"] = TEST_SQS_QUEUE_URL  # Set for producer_app

# Define the Auth Token that your Producer expects from SSM.
TEST_AUTH_TOKEN = "your_secret_test_token_for_producer"  # ***CHANGE THIS to your desired test token***


# --- Integration Test Class ---
class TestProducerIntegration(unittest.TestCase):
    # boto3 clients for direct interaction with LocalStack (for setup/teardown/verification)
    test_sqs_client = None
    test_ssm_client = None
    queue_url = None
    queue_name = None

    @classmethod
    def setUpClass(cls):
        """
        Runs once before all tests in this class.
        Initializes boto3 clients for LocalStack, creates the SQS queue,
        and puts the SSM parameter required by the Producer.
        """
        print("\n--- Setting up Producer Integration Tests ---")

        # Initialize boto3 clients for test script's direct LocalStack interaction
        cls.test_sqs_client = boto3.client(
            'sqs',
            region_name=os.environ["AWS_DEFAULT_REGION"],
            endpoint_url=os.environ["AWS_ENDPOINT_URL"]
        )
        cls.test_ssm_client = boto3.client(
            'ssm',
            region_name=os.environ["AWS_DEFAULT_REGION"],
            endpoint_url=os.environ["AWS_ENDPOINT_URL"]
        )

        # Create SQS queue in LocalStack
        cls.queue_url = os.environ["SQS_QUEUE_URL"]
        cls.queue_name = cls.queue_url.split('/')[-1]
        print(f"Creating SQS queue '{cls.queue_name}' at {cls.queue_url} in LocalStack...")
        try:
            cls.test_sqs_client.create_queue(QueueName=cls.queue_name)
            print(f"Queue '{cls.queue_name}' created successfully.")
        except Exception as e:
            print(f"Error creating queue, attempting to get existing queue URL: {e}")
            try:
                response = cls.test_sqs_client.get_queue_url(QueueName=cls.queue_name)
                cls.queue_url = response['QueueUrl']
                print(f"Found existing queue: {cls.queue_url}")
            except Exception as get_e:
                print(f"Failed to get queue URL: {get_e}")
                raise RuntimeError(f"Could not create or get SQS queue: {e}. Is LocalStack running and accessible?")

        # Create SSM parameter in LocalStack for AUTH_TOKEN
        print(f"Putting SSM parameter '/microservice1/token' with value '{TEST_AUTH_TOKEN}' in LocalStack...")
        try:
            cls.test_ssm_client.put_parameter(
                Name="/microservice1/token",
                Value=TEST_AUTH_TOKEN,
                Type="SecureString",  # Producer expects SecureString type
                Overwrite=True
            )
            print("SSM parameter created/updated successfully.")
        except Exception as e:
            print(f"Error creating/updating SSM parameter: {e}")
            raise RuntimeError(f"Could not create SSM parameter: {e}. Is LocalStack SSM service running?")

        # Optional: Suppress logging from producer_app during tests for cleaner output
        # (Assumes producer_app uses Python's standard 'logging' module)
        if hasattr(producer_app, 'logging'):
            cls._original_app_logging_level = producer_app.logging.getLogger().level
            producer_app.logging.getLogger().setLevel(producer_app.logging.CRITICAL)

        print("--- Producer Integration Setup Complete ---")

    @classmethod
    def tearDownClass(cls):
        """
        Runs once after all tests in this class.
        Deletes the SQS queue and SSM parameter from LocalStack.
        """
        print("\n--- Tearing down Producer Integration Tests ---")
        try:
            cls.test_sqs_client.delete_queue(QueueUrl=cls.queue_url)
            print(f"Queue '{cls.queue_name}' deleted from LocalStack.")
        except Exception as e:
            print(f"Error deleting queue '{cls.queue_name}': {e}")

        try:
            cls.test_ssm_client.delete_parameter(Name="/microservice1/token")
            print("SSM parameter deleted from LocalStack.")
        except Exception as e:
            print(f"Error deleting SSM parameter: {e}")

        # Restore original logging level if it was changed
        if hasattr(producer_app, 'logging') and hasattr(cls,
                                                        '_original_app_logging_level') and cls._original_app_logging_level is not None:
            producer_app.logging.getLogger().setLevel(cls._original_app_logging_level)
        print("--- Producer Integration Teardown Complete ---")

    def setUp(self):
        """
        Runs before each individual test method.
        Purges the SQS queue to ensure test isolation.
        """
        print(f"\nRunning test: {self._testMethodName}")
        # Clear the queue before each test to ensure no lingering messages from previous tests
        self.test_sqs_client.purge_queue(QueueUrl=self.queue_url)
        print("SQS queue purged for current test.")

        # Access the Flask app instance from the imported producer_app module
        self.producer_app_instance = producer_app.app

    def test_send_message_integration_success(self):
        """
        Tests that the Producer successfully sends a message to LocalStack SQS
        when interacting via its Flask API.
        """
        print("Running Producer integration test: send_message_integration_success...")

        test_message_data = {
            "email_subject": f"Integration Test Success - {datetime.now(UTC).isoformat()}",
            "email_sender": "producer-e2e@example.com",
            "email_timestamp": int(datetime.now(UTC).timestamp()),
            "email_content": "This is a message sent through the Producer API for integration testing."
        }

        request_payload = {
            "token": TEST_AUTH_TOKEN,  # Use the token stored in LocalStack SSM
            "data": test_message_data
        }

        # Use Flask's test client to simulate an API call to your Producer
        response = self.producer_app_instance.test_client().post('/message', json=request_payload)

        # Assert the API response from your Producer
        self.assertEqual(response.status_code, 200)
        self.assertEqual(json.loads(response.data), {"status": "Message sent to SQS"})

        # --- Verification: Check if the message actually arrived in LocalStack SQS ---
        messages_received = []
        # LocalStack SQS might have a slight delay, so poll a few times
        for _ in range(5):  # Try up to 5 times
            sqs_response = self.test_sqs_client.receive_message(
                QueueUrl=self.queue_url,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=1  # Short poll for faster test execution
            )
            messages = sqs_response.get('Messages', [])
            if messages:
                messages_received.extend(messages)
                break  # Message found, stop polling
            print("No messages received yet in SQS, waiting...")

        self.assertEqual(len(messages_received), 1, "Expected exactly one message in the queue")
        received_body = json.loads(messages_received[0]['Body'])

        # Verify the content of the received message
        self.assertEqual(received_body['email_sender'], test_message_data['email_sender'])
        self.assertIn("Integration Test Success", received_body['email_subject'])
        self.assertEqual(received_body['email_content'], test_message_data['email_content'])
        print("Producer integration test PASSED: Message sent via API and verified in SQS.")

        # Clean up the message from the queue after verification
        self.test_sqs_client.delete_message(
            QueueUrl=self.queue_url,
            ReceiptHandle=messages_received[0]['ReceiptHandle']
        )

    def test_send_message_integration_unauthorized(self):
        """
        Tests unauthorized access to Producer API with a wrong token.
        """
        print("Running Producer integration test: unauthorized access...")
        request_payload = {
            "token": "wrong_token",  # Intentionally use a wrong token
            "data": {"email_subject": "Unauthorized Test", "email_timestamp": 1234567890}
        }
        response = self.producer_app_instance.test_client().post('/message', json=request_payload)
        self.assertEqual(response.status_code, 401)
        self.assertEqual(json.loads(response.data), {"error": "Unauthorized"})

    def test_send_message_integration_invalid_format(self):
        """
        Tests invalid request format to Producer API (missing data/token).
        """
        print("Running Producer integration test: invalid format...")
        response = self.producer_app_instance.test_client().post('/message', json={})  # Empty payload
        self.assertEqual(response.status_code, 400)
        self.assertEqual(json.loads(response.data), {"error": "Invalid request format"})


if __name__ == '__main__':
    unittest.main()