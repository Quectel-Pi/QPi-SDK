#!/usr/bin/env python3
"""临时 Git 仓库验证快照器，绝不访问发布底包或演示目录。"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCANNER = Path(__file__).with_name("scan-local.py")


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.upstream = root / "upstream"
        self.sdk = root / "sdk"
        self.kernel = self.sdk / "kernel"
        self.output = root / "snapshot"
        for repo in (self.upstream, self.sdk):
            repo.mkdir()
            self.git(repo, "init", "-q")
        original = self.upstream / "kernel-6.1"
        original.mkdir()
        (original / "tracked.c").write_text("base\n")
        self.git(self.upstream, "add", ".")
        self.git(self.upstream, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "-qm", "fixture")
        self.base = self.git(self.upstream, "rev-parse", "HEAD").stdout.strip()
        self.kernel.mkdir()
        (self.kernel / "tracked.c").write_text("base\n")
        (self.sdk / ".gitignore").write_text("*.o\n")
        self.git(self.sdk, "add", ".")

    @staticmethod
    def git(repo, *args):
        return subprocess.run(["git", "-C", str(repo), *args], check=True,
                              capture_output=True, text=True)

    def scan(self):
        return subprocess.run([sys.executable, str(SCANNER), str(self.upstream),
                               "kernel-6.1", self.base, str(self.kernel), str(self.output)],
                              capture_output=True, text=True)

    def test_new_source_and_modified_source_are_saved(self):
        (self.kernel / "tracked.c").write_text("modified\n")
        (self.kernel / "new.c").write_text("new\n")
        (self.kernel / "ignored.o").write_bytes(b"object")
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "new.c").read_text(), "new\n")
        self.assertEqual((self.output / "tracked.c").read_text(), "modified\n")
        self.assertFalse((self.output / "ignored.o").exists())

    def test_deleted_tracked_source_blocks_and_preserves_old_snapshot(self):
        self.output.mkdir()
        (self.output / "keep").write_text("previous snapshot")
        (self.kernel / "tracked.c").unlink()
        result = self.scan()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("本地删除", result.stderr)
        self.assertTrue((self.output / "keep").exists())

    def test_permissions_change_blocks(self):
        os.chmod(self.kernel / "tracked.c", 0o755)
        result = self.scan()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("权限", result.stderr)

    def test_new_symlink_blocks_text_merge(self):
        (self.kernel / "new-link").symlink_to("tracked.c")
        result = self.scan()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("符号链接", result.stderr)

    def test_invalid_revision_does_not_replace_snapshot(self):
        self.output.mkdir()
        (self.output / "keep").touch()
        self.base = "not-a-real-commit"
        self.assertNotEqual(self.scan().returncode, 0)
        self.assertTrue((self.output / "keep").exists())

    def test_unchanged_tree_has_empty_snapshot(self):
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.output.iterdir()), [])


if __name__ == "__main__":
    unittest.main()