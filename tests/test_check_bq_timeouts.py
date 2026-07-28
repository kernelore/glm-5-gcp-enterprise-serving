import unittest
from unittest.mock import patch, MagicMock
import sys
import os

# Add scripts directory to module search path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import check_bq

class TestCheckBQTimeouts(unittest.TestCase):
    @patch("subprocess.run")
    def test_run_bq_query_attempt_timeout_capping(self, mock_subprocess_run):
        # Mock bq CLI success
        mock_res = MagicMock()
        mock_res.returncode = 0
        mock_res.stdout = '[{"total_trajectories": 10}]'
        mock_subprocess_run.return_value = mock_res

        # Call with 180s total budget and 30s attempt timeout
        success, data = check_bq.run_bq_query("SELECT count(*) FROM test", "test-project", timeout=180, attempt_timeout=30)
        self.assertTrue(success)
        mock_subprocess_run.assert_called_once()
        _, kwargs = mock_subprocess_run.call_args
        self.assertEqual(kwargs.get("timeout"), 30)

    @patch("subprocess.run")
    def test_run_bq_query_bounded_by_remaining_total_timeout(self, mock_subprocess_run):
        mock_res = MagicMock()
        mock_res.returncode = 0
        mock_res.stdout = '[{"total_trajectories": 10}]'
        mock_subprocess_run.return_value = mock_res

        # Call with 10s remaining total budget and 30s attempt timeout -> should cap at 10s
        success, data = check_bq.run_bq_query("SELECT count(*) FROM test", "test-project", timeout=10, attempt_timeout=30)
        self.assertTrue(success)
        mock_subprocess_run.assert_called_once()
        _, kwargs = mock_subprocess_run.call_args
        self.assertEqual(kwargs.get("timeout"), 10)

if __name__ == "__main__":
    unittest.main()
