import unittest
from unittest.mock import patch, MagicMock
import os
import sys
import json
from datetime import datetime

# Add the 'Consumer' directory to the Python path for importing 'app'
# This is crucial for the test file to find and import the 'app' module.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# Set environment variables required by the application for testing
# These mimic the environment variables that the actual app.py would expect.
os.environ["SQS_QUEUE_URL"] = "http://mock-sqs-url/123456789012/consumer-test-queue"
os.environ["S3_BUCKET_NAME"] = "consumer-test-bucket-123"
os.environ["AWS_REGION"] = "us-west-1"


# --- Unit Test Class ---

class TestConsumerApp(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        """
        Set up class-level mocks and imports that are shared across all test methods.
        This runs once before any test in this class.
        """
        super().setUpClass()
        cls.mock_sqs_client = MagicMock()
        cls.mock_s3_client = MagicMock()
        cls.boto3_client_patcher = patch('boto3.client', side_effect=lambda service_name, **kwargs: {
            'sqs': cls.mock_sqs_client,
            's3': cls.mock_s3_client
        }.get(service_name))
        cls.boto3_client_patcher.start()

        # Ensure 'app' module is reloaded:
        # This is vital to ensure that app.py initializes its global variables (sqs, s3)
        # with our *mocked* boto3 clients, not the real ones. If app was imported before
        # boto3.client was patched, it would use real clients.
        if 'app' in sys.modules:
            del sys.modules['app']

        # Import the app module: After patching boto3.client, importing app.py
        # will cause its global 'sqs' and 's3' variables to be assigned our mock clients.
        import app as app_module
        cls.app_module = app_module

        # Store references to app's global variables for assertions in tests.
        cls.SQS_QUEUE_URL = app_module.SQS_QUEUE_URL
        cls.S3_BUCKET_NAME = app_module.S3_BUCKET_NAME

    @classmethod
    def tearDownClass(cls):
        """
        Clean up class-level mocks after all tests in the class have finished.
        This runs once after all tests.
        """
        # Stop the boto3 client patcher to restore original behavior.
        cls.boto3_client_patcher.stop()

        # Clean up the app module from sys.modules to ensure a clean state
        # for any subsequent test runs or other parts of the application.
        if 'app' in sys.modules:
            del sys.modules['app']
        super().tearDownClass()

    def setUp(self):
        """
        Set up common mocks and reset their states before each test method runs.
        This ensures each test starts with a clean and predictable environment.
        """
        # Reset mock call history: Important for `assert_called_once_with`, `assert_not_called`, etc.
        self.mock_sqs_client.reset_mock()
        self.mock_s3_client.reset_mock()

        # Set default behaviors for the mock clients:
        # Ensure s3.put_object has no side effect by default (e.g., no exceptions from previous tests).
        self.mock_s3_client.put_object.side_effect = None
        # Default SQS receive_message to return no messages unless explicitly set otherwise in a test.
        self.mock_sqs_client.receive_message.return_value = {"Messages": []}
        # Default SQS delete_message to succeed.
        self.mock_sqs_client.delete_message.return_value = {}

        # Patch time.sleep: This prevents actual delays during tests, making them run fast.
        # It's patched per test method as it's a standard library function.
        self.time_sleep_patcher = patch('time.sleep')
        self.mock_time_sleep = self.time_sleep_patcher.start()

    def tearDown(self):
        """
        Clean up mocks started in setUp after each test method runs.
        """
        # Stop the time.sleep patcher.
        self.time_sleep_patcher.stop()

    # --- Test Cases for process_message function ---

    def test_process_message_success(self):
        """
        Tests the successful processing and S3 upload of a valid message.
        Verifies that:
        1. S3 put_object is called exactly once with the correct bucket, key format, and body.
        2. The S3 key incorporates the correct mocked timestamp.
        """
        message_body = {
            "email_subject": "Hello",
            "email_sender": "test@example.com",
            "email_timestamp": 1678886400,
            "email_content": "This is a test message."
        }

        # Patch app.datetime to control the current time, ensuring predictable S3 keys.
        with patch('app.datetime') as mock_datetime:
            mock_datetime.utcnow.return_value = datetime(2023, 3, 15, 10, 0, 0)
            # These side_effects ensure that strftime and fromtimestamp on the mocked datetime
            # object behave as expected, returning predictable strings/objects.
            mock_datetime.strftime.side_effect = lambda dt, fmt: datetime(2023, 3, 15, 10, 0, 0).strftime(fmt)
            mock_datetime.fromtimestamp.side_effect = lambda ts: datetime.fromtimestamp(ts)

            # Call the function under test directly from the imported app module.
            self.app_module.process_message(message_body)

            # Assertions for S3 interaction
            self.mock_s3_client.put_object.assert_called_once()
            args, kwargs = self.mock_s3_client.put_object.call_args
            self.assertEqual(kwargs['Bucket'], self.S3_BUCKET_NAME)
            self.assertTrue(kwargs['Key'].startswith("messages/message-"))
            self.assertTrue(kwargs['Key'].endswith(".json"))
            self.assertEqual(json.loads(kwargs['Body']), message_body)

    def test_process_message_s3_failure(self):
        """
        Tests error handling within process_message when S3 upload fails.
        Verifies that:
        1. An exception is raised when s3.put_object encounters an error.
        2. s3.put_object is still called once (the attempt that failed).
        """
        # Configure the mock s3 client's put_object method to raise an exception.
        self.mock_s3_client.put_object.side_effect = Exception("S3 upload failed")
        message_body = {"data": "some_data"}

        # Assert that calling process_message raises the expected exception.
        with self.assertRaises(Exception) as cm:
            self.app_module.process_message(message_body)

        self.assertEqual(str(cm.exception), "S3 upload failed")
        # Assert that s3.put_object was called once (the failing attempt).
        self.mock_s3_client.put_object.assert_called_once()

    # --- Test Cases for poll_queue function ---

    def test_poll_queue_no_messages(self):
        """
        Tests poll_queue's behavior when no messages are received from SQS.
        Verifies that:
        1. SQS receive_message is called once with correct parameters.
        2. No S3 upload or SQS message deletion occurs.
        3. The polling loop terminates correctly (due to mocked time.sleep).
        """
        # Configure SQS receive_message mock to return an empty list of messages.
        self.mock_sqs_client.receive_message.return_value = {"Messages": []}
        # Configure time.sleep to immediately raise StopIteration, causing the poll_queue loop to exit after one iteration.
        self.mock_time_sleep.side_effect = [StopIteration]

        # Assert that poll_queue raises StopIteration (as configured by mock_time_sleep).
        with self.assertRaises(StopIteration):
            self.app_module.poll_queue()

        # Assertions for SQS and S3 interactions
        self.mock_sqs_client.receive_message.assert_called_once_with(
            QueueUrl=self.SQS_QUEUE_URL,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=5,
            VisibilityTimeout=30
        )
        self.mock_s3_client.put_object.assert_not_called()
        self.mock_sqs_client.delete_message.assert_not_called()

    def test_poll_queue_with_messages(self):
        """
        Tests poll_queue's behavior when multiple valid messages are received.
        Verifies that:
        1. SQS receive_message is called once.
        2. process_message is called for each received message.
        3. SQS delete_message is called for each processed message.
        """
        # Define mock SQS messages, including their JSON body and receipt handle.
        mock_messages = [
            {"Body": json.dumps({"id": 1, "email_subject": "Msg1"}), "ReceiptHandle": "handle1"},
            {"Body": json.dumps({"id": 2, "email_subject": "Msg2"}), "ReceiptHandle": "handle2"},
        ]
        # Configure SQS receive_message to return these mock messages.
        self.mock_sqs_client.receive_message.return_value = {"Messages": mock_messages}
        # Configure time.sleep to immediately raise StopIteration, exiting the loop after one message batch.
        self.mock_time_sleep.side_effect = [StopIteration]

        # Patch app.process_message to verify it's called correctly without re-testing its internal logic.
        with patch('app.process_message') as mock_process_message:
            # Assert that poll_queue raises StopIteration (as configured by mock_time_sleep).
            with self.assertRaises(StopIteration):
                self.app_module.poll_queue()

            # Assertions for SQS and process_message interactions
            self.mock_sqs_client.receive_message.assert_called_once()
            self.assertEqual(mock_process_message.call_count, 2)  # process_message should be called twice

            # Verify process_message was called with the correct parsed bodies.
            expected_body_1 = json.loads(mock_messages[0]["Body"])
            expected_body_2 = json.loads(mock_messages[1]["Body"])
            mock_process_message.assert_any_call(expected_body_1)
            mock_process_message.assert_any_call(expected_body_2)

            # Assert SQS delete_message was called for each processed message.
            self.assertEqual(self.mock_sqs_client.delete_message.call_count, 2)
            self.mock_sqs_client.delete_message.assert_any_call(QueueUrl=self.SQS_QUEUE_URL, ReceiptHandle="handle1")
            self.mock_sqs_client.delete_message.assert_any_call(QueueUrl=self.SQS_QUEUE_URL, ReceiptHandle="handle2")


if __name__ == '__main__':
    unittest.main()