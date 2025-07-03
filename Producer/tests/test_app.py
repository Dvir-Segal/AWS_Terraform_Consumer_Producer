import unittest
from unittest.mock import patch
import os
import sys
from flask import json
from moto import mock_aws

# Add the 'Producer' directory to the Python path for importing 'app'
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# Set environment variables required by the application
os.environ["AWS_REGION"] = "us-west-1"
os.environ["SQS_QUEUE_URL"] = "http://mock-sqs-url/123456789012/test-queue"


# --- Unit Test Class ---

# Apply mock_aws decorator to the entire test class for all methods to mock AWS services
@mock_aws
class TestProducerApp(unittest.TestCase):

    # Use setUpClass to patch things *before* the module is imported in individual tests
    # This runs once for the entire test class.
    @classmethod
    def setUpClass(cls):
        super().setUpClass()  # Call parent's setUpClass if it exists

        # --- CRITICAL PATCHING BEFORE APP IMPORT ---
        # Mock the ssm client that 'app.py' will try to import and use.
        # We need to mock the *boto3* module's client method.
        # This patch needs to be active when app.py runs its module-level code.

        # Create a mock for the ssm client
        cls.mock_ssm_client = unittest.mock.Mock()
        cls.mock_ssm_client.get_parameter.return_value = {
            "Parameter": {"Value": "$DJ!S4K#5ke3RkY=", "Type": "SecureString", "Version": 1}
        }

        # Patch boto3.client directly, specifically for 'ssm'
        # We target the module where 'boto3.client' is imported from.
        # If app.py does 'import boto3', then patch 'boto3.client'.
        # If app.py does 'from boto3 import client', then patch 'app.client'.
        # Assuming app.py does 'import boto3', and then 'boto3.client('ssm', ...)'.
        cls.boto3_patcher = patch('boto3.client', return_value=cls.mock_ssm_client)
        cls.boto3_patcher.start()

        # Now, import the app. It will use the mocked boto3.client.
        # This import is done once for the class.
        from app import app as flask_app_module, SQS_QUEUE_URL, sqs
        cls.app_module = flask_app_module  # Store the imported app module
        cls.SQS_QUEUE_URL = SQS_QUEUE_URL
        cls.sqs_client_original = sqs  # Store original SQS client for later patching

        # It's good practice to stop patches started in setUpClass in tearDownClass
        # but we'll do it in setUp/tearDown for SQS client to reset per test.

    @classmethod
    def tearDownClass(cls):
        # Stop the boto3.client patcher that was started in setUpClass
        cls.boto3_patcher.stop()
        # Clean up imported app module from sys.modules
        if 'app' in sys.modules:
            del sys.modules['app']
        super().tearDownClass()

    # setUp is run before each test method
    def setUp(self):
        # Set TESTING mode for the Flask app instance
        self.app = self.app_module
        self.app.config["TESTING"] = True

        # Create a new Flask test client for each test
        self.client = self.app.test_client()

        # Patch SQS send_message for each test
        self.sqs_send_message_patcher = patch.object(self.sqs_client_original, 'send_message')
        self.mock_sqs_send_message = self.sqs_send_message_patcher.start()

    # tearDown is run after each test method to clean up patches
    def tearDown(self):
        self.mock_sqs_send_message.stop()

    # --- Test Methods (remain largely the same) ---

    def test_health_check(self):
        """Tests the health check endpoint."""
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data.decode("utf-8"), "Microservice 1 OK")

    def test_receive_message_success(self):
        """Tests successful message reception and SQS dispatch."""
        payload = {
            "data": {
                "email_subject": "Test Subject",
                "email_sender": "test@example.com",
                "email_timestamp": 1672531200,
                "email_content": "This is a test message."
            },
            "token": "$DJ!S4K#5ke3RkY="
        }
        response = self.client.post("/message", json=payload)

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {"status": "Message sent to SQS"})
        self.mock_sqs_send_message.assert_called_once_with(
            QueueUrl=self.SQS_QUEUE_URL,
            # --- התיקון כאן: הוסף sort_keys=True ---
            MessageBody=json.dumps(payload["data"], sort_keys=True)
        )
        # Assert that get_parameter was called on our mock ssm client
        self.mock_ssm_client.get_parameter.assert_called_once_with(Name="/microservice1/token", WithDecryption=True)

    def test_receive_message_invalid_format(self):
        """Tests handling of invalid request format."""
        response = self.client.post("/message", json={"some_other_key": "value"})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json, {"error": "Invalid request format"})

    def test_receive_message_unauthorized(self):
        """Tests handling of incorrect token."""
        payload = {
            "data": {
                "email_subject": "Test",
                "email_sender": "test@example.com",
                "email_timestamp": 1672531200,
                "email_content": "Test content"
            },
            "token": "INCORRECT_TOKEN_123"
        }
        response = self.client.post("/message", json=payload)
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json, {"error": "Unauthorized"})

    def test_receive_message_missing_timestamp(self):
        """Tests handling of missing 'email_timestamp'."""
        payload = {
            "data": {
                "email_subject": "Test",
                "email_sender": "test@example.com",
                "email_content": "Test content"
            },
            "token": "$DJ!S4K#5ke3RkY="
        }
        response = self.client.post("/message", json=payload)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json, {"error": "Missing email_timestamp"})

    def test_receive_message_invalid_timestamp(self):
        """Tests handling of invalid 'email_timestamp' format."""
        payload = {
            "data": {
                "email_subject": "Test",
                "email_sender": "test@example.com",
                "email_timestamp": "not_an_int",
                "email_content": "Test content"
            },
            "token": "$DJ!S4K#5ke3RkY="
        }
        response = self.client.post("/message", json=payload)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json, {"error": "Invalid email_timestamp"})

    def test_receive_message_sqs_error(self):
        """Tests handling of SQS send_message error."""
        self.mock_sqs_send_message.side_effect = Exception("SQS is down!")

        payload = {
            "data": {
                "email_subject": "Test",
                "email_sender": "test@example.com",
                "email_timestamp": 1672531200,
                "email_content": "Test content"
            },
            "token": "$DJ!S4K#5ke3RkY="
        }
        response = self.client.post("/message", json=payload)
        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.json, {"error": "SQS is down!"})
        self.mock_sqs_send_message.assert_called_once()


if __name__ == '__main__':
    unittest.main()