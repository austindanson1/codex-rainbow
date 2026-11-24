import json
import os
from pathlib import Path
import subprocess
import sqlite3
import sys
import tempfile
import unittest

BIN = Path(sys.argv.pop(1)).resolve()
SCRATCH = Path(sys.argv.pop(1)).resolve()
IDS = [f"018f0000-{step:04x}-7000-8000-000000000000" for step in range(12)]


class RainbowCLI(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="rainbow-tests-", dir=SCRATCH)
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.index = self.root / "session_index.jsonl"
        self.state = self.root / "state"
        self.env = {**os.environ, "CODEX_HOME": str(self.root), "CODEX_RAINBOW_STATE_DIR": str(self.state)}

    def index_chats(self, *entries):
        self.index.write_text(
            "\n".join(json.dumps({"id": IDS[i], "thread_name": title}) for i, title in entries) + "\n"
        )

    def run_cli(self, *args, check=True):
        return subprocess.run([BIN, *args], env=self.env, check=check, text=True, capture_output=True)

    def find(self, title=""):
        return {row["id"]: row for row in json.loads(self.run_cli("find", title).stdout)}

    def test_cycle_is_creation_order_and_wraps(self):
        self.index_chats(*reversed([(i, f"Chat {i}") for i in range(10)]))
        result = self.find()
        self.assertEqual(
            ["red", "orange", "yellow", "green", "turquoise", "blue", "indigo", "violet", "red", "orange"],
            [result[i]["color"] for i in IDS[:10]],
        )

    def test_rename_reorder_restart_override_and_restore(self):
        self.index_chats((0, "Original"), (1, "Another"))
        self.assertEqual("red", self.find()[IDS[0]]["color"])
        self.run_cli("set", "turquoise", f"codex://thread/{IDS[0]}")
        self.index_chats((2, "New entry"), (1, "Another"), (0, "Original"), (0, "Renamed"))
        self.assertEqual({}, self.find("Original"))
        renamed = self.find("Renamed")[IDS[0]]
        self.assertEqual("turquoise", renamed["override"])
        self.assertEqual("yellow", self.find()[IDS[2]]["color"])
        self.run_cli("reset", IDS[0])
        self.assertEqual("red", self.find()[IDS[0]]["color"])

    def test_batch_validates_every_id_before_writing(self):
        self.index_chats((0, "One"), (1, "Two"))
        before = self.find()
        result = self.run_cli("set", "blue", IDS[0], IDS[2], check=False)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(before, self.find())
        self.run_cli("set", "blue", IDS[0], IDS[1])
        self.assertEqual({"blue"}, {row["color"] for row in self.find().values()})

    def folder_metadata(self, *entries):
        database = self.root / "state_5.sqlite"
        with sqlite3.connect(database) as connection:
            connection.executescript("""
                CREATE TABLE IF NOT EXISTS thread_sections (id TEXT, name TEXT);
                CREATE TABLE IF NOT EXISTS threads (
                    id TEXT, project_id TEXT, thread_section_id TEXT, archived INTEGER,
                    is_pinned INTEGER, section_position INTEGER, created_at INTEGER
                );
                DELETE FROM threads;
                DELETE FROM thread_sections;
                INSERT INTO thread_sections VALUES ('pins', 'Pinned'), ('custom', 'Custom folder');
            """)
            connection.executemany(
                "INSERT INTO threads VALUES (?, ?, ?, ?, 0, ?, ?)",
                [(IDS[i], project, section, int(archived), i, i) for i, project, section, archived in entries],
            )

    def test_reset_keeps_pins_and_advances_each_folder(self):
        entries = [(0, "a", None, False), (1, "b", None, False), (2, "a", None, False),
                   (3, None, "custom", False), (4, "b", "pins", False), (5, "b", None, False),
                   (6, "b", None, True)]
        self.index_chats(*[(i, "Chat " + str(i)) for i, *_ in entries])
        self.folder_metadata(*entries)
        self.run_cli("set", "violet", IDS[0], IDS[4], IDS[5], IDS[6])
        report = json.loads(self.run_cli("reset-rainbow", IDS[5]).stdout)
        self.assertEqual({"chats": 4, "folders": 3, "pinnedPreserved": 2}, report)
        result = self.find()
        self.assertIsNone(result[IDS[0]].get("override"))
        self.assertEqual(["red", "red", "orange", "red", "violet", "violet", "violet"],
                         [result[i]["color"] for i in IDS[:7]])

        # A chat can change folders without changing existing assignments.
        entries[2] = (2, "b", None, False)
        entries.extend([(7, "a", None, False), (8, "b", None, False), (9, None, "custom", False)])
        self.folder_metadata(*entries)
        self.index_chats(*[(i, "Chat " + str(i)) for i, *_ in entries])
        result = self.find()
        self.assertEqual(["orange", "yellow", "orange", "orange"],
                         [result[IDS[i]]["color"] for i in (2, 7, 8, 9)])

    def test_existing_color_file_migrates_without_recoloring(self):
        self.index_chats((0, "Existing"), (1, "Another"), (2, "New"))
        self.folder_metadata((0, "a", None, False), (1, "b", None, False), (2, "a", None, False))
        self.state.mkdir()
        (self.state / "colors.json").write_text(json.dumps({
            "version": 1, "next": 2,
            "rainbow": {IDS[0].upper(): "red", IDS[1].upper(): "orange"},
            "overrides": {IDS[0].upper(): "turquoise"},
        }))
        result = self.find()
        self.assertEqual(["turquoise", "orange", "orange"], [result[i]["color"] for i in IDS[:3]])

    def test_css_export_uses_exact_local_ids_and_current_colors(self):
        self.index_chats((0, "Private example title"), (1, "Another"))
        self.run_cli("set", "turquoise", IDS[1])
        state = self.state / "colors.json"
        before = state.read_bytes()
        css = self.run_cli("css").stdout
        self.assertIn('[data-app-action-sidebar-thread-row]', css)
        self.assertIn('[data-app-action-sidebar-thread-id^="local:"]', css)
        self.assertIn(f'[data-app-action-sidebar-thread-id$=":{IDS[1]}" i]', css)
        self.assertIn('linear-gradient(#29c7b83b, #29c7b83b)', css)
        self.assertIn('linear-gradient(#ee52673b, #ee52673b)', css)
        self.assertNotIn("Private example title", css)
        self.assertEqual(state.read_bytes(), before)

    def test_fresh_sync_on_legacy_schema_and_export_after_reopen(self):
        self.index_chats((0, "A"), (1, "B"), (2, "C"))
        with sqlite3.connect(self.root / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads (id TEXT, cwd TEXT, archived INTEGER)")
            db.executemany("INSERT INTO threads VALUES (?, ?, 0)", zip(IDS[:3], ["/one", "/two", "/one"]))
        css = self.run_cli("sync-css").stdout
        self.assertEqual(css, self.run_cli("css").stdout)
        self.assertEqual(["red", "red", "orange"], [self.find()[i]["color"] for i in IDS[:3]])
        self.assertNotEqual(0, self.run_cli("reset-rainbow", check=False).returncode)

    def test_concurrent_overrides_survive(self):
        self.index_chats(*[(i, f"Chat {i}") for i in range(10)])
        processes = [
            subprocess.Popen([BIN, "set", "indigo", chat], env=self.env, stdout=subprocess.DEVNULL)
            for chat in IDS[:10]
        ]
        for process in processes:
            self.assertEqual(0, process.wait(timeout=10))
        self.assertEqual({"indigo"}, {row["override"] for row in self.find().values()})

    def test_corrupt_state_fails_without_replacing_it(self):
        self.index_chats((0, "One"))
        self.state.mkdir()
        file = self.state / "colors.json"
        for invalid in ('{"version":1,"next":999,"rainbow":{},"overrides":{}}', "{invalid"):
            with self.subTest(invalid=invalid):
                file.write_text(invalid)
                self.assertNotEqual(0, self.run_cli("find", check=False).returncode)
                self.assertEqual(invalid, file.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
