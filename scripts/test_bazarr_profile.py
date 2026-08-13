import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from bazarr_profile import configure_profile


class BazarrProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.db = self.root / "bazarr.db"
        self.config = self.root / "config.yaml"
        self.backups = self.root / "backups"
        connection = sqlite3.connect(self.db)
        connection.executescript("""
          CREATE TABLE table_languages_profiles (profileId INTEGER PRIMARY KEY, cutoff INTEGER, originalFormat INTEGER, items TEXT NOT NULL, name TEXT NOT NULL, mustContain TEXT, mustNotContain TEXT, tag TEXT);
          CREATE TABLE table_settings_languages (code3 TEXT PRIMARY KEY, code2 TEXT, code3b TEXT, enabled INTEGER, name TEXT NOT NULL);
          CREATE TABLE table_movies (radarrId INTEGER PRIMARY KEY, profileId INTEGER);
          CREATE TABLE table_shows (sonarrSeriesId INTEGER PRIMARY KEY, profileId INTEGER);
          INSERT INTO table_languages_profiles VALUES (3, NULL, 0, '[]', 'Vietnamese-English', '[]', '[]', 'old');
          INSERT INTO table_languages_profiles VALUES (7, NULL, 0, '[]', 'Vietnamese-English', '[]', '[]', 'duplicate');
          INSERT INTO table_settings_languages VALUES ('vie', 'vi', 'vie', 0, 'Vietnamese');
          INSERT INTO table_settings_languages VALUES ('eng', 'en', 'eng', 0, 'English');
          INSERT INTO table_movies VALUES (10, NULL), (11, 7);
          INSERT INTO table_shows VALUES (20, NULL);
        """)
        connection.commit()
        connection.close()
        self.config.write_text("""general:
  adaptive_searching: false
  enabled_providers:
  - old
  movie_default_enabled: false
  movie_default_profile: null
  serie_default_enabled: false
  serie_default_profile: null
  single_language: true
  use_embedded_subs: true
  utf8_encode: false
  wanted_search_frequency: 24
radarr:
  use_radarr: true
""", encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def test_reconciles_one_default_profile_and_existing_media(self):
        result = configure_profile(self.db, self.config, self.backups, "20260813-120000")
        connection = sqlite3.connect(self.db)
        profiles = connection.execute("SELECT profileId, cutoff, items, tag FROM table_languages_profiles WHERE name='Vietnamese-English'").fetchall()
        movies = connection.execute("SELECT profileId FROM table_movies ORDER BY radarrId").fetchall()
        shows = connection.execute("SELECT profileId FROM table_shows").fetchall()
        enabled = connection.execute("SELECT code2, enabled FROM table_settings_languages ORDER BY code2").fetchall()
        connection.close()

        self.assertEqual(len(profiles), 1)
        profile_id, cutoff, items, tag = profiles[0]
        self.assertEqual(cutoff, 1)
        self.assertEqual([item["language"] for item in json.loads(items)], ["vi", "en"])
        self.assertEqual(tag, "vi-en")
        self.assertEqual(movies, [(profile_id,), (profile_id,)])
        self.assertEqual(shows, [(profile_id,)])
        self.assertEqual(enabled, [("en", 1), ("vi", 1)])
        self.assertEqual(result["moviesUpdated"], 2)
        self.assertEqual(result["seriesUpdated"], 1)
        self.assertTrue(Path(result["backupPath"]).is_file())

        config = self.config.read_text(encoding="utf-8")
        self.assertIn("  enabled_providers:\n  - gestdown\n  - yifysubtitles", config)
        self.assertIn(f"  movie_default_profile: {profile_id}", config)
        self.assertIn(f"  serie_default_profile: {profile_id}", config)
        self.assertIn("  use_embedded_subs: false", config)
        self.assertIn("  adaptive_searching: true", config)
        self.assertIn("  wanted_search_frequency: 6", config)
        self.assertIn("  utf8_encode: true", config)

    def test_second_run_is_idempotent_but_keeps_a_recovery_backup(self):
        first = configure_profile(self.db, self.config, self.backups, "20260813-120000")
        second = configure_profile(self.db, self.config, self.backups, "20260813-120100")
        connection = sqlite3.connect(self.db)
        count = connection.execute("SELECT count(*) FROM table_languages_profiles WHERE name='Vietnamese-English'").fetchone()[0]
        connection.close()
        self.assertEqual(count, 1)
        self.assertEqual(second["moviesUpdated"], 0)
        self.assertEqual(second["seriesUpdated"], 0)
        self.assertNotEqual(first["backupPath"], second["backupPath"])


if __name__ == "__main__":
    unittest.main()
