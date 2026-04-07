import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class CliDoctorTests(unittest.TestCase):
    def test_pack_push_is_rejected_with_migration_error(self):
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)

            completed = subprocess.run(
                [str(ROOT / "pack"), "push"],
                cwd=repo,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("pack push was removed; use pack send", completed.stdout + completed.stderr)

    def test_unpack_pull_is_rejected_with_migration_error(self):
        with tempfile.TemporaryDirectory() as td:
            completed = subprocess.run(
                [str(ROOT / "unpack"), "pull"],
                cwd=td,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("unpack pull was removed; use unpack take", completed.stdout + completed.stderr)

    def test_pack_update_remote_flag_is_rejected_with_migration_error(self):
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)

            completed = subprocess.run(
                [str(ROOT / "pack"), "--update-remote", "doctor"],
                cwd=repo,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("--update-remote was removed; use --update", completed.stdout + completed.stderr)

    def test_pack_update_remote_equals_form_is_rejected_with_migration_error(self):
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)

            completed = subprocess.run(
                [str(ROOT / "pack"), "--update-remote=1", "doctor"],
                cwd=repo,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("--update-remote was removed; use --update", completed.stdout + completed.stderr)

    def test_pack_recent_days_flag_is_rejected_with_migration_error(self):
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)

            completed = subprocess.run(
                [str(ROOT / "pack"), "--recent-days", "7", "doctor"],
                cwd=repo,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("--recent-days was removed; use --update N", completed.stdout + completed.stderr)

    def test_pack_send_rejects_pack_only_update_flag_in_send_zone(self):
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)

            completed = subprocess.run(
                [str(ROOT / "pack"), "send", "--update", "7", "doctor"],
                cwd=repo,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("--update is only valid for 'pack'", completed.stdout + completed.stderr)

    def test_pack_setup_rejects_runtime_flags(self):
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)

            completed = subprocess.run(
                [str(ROOT / "pack"), "--update", "7", "setup"],
                cwd=repo,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("setup does not accept runtime options", completed.stdout + completed.stderr)

    def test_pack_doctor_rejects_invalid_update_value(self):
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)

            completed = subprocess.run(
                [str(ROOT / "pack"), "--update", "0", "doctor"],
                cwd=repo,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("update must be -1 or a positive integer", completed.stdout + completed.stderr)

    def test_unpack_doctor_rejects_invalid_boolean_flag(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = pathlib.Path(td) / "conf.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [unpack]
                    pack_dir = "/tmp/packs"
                    pack_prefix = "syncpack"
                    peer = "sync"
                    ff_only = "wat"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [str(ROOT / "unpack"), "doctor"],
                cwd=td,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        combined = completed.stdout + completed.stderr
        self.assertIn("--ff-only must be 0|1", combined)

    def test_pack_doctor_honors_output_dir_cli_override(self):
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td) / "repo"
            pack_dir = pathlib.Path(td) / "packs"
            repo.mkdir()
            pack_dir.mkdir()

            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Codex"], cwd=repo, check=True)
            subprocess.run(
                ["git", "config", "user.email", "codex@example.com"],
                cwd=repo,
                check=True,
            )
            (repo / "README.md").write_text("hello\n", encoding="utf-8")
            subprocess.run(["git", "add", "README.md"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=repo, check=True)

            (repo / "conf.toml").write_text(
                textwrap.dedent(
                    f"""
                    [pack]
                    output_dir = "{(pathlib.Path(td) / 'ignored-out').as_posix()}"
                    pack_prefix = "syncpack"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [str(ROOT / "pack"), "--output-dir", str(pack_dir), "doctor"],
                cwd=repo,
                text=True,
                capture_output=True,
            )

        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)

    def test_pack_send_doctor_cli_proxy_override_replaces_config_proxy_family(self):
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td) / "repo"
            repo.mkdir()

            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Codex"], cwd=repo, check=True)
            subprocess.run(
                ["git", "config", "user.email", "codex@example.com"],
                cwd=repo,
                check=True,
            )
            (repo / "README.md").write_text("hello\n", encoding="utf-8")
            subprocess.run(["git", "add", "README.md"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=repo, check=True)

            (repo / "conf.toml").write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "/tmp/out"
                    pack_prefix = "syncpack"

                    [pack.send.telegram]
                    to = "@target"

                    [telegram.common]
                    api_id = 1
                    api_hash = "hash"
                    session = "sess"

                    [telegram.common.proxy.mtproto]
                    host = "old.example"
                    port = 443
                    secret = "abababababababababababababababab"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    str(ROOT / "pack"),
                    "send",
                    "doctor",
                    "--proxy-type",
                    "http",
                    "--http-host",
                    "proxy.example.com",
                    "--http-port",
                    "8080",
                ],
                cwd=repo,
                text=True,
                capture_output=True,
            )

        combined = completed.stdout + completed.stderr
        self.assertNotIn(
            "telegram_socks5_* and telegram_mtproto_* keys are not allowed when telegram_proxy_type=http",
            combined,
        )

    def test_pack_send_doctor_rejects_invalid_pack_config_before_telegram(self):
        with tempfile.TemporaryDirectory() as td:
            repo = pathlib.Path(td) / "repo"
            repo.mkdir()

            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Codex"], cwd=repo, check=True)
            subprocess.run(
                ["git", "config", "user.email", "codex@example.com"],
                cwd=repo,
                check=True,
            )
            (repo / "README.md").write_text("hello\n", encoding="utf-8")
            subprocess.run(["git", "add", "README.md"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=repo, check=True)

            (repo / "conf.toml").write_text(
                textwrap.dedent(
                    f"""
                    [pack]
                    output_dir = "{repo.as_posix()}"
                    pack_prefix = "syncpack"

                    [pack.send.telegram]
                    to = "@target"

                    [telegram.common]
                    api_id = 1
                    api_hash = "hash"
                    session = "sess"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [str(ROOT / "pack"), "send", "doctor"],
                cwd=repo,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("Refusing to write packs inside the repository", completed.stdout + completed.stderr)

    def test_unpack_take_doctor_cli_proxy_override_replaces_config_proxy_family(self):
        with tempfile.TemporaryDirectory() as td:
            workdir = pathlib.Path(td)
            (workdir / "conf.toml").write_text(
                textwrap.dedent(
                    """
                    [unpack]
                    pack_dir = "/tmp/packs"
                    pack_prefix = "syncpack"
                    peer = "sync"

                    [unpack.take.telegram]
                    from = "@source"

                    [telegram.common]
                    api_id = 1
                    api_hash = "hash"
                    session = "sess"

                    [telegram.common.proxy.mtproto]
                    host = "old.example"
                    port = 443
                    secret = "abababababababababababababababab"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    str(ROOT / "unpack"),
                    "take",
                    "doctor",
                    "--proxy-type",
                    "http",
                    "--http-host",
                    "proxy.example.com",
                    "--http-port",
                    "8080",
                ],
                cwd=workdir,
                text=True,
                capture_output=True,
            )

        combined = completed.stdout + completed.stderr
        self.assertNotIn(
            "telegram_socks5_* and telegram_mtproto_* keys are not allowed when telegram_proxy_type=http",
            combined,
        )

    def test_unpack_take_doctor_rejects_invalid_unpack_config_before_telegram(self):
        with tempfile.TemporaryDirectory() as td:
            workdir = pathlib.Path(td)
            (workdir / "conf.toml").write_text(
                textwrap.dedent(
                    """
                    [unpack]
                    pack_dir = "/tmp/packs"
                    pack_prefix = "syncpack"
                    peer = "sync"
                    ff_only = "wat"

                    [unpack.take.telegram]
                    from = "@source"

                    [telegram.common]
                    api_id = 1
                    api_hash = "hash"
                    session = "sess"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [str(ROOT / "unpack"), "take", "doctor"],
                cwd=workdir,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("--ff-only must be 0|1", completed.stdout + completed.stderr)
