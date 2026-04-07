import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class SetupPromptTests(unittest.TestCase):
    def make_tool_copy(self, parent: pathlib.Path) -> pathlib.Path:
        tool_root = parent / "tool"
        tool_root.mkdir()
        shutil.copy2(ROOT / "pack", tool_root / "pack")
        shutil.copy2(ROOT / "unpack", tool_root / "unpack")
        shutil.copytree(ROOT / "src", tool_root / "src")
        return tool_root

    def run_setup(self, command, *, cwd: pathlib.Path, input_text: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["script", "-qec", " ".join(str(part) for part in command), "/dev/null"],
            cwd=cwd,
            input=input_text,
            text=True,
            capture_output=True,
        )

    def test_pack_setup_uses_built_in_defaults_not_existing_config(self):
        with tempfile.TemporaryDirectory() as td:
            temp_root = pathlib.Path(td)
            tool_root = self.make_tool_copy(temp_root)
            (tool_root / "conf.toml").write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "/tmp/custom"
                    pack_prefix = "custom"
                    remote_name = "upstream"
                    update = 9
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            completed = self.run_setup(
                [tool_root / "pack", "setup"],
                cwd=temp_root,
                input_text="\n\n\n\n",
            )

        combined = completed.stdout + completed.stderr
        self.assertEqual(0, completed.returncode, combined)
        self.assertIn("pack.output_dir (where created packs are stored) [~/syncpacks]:", combined)
        self.assertIn("pack.pack_prefix (filename prefix for created archives) [syncpack]:", combined)
        self.assertIn("pack.remote_name (git remote used by update) [origin]:", combined)
        self.assertIn(
            "pack.update (leave empty to disable; -1 updates only local branches; positive integer includes recent remote branches):",
            combined,
        )
        self.assertNotIn("/tmp/custom", combined)
        self.assertNotIn("[custom]", combined)
        self.assertNotIn("[upstream]", combined)

    def test_unpack_setup_prompt_order_matches_spec(self):
        with tempfile.TemporaryDirectory() as td:
            temp_root = pathlib.Path(td)
            tool_root = self.make_tool_copy(temp_root)

            completed = self.run_setup(
                [tool_root / "unpack", "setup"],
                cwd=temp_root,
                input_text="\n\n\n\n\n\n\n",
            )

        combined = completed.stdout + completed.stderr
        self.assertEqual(0, completed.returncode, combined)
        prompts = [
            "unpack.pack_dir (where pack archives are searched or downloaded) [~/syncpacks]:",
            "unpack.pack_prefix (filename prefix expected for incoming archives) [syncpack]:",
            "unpack.peer (remote name used for imported refs) [sync]:",
            "unpack.ff_only (allow only fast-forward branch updates) [true]:",
            "unpack.force_tags (overwrite local tags from incoming pack) [false]:",
            "unpack.prune_remote_refs (remove stale imported remote refs) [true]:",
            "unpack.prune_local_branches (delete unmatched local branches after import) [false]:",
            "unpack.clean_peer_refs (clear refs/remotes/<peer>/* before import) [true]:",
        ]
        last_index = -1
        for prompt in prompts:
            index = combined.find(prompt)
            self.assertNotEqual(-1, index, f"Missing prompt: {prompt}\n{combined}")
            self.assertGreater(index, last_index, f"Prompt out of order: {prompt}\n{combined}")
            last_index = index

    def test_pack_send_setup_rejects_empty_to_without_rewriting_file(self):
        with tempfile.TemporaryDirectory() as td:
            temp_root = pathlib.Path(td)
            tool_root = self.make_tool_copy(temp_root)
            config_path = tool_root / "conf.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [pack]
                    output_dir = "~/syncpacks"
                    pack_prefix = "syncpack"
                    remote_name = "origin"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )
            before = config_path.read_text(encoding="utf-8")

            completed = self.run_setup(
                [tool_root / "pack", "send", "setup"],
                cwd=temp_root,
                input_text="\n",
            )

            after = config_path.read_text(encoding="utf-8")

        combined = completed.stdout + completed.stderr
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("pack.send.telegram.to (Telegram destination chat for sent packs):", combined)
        self.assertIn("pack.send.telegram.to cannot be empty.", combined)
        self.assertEqual(before, after)

    def test_unpack_take_setup_rejects_empty_from_without_rewriting_file(self):
        with tempfile.TemporaryDirectory() as td:
            temp_root = pathlib.Path(td)
            tool_root = self.make_tool_copy(temp_root)
            config_path = tool_root / "conf.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [unpack]
                    pack_dir = "~/syncpacks"
                    pack_prefix = "syncpack"
                    peer = "sync"
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )
            before = config_path.read_text(encoding="utf-8")

            completed = self.run_setup(
                [tool_root / "unpack", "take", "setup"],
                cwd=temp_root,
                input_text="\n",
            )

            after = config_path.read_text(encoding="utf-8")

        combined = completed.stdout + completed.stderr
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("unpack.take.telegram.from (Telegram source chat used for take):", combined)
        self.assertIn("unpack.take.telegram.from cannot be empty.", combined)
        self.assertEqual(before, after)
