import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


def load_root_config_module():
    module_path = pathlib.Path(__file__).resolve().parents[1] / "src" / "root_config.py"
    spec = importlib.util.spec_from_file_location("root_config", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class RootTomlConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root_config = load_root_config_module()

    def test_pack_commands_use_git_top_level_as_config_root(self):
        root = self.root_config.resolve_config_root(
            command="pack",
            cwd="/tmp/repo/subdir",
            git_top_level="/tmp/repo",
            tool_root="/opt/sync_tool",
        )
        self.assertEqual("/opt/sync_tool", root)

    def test_unpack_outside_repo_uses_cwd_as_config_root(self):
        root = self.root_config.resolve_config_root(
            command="unpack",
            cwd="/tmp/outside",
            git_top_level="",
            tool_root="/opt/sync_tool",
        )
        self.assertEqual("/opt/sync_tool", root)

    def test_unpack_inside_repo_uses_git_top_level_as_config_root(self):
        root = self.root_config.resolve_config_root(
            command="unpack-take",
            cwd="/tmp/repo/subdir",
            git_top_level="/tmp/repo",
            tool_root="/opt/sync_tool",
        )
        self.assertEqual("/opt/sync_tool", root)

    def test_dotted_keys_count_as_existing_table(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = pathlib.Path(td) / "conf.toml"
            config_path.write_text('pack.output_dir = "out"\npack.pack_prefix = "syncpack"\n', encoding="utf-8")

            doc = self.root_config.load_conf_toml(str(config_path))

        self.assertTrue(self.root_config.table_exists(doc, "pack"))
        self.assertEqual("out", doc["pack"]["output_dir"])

    def test_inline_table_counts_as_existing_table(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = pathlib.Path(td) / "conf.toml"
            config_path.write_text('pack = { output_dir = "out", pack_prefix = "syncpack" }\n', encoding="utf-8")

            doc = self.root_config.load_conf_toml(str(config_path))

        self.assertTrue(self.root_config.table_exists(doc, "pack"))
        self.assertEqual("syncpack", doc["pack"]["pack_prefix"])

    def test_extract_pack_section_reads_direct_keys(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = pathlib.Path(td) / "conf.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "syncpacks"
                    pack_prefix = "syncpack"
                    update = -1

                    [pack.send.telegram]
                    to = "@sync-channel"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            doc = self.root_config.load_conf_toml(str(config_path))
            pack = self.root_config.extract_table(doc, "pack")
            send = self.root_config.extract_table(doc, "pack.send.telegram")

        self.assertEqual("syncpacks", pack["output_dir"])
        self.assertEqual("syncpack", pack["pack_prefix"])
        self.assertEqual(-1, pack["update"])
        self.assertEqual("@sync-channel", send["to"])

    def test_export_config_flattens_sections_and_proxy(self):
        document = {
            "pack": {"output_dir": "syncpacks", "update": -1, "send": {"telegram": {"to": "@sync"}}},
            "unpack": {"peer": "sync", "take": {"telegram": {"from": "@source"}}},
            "telegram": {"common": {"api_id": 123, "proxy": {"http": {"host": "proxy.example.com", "port": 8080}}}},
        }

        exported = self.root_config.export_config(document)

        self.assertEqual("syncpacks", exported["CFG_PACK_OUTPUT_DIR"])
        self.assertEqual("-1", exported["CFG_PACK_UPDATE"])
        self.assertEqual("@sync", exported["CFG_PACK_SEND_TELEGRAM_TO"])
        self.assertEqual("@source", exported["CFG_UNPACK_TAKE_TELEGRAM_FROM"])
        self.assertEqual("123", exported["CFG_TELEGRAM_COMMON_API_ID"])
        self.assertEqual("http", exported["CFG_TELEGRAM_PROXY_MODE"])
        self.assertEqual("proxy.example.com", exported["CFG_TELEGRAM_PROXY_HOST"])
        self.assertEqual("8080", exported["CFG_TELEGRAM_PROXY_PORT"])

    def test_build_export_rejects_removed_pack_update_remote_key(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = pathlib.Path(td) / "conf.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "syncpacks"
                    pack_prefix = "syncpack"
                    update_remote = true
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                ValueError,
                r"\[pack\]\.update_remote is no longer supported; use \[pack\]\.update",
            ):
                self.root_config.build_export("pack", td, td, td)

    def test_build_export_rejects_removed_pack_push_section(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = pathlib.Path(td) / "conf.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "syncpacks"
                    pack_prefix = "syncpack"

                    [pack.push.telegram]
                    to = "@sync-target"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                ValueError,
                r"\[pack\.push\.telegram\] is no longer supported; use \[pack\.send\.telegram\]",
            ):
                self.root_config.build_export("pack", td, td, td)

    def test_build_export_rejects_removed_global_fields(self):
        cases = [
            (
                "pack_machine_name",
                """
                [pack]
                output_dir = "syncpacks"
                pack_prefix = "syncpack"
                machine_name = "box"
                """,
                r"\[pack\]\.machine_name is no longer supported; use \[telegram\.common\]\.local_machine_name",
            ),
            (
                "unpack_project_name",
                """
                [unpack]
                pack_dir = "syncpacks"
                pack_prefix = "syncpack"
                project_name = "demo"
                peer = "sync"
                """,
                r"\[unpack\]\.project_name is no longer supported; use --project-name for outside-repo unpack take bootstrap",
            ),
            (
                "telegram_session_string",
                """
                [telegram.common]
                api_id = 1
                api_hash = "hash"
                session = "sess"
                session_string = "abc"
                """,
                r"\[telegram\.common\]\.session_string is no longer supported; use \[telegram\.common\]\.session",
            ),
            (
                "telegram_phone",
                """
                [telegram.common]
                api_id = 1
                api_hash = "hash"
                session = "sess"
                phone = "+70000000000"
                """,
                r"\[telegram\.common\]\.phone is no longer supported",
            ),
            (
                "telegram_caption",
                """
                [telegram.common]
                api_id = 1
                api_hash = "hash"
                session = "sess"
                caption = "text"
                """,
                r"\[telegram\.common\]\.caption is no longer supported",
            ),
            (
                "telegram_python_min",
                """
                [telegram.common]
                api_id = 1
                api_hash = "hash"
                session = "sess"
                python_min = "3.8"
                """,
                r"\[telegram\.common\]\.python_min is no longer supported",
            ),
        ]

        for name, config_text, pattern in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as td:
                config_path = pathlib.Path(td) / "conf.toml"
                config_path.write_text(textwrap.dedent(config_text).strip() + "\n", encoding="utf-8")

                with self.assertRaisesRegex(ValueError, pattern):
                    self.root_config.build_export("pack", td, td, td)

    def test_export_config_rejects_multiple_proxy_tables(self):
        document = {
            "telegram": {
                "common": {
                    "proxy": {
                        "http": {"host": "http.example.com", "port": 8080},
                        "mtproto": {"host": "mt.example.com", "port": 443, "secret": "ab" * 16},
                    }
                }
            }
        }

        with self.assertRaisesRegex(ValueError, "Only one \\[telegram\\.common\\.proxy\\.\\*\\] table is allowed"):
            self.root_config.export_config(document)

    def test_cli_export_prints_shell_assignments(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = pathlib.Path(td) / "conf.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "syncpacks"

                    [telegram.common]
                    api_id = 123

                    [telegram.common.proxy.socks5]
                    host = "127.0.0.1"
                    port = 1080
                    username = "alice"
                    password = "secret"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            module_path = pathlib.Path(__file__).resolve().parents[1] / "src" / "root_config.py"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(module_path),
                    "export",
                    "--command",
                    "pack",
                    "--cwd",
                    td,
                    "--git-top-level",
                    td,
                    "--tool-root",
                    td,
                ],
                check=True,
                capture_output=True,
                text=True,
            )

        output = completed.stdout
        self.assertIn("CFG_HAS_CONF_TOML=1", output)
        self.assertIn("CFG_PACK_OUTPUT_DIR=syncpacks", output)
        self.assertIn("CFG_TELEGRAM_COMMON_API_ID=123", output)
        self.assertIn("CFG_TELEGRAM_PROXY_MODE=socks5", output)
        self.assertIn("CFG_TELEGRAM_PROXY_USERNAME=alice", output)

    def test_update_table_file_preserves_other_sections(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = pathlib.Path(td) / "conf.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "syncpacks"

                    [telegram.common]
                    api_id = 123
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            self.root_config.update_table_file(
                str(config_path),
                "pack.send.telegram",
                {"to": "@sync-target"},
            )

            document = self.root_config.load_conf_toml(str(config_path))

        self.assertEqual("syncpacks", document["pack"]["output_dir"])
        self.assertEqual(123, document["telegram"]["common"]["api_id"])
        self.assertEqual("@sync-target", document["pack"]["send"]["telegram"]["to"])

    def test_update_parent_table_preserves_nested_child_tables(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = pathlib.Path(td) / "conf.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "syncpacks"
                    pack_prefix = "syncpack"

                    [pack.send.telegram]
                    to = "@sync-target"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            self.root_config.update_table_file(
                str(config_path),
                "pack",
                {
                    "output_dir": "other-syncpacks",
                    "pack_prefix": "syncpack",
                    "update": -1,
                },
            )

            document = self.root_config.load_conf_toml(str(config_path))

        self.assertEqual("other-syncpacks", document["pack"]["output_dir"])
        self.assertEqual("@sync-target", document["pack"]["send"]["telegram"]["to"])

    def test_build_export_uses_tool_root_conf_for_pack_scope(self):
        with tempfile.TemporaryDirectory() as td:
            tool_root = pathlib.Path(td) / "tool"
            repo_root = pathlib.Path(td) / "repo"
            tool_root.mkdir()
            repo_root.mkdir()

            (tool_root / "conf.toml").write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "global-syncpacks"
                    pack_prefix = "syncpack"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )
            (repo_root / "conf.toml").write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "repo-syncpacks"
                    pack_prefix = "syncpack"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            exported = self.root_config.build_export(
                "pack",
                str(repo_root),
                str(repo_root),
                str(tool_root),
            )

        self.assertEqual(str(tool_root), exported["CFG_CONFIG_ROOT"])
        self.assertEqual(str(tool_root / "conf.toml"), exported["CFG_CONFIG_FILE"])
        self.assertEqual("global-syncpacks", exported["CFG_PACK_OUTPUT_DIR"])


if __name__ == "__main__":
    unittest.main()
