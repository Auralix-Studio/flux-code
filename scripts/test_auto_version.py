"""Offline release planning tests against isolated, real Git repositories."""
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import auto_version as release


class AutoVersionTest(unittest.TestCase):
    def setUp(self):
        parent = pathlib.Path(__file__).resolve().parent.parent / "dist"
        parent.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="version-tests-", dir=parent, ignore_cleanup_errors=True)
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.override = patch.object(release, "ROOT", self.root)
        self.override.start()
        self.addCleanup(self.override.stop)
        self.mock_remote = patch.object(release, "get_remote_public_tags", return_value=set())
        self.mock_remote.start()
        self.addCleanup(self.mock_remote.stop)
        self.git("init", "-q")
        self.git("config", "user.name", "Release tests")
        self.git("config", "user.email", "tests@example.invalid")
        (self.root / "lib/core").mkdir(parents=True)
        (self.root / "assets").mkdir()
        (self.root / "pubspec.yaml").write_text("name: flux\nversion: 1.0.0+1\n", encoding="utf-8")
        (self.root / "lib/core/app_version.dart").write_text("initial", encoding="utf-8")
        (self.root / "assets/changelog.json").write_text(json.dumps([{
            "version": "1.0.0", "date": "2026-10-17", "title": "Flux 1.0.0",
            "changes": [{"type": "improvement", "description": "PENDIENTE: review"}]
        }]), encoding="utf-8")
        self.commit("feat: primera versión")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True,
                              capture_output=True, encoding="utf-8").stdout.strip()

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-q", "--allow-empty", "-m", message)

    def test_first_release_keeps_version_and_updates_all_sources(self):
        result = release.plan()
        self.assertEqual((result["version"], result["build"]), ("1.0.0", 2))
        release.apply(result, "2026-10-17")
        self.assertIn("version: 1.0.0+2", (self.root / "pubspec.yaml").read_text())
        self.assertIn("full = '1.0.0+2'", (self.root / "lib/core/app_version.dart").read_text())
        notes = json.loads((self.root / "assets/changelog.json").read_text(encoding="utf-8"))
        self.assertEqual(notes[0]["changes"][0]["description"], "primera versión")

    def test_docs_and_release_commits_do_not_publish(self):
        self.git("tag", "v1.0.0")
        self.commit("docs: ayuda")
        self.commit("chore(release): v1.0.0 [skip ci]")
        self.assertEqual(release.plan(), {"release": False})

    def test_conventional_levels(self):
        for subject, body, expected in [
            ("fix(player): corregir pausa", "", 1),
            ("feat: subtítulos", "", 2),
            ("feat(api)!: nuevo contrato", "", 3),
            ("refactor: contrato", "BREAKING CHANGE: nuevo formato", 3),
            ("ci: pruebas", "", 0), ("corregir reproducción", "", 1),
        ]:
            with self.subTest(subject=subject):
                self.assertEqual(release.classify(subject, body)[0], expected)

    def test_fix_feature_and_breaking_choose_highest(self):
        self.git("tag", "v1.0.0")
        self.commit("fix: pausa")
        self.commit("feat: audio")
        self.assertEqual(release.plan()["version"], "1.1.0")
        self.commit("feat!: contrato")
        self.assertEqual(release.plan()["version"], "2.0.0")

    def test_reviewed_notes_are_preserved(self):
        file = self.root / "assets/changelog.json"
        entries = json.loads(file.read_text())
        entries[0]["changes"] = [{"type": "fix", "description": "Nota revisada"}]
        file.write_text(json.dumps(entries), encoding="utf-8")
        self.commit("fix: corrección")
        release.apply(release.plan(), "2026-10-17")
        self.assertEqual(json.loads(file.read_text())[0]["changes"], entries[0]["changes"])

    def test_dirty_worktree_blocks_apply(self):
        (self.root / "unknown.txt").write_text("preserve")
        with self.assertRaisesRegex(ValueError, "Commit local changes"):
            release.apply(release.plan(), "2026-10-17")

    def test_manually_prepared_version_never_decreases(self):
        self.git("tag", "v1.0.0")
        (self.root / "pubspec.yaml").write_text("name: flux\nversion: 3.0.0+8\n")
        self.commit("fix: corrección")
        self.assertEqual((release.plan()["version"], release.plan()["build"]), ("3.0.0", 9))

    def test_previous_build_is_always_exceeded(self):
        file = self.root / "pubspec.yaml"
        file.write_text("name: flux\nversion: 1.0.0+50\n")
        self.commit("chore: build")
        self.git("tag", "v1.0.0")
        file.write_text("name: flux\nversion: 1.0.1+1\n")
        self.commit("fix: build accidental")
        self.assertEqual(release.plan()["build"], 51)

    def test_android_limit_blocks_overflow(self):
        (self.root / "pubspec.yaml").write_text(f"name: flux\nversion: 1.0.0+{release.MAX_BUILD}\n")
        self.commit("fix: limite")
        with self.assertRaisesRegex(ValueError, "Android versionCode"):
            release.plan()

    def test_next_is_read_only(self):
        before = self.git("status", "--porcelain")
        release.plan()
        self.assertEqual(self.git("status", "--porcelain"), before)

    def test_remote_public_tag_collision_advances_version(self):
        self.git("tag", "v1.0.0")
        with patch.object(release, "get_remote_public_tags", return_value={"v1.5.0"}):
            self.commit("fix: correccion")
            self.assertEqual(release.plan()["version"], "1.5.1")


if __name__ == "__main__":
    unittest.main()
