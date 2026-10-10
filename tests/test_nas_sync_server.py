import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "nas-sync-server"))
import server


class NASDataLayerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        server.DATA_DIR = Path(self.temp.name)
        server.DB_PATH = server.DATA_DIR / "test.sqlite3"

    def tearDown(self):
        self.temp.cleanup()

    def test_namespaces_are_independent_and_revisions_are_checked(self):
        web = {"_v": 3, "db": {"hold": [{"code": "510300"}]}}
        native = {"schemaVersion": 1, "data": {"holdings": [{"code": "510300"}], "ledger": []}, "intradayBars": [], "dailyBars": []}
        self.assertEqual(server.write_snapshot("legacy", web)["revision"], 1)
        self.assertEqual(server.write_snapshot("native", native, expected_revision=0)["revision"], 1)
        conflict = server.write_snapshot("native", native, expected_revision=0)
        self.assertTrue(conflict["conflict"])
        self.assertEqual(server.read_snapshot("legacy")["data"], web)
        self.assertEqual(server.read_snapshot("native")["data"], native)

    def test_empty_native_overwrite_guard_detects_ledger_data(self):
        full = {"data": {"holdings": [{"code": "510300"}]}, "intradayBars": [], "dailyBars": []}
        cash_only = {"data": {"holdings": [], "cash": 10}, "intradayBars": [], "dailyBars": []}
        empty = {"data": {"holdings": [], "ledger": []}, "intradayBars": [], "dailyBars": []}
        self.assertTrue(server.contains_user_data(full))
        self.assertTrue(server.contains_user_data(cash_only))
        self.assertFalse(server.contains_user_data(empty))

    def test_keeps_latest_ten_rollback_versions(self):
        for revision in range(1, 14):
            server.write_snapshot("native", {"data": {"cash": revision}}, expected_revision=revision - 1)
        with server.connect() as db:
            rows = db.execute("SELECT revision FROM history WHERE namespace='native' ORDER BY revision").fetchall()
        self.assertEqual([row[0] for row in rows], list(range(4, 14)))


if __name__ == "__main__":
    unittest.main()
