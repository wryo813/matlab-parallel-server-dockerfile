# Copyright 2023 The MathWorks, Inc.

"""Test runner for the productsTest.m test file"""

from utils import dockertool, helpers
from pathlib import Path
import unittest


def _license_file_available():
    """secret MATLAB_LICENSE_FILE が未設定で license.lic が空のときは False を返す。"""
    try:
        helpers.get_license_filepath()
    except (ValueError, TypeError):
        return False
    return True


_SKIP_NO_LICENSE_REASON = (
    "License file is empty or missing (secret MATLAB_LICENSE_FILE is not set); "
    "skipping test that needs a MATLAB license"
)


class TestInstalledProducts(unittest.TestCase):
    """A test runner class for the productsTest.m test file"""

    def run_matlab_test(self, m_filename):
        m_filepath = str(Path(__file__).parent.resolve() / m_filename)

        runner = dockertool.MATLABTestRunner(m_filepath)

        exit_code, error, logs = runner.run()
        self.assertEqual(exit_code, 0, logs)
        self.assertIsNone(error, logs)

    @unittest.skipUnless(_license_file_available(), _SKIP_NO_LICENSE_REASON)
    def test_installed_products(self):
        m_filename = "productsTest.m"
        self.run_matlab_test(m_filename)

if __name__ == "__main__":
    unittest.main()
