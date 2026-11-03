# Copyright 2023 The MathWorks, Inc.

"""Test runner for the productsTest.m test file

MATLAB のライセンスは次のどちらかで与える。どちらも無いときはテストをスキップする。
- batch licensing token: 環境変数 BATCH_TOKEN と、ランナー上の matlab-batch 実行ファイルのパス
  MATLAB_BATCH_PATH (ワークフローがダウンロードする)。matlab-batch をコンテナにマウントして実行する。
- ライセンスファイル: 環境変数 LICENSE_FILE_PATH (secret MATLAB_LICENSE_FILE から生成)。upstream と同じ方式。
"""

from utils import dockertool, helpers
from pathlib import Path
import docker
import os
import requests
import unittest

"""matlab-batch をマウントするコンテナ内のパス (PATH 上にあり、matlab は同じ PATH から見つかる)"""
MATLAB_BATCH_DST = "/usr/local/bin/matlab-batch"

"""製品数が多くライセンス確認を挟むため、upstream の 300 秒より長めに待つ"""
MATLAB_BATCH_TIMEOUT = 900


def _license_file_available():
    """secret MATLAB_LICENSE_FILE が未設定で license.lic が空のときは False を返す。"""
    try:
        helpers.get_license_filepath()
    except (ValueError, TypeError):
        return False
    return True


def _batch_token_available():
    """secret MATLAB_BATCH_TOKEN と matlab-batch 実行ファイルが揃っているときだけ True を返す。"""
    token = os.environ.get("BATCH_TOKEN") or ""
    matlab_batch = os.environ.get("MATLAB_BATCH_PATH") or ""
    return token.strip() != "" and os.path.isfile(matlab_batch)


def _run_with_batch_token(statement, mounts=()):
    """matlab-batch と batch token で MATLAB の statement を実行し、(終了コード, ログ) を返す。"""
    client = docker.from_env()
    all_mounts = [
        docker.types.Mount(
            target=MATLAB_BATCH_DST,
            source=os.path.abspath(os.environ["MATLAB_BATCH_PATH"]),
            read_only=True,
            type="bind",
        ),
        *mounts,
    ]
    container = client.containers.run(
        image=helpers.get_image_name(),
        detach=True,
        entrypoint=[MATLAB_BATCH_DST],
        command=[statement],
        environment={"MLM_LICENSE_TOKEN": os.environ["BATCH_TOKEN"].strip()},
        mounts=all_mounts,
    )
    try:
        result = container.wait(timeout=MATLAB_BATCH_TIMEOUT)
        logs = container.logs().strip().decode("utf-8")
        return result.get("StatusCode"), logs
    except requests.exceptions.ReadTimeout:
        raise TimeoutError(
            f"matlab-batch took longer than {MATLAB_BATCH_TIMEOUT} s to complete"
        )
    finally:
        container.stop()
        container.remove()
        client.close()


_SKIP_NO_LICENSE_REASON = (
    "Neither a batch licensing token (secret MATLAB_BATCH_TOKEN) nor a license file "
    "(secret MATLAB_LICENSE_FILE) is available; skipping test that needs a MATLAB license"
)


class TestInstalledProducts(unittest.TestCase):
    """A test runner class for the productsTest.m test file"""

    def run_matlab_test(self, m_filename):
        m_filepath = str(Path(__file__).parent.resolve() / m_filename)

        if _batch_token_available():
            m_dstpath = "/tmp/" + m_filename
            mount = docker.types.Mount(
                target=m_dstpath, source=m_filepath, read_only=True, type="bind"
            )
            exit_code, logs = _run_with_batch_token(
                f"assertSuccess(runtests('{m_dstpath}'))", mounts=[mount]
            )
            self.assertEqual(exit_code, 0, logs)
            return

        runner = dockertool.MATLABTestRunner(m_filepath)

        exit_code, error, logs = runner.run()
        self.assertEqual(exit_code, 0, logs)
        self.assertIsNone(error, logs)

    @unittest.skipUnless(_batch_token_available(), _SKIP_NO_LICENSE_REASON)
    def test_matlab_batch_runs(self):
        """Test that MATLAB starts with the batch licensing token and reports the expected release."""
        exit_code, logs = _run_with_batch_token("disp(version('-release'))")
        self.assertEqual(exit_code, 0, logs)
        expected_release = helpers.get_release().strip().lstrip("Rr")
        self.assertRegex(logs, expected_release)

    @unittest.skipUnless(
        _batch_token_available() or _license_file_available(), _SKIP_NO_LICENSE_REASON
    )
    def test_installed_products(self):
        m_filename = "productsTest.m"
        self.run_matlab_test(m_filename)

if __name__ == "__main__":
    unittest.main()
