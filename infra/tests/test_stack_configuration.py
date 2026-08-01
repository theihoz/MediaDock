import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "linux" / "configure-stack.py"
SPEC = importlib.util.spec_from_file_location("configure_stack", MODULE_PATH)
configure_stack = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configure_stack)


class StackConfigurationTests(unittest.TestCase):
    def test_extract_qbittorrent_password_reads_stderr_logs(self):
        completed = subprocess.CompletedProcess(
            args=["docker", "logs", "qbittorrent"],
            returncode=0,
            stdout="",
            stderr="A temporary password is provided for this session: current-pass\n",
        )
        self.assertEqual(
            "current-pass", configure_stack.extract_qbittorrent_password(completed)
        )

    def test_qbittorrent_login_accepts_v4_and_v5_success_bodies(self):
        self.assertTrue(configure_stack.qbittorrent_login_succeeded("Ok."))
        self.assertTrue(configure_stack.qbittorrent_login_succeeded(""))
        self.assertFalse(configure_stack.qbittorrent_login_succeeded("Fails."))

    def test_parse_sabnzbd_api_key_accepts_version_preamble(self):
        ini = "__version__ = 19\n[misc]\napi_key = abc123\nport = 8080\n"
        self.assertEqual("abc123", configure_stack.parse_sabnzbd_api_key(ini))

    def test_sabnzbd_settings_allow_only_expected_internal_hosts(self):
        settings = configure_stack.sabnzbd_misc_settings()
        self.assertEqual("sabnzbd,localhost,127.0.0.1", settings["host_whitelist"])
        self.assertEqual(
            "/data/downloads/usenet/incomplete", settings["download_dir"]
        )

    def test_seerr_network_prefers_ipv4_without_changing_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "settings.json"
            original = {
                "sessionSecret": "keep-me",
                "network": {"forceIpv4First": False, "apiRequestTimeout": 20000},
                "radarr": [{"name": "Radarr", "activeProfileId": 1}],
                "sonarr": [{"name": "Sonarr", "activeProfileId": 1}],
            }
            path.write_text(json.dumps(original), encoding="utf-8")
            changed = configure_stack.configure_seerr_network(path)
            configured = json.loads(path.read_text(encoding="utf-8"))
            self.assertTrue(changed)
            self.assertTrue(configured["network"]["forceIpv4First"])
            self.assertEqual(configured["radarr"][0]["activeProfileId"], 4)
            self.assertEqual(configured["sonarr"][0]["activeProfileId"], 4)
            self.assertEqual(configured["sessionSecret"], "keep-me")

    def test_redact_hides_known_secret_shapes(self):
        text = 'ApiKey="0123456789abcdef0123456789abcdef" password=hunter2'
        redacted = configure_stack.redact(text)
        self.assertNotIn("0123456789abcdef0123456789abcdef", redacted)
        self.assertNotIn("hunter2", redacted)
        self.assertIn("[redacted]", redacted)

    def test_set_schema_field_updates_matching_field_only(self):
        schema = {
            "fields": [
                {"name": "host", "value": "old"},
                {"name": "port", "value": 1},
            ]
        }
        configure_stack.set_schema_field(schema, "host", "qbittorrent")
        self.assertEqual("qbittorrent", schema["fields"][0]["value"])
        self.assertEqual(1, schema["fields"][1]["value"])

    def test_set_schema_field_rejects_unknown_required_field(self):
        with self.assertRaises(KeyError):
            configure_stack.set_schema_field({"fields": []}, "host", "x")

    def test_equivalent_record_matches_name_and_implementation(self):
        records = [
            {"name": "qBittorrent", "implementation": "QBittorrent"},
            {"name": "SABnzbd", "implementation": "Sabnzbd"},
        ]
        self.assertTrue(
            configure_stack.has_equivalent(
                records, name="qBittorrent", implementation="QBittorrent"
            )
        )
        self.assertFalse(
            configure_stack.has_equivalent(
                records, name="Prowlarr", implementation="Prowlarr"
            )
        )

    def test_build_schema_record_preserves_contract_and_sets_values(self):
        schema = {
            "implementation": "QBittorrent",
            "configContract": "QBittorrentSettings",
            "fields": [
                {"name": "host", "value": "localhost"},
                {"name": "port", "value": 8080},
                {"name": "password", "value": ""},
            ],
        }
        record = configure_stack.build_schema_record(
            schema,
            name="qBittorrent",
            values={"host": "qbittorrent", "port": 8080, "password": "secret"},
        )
        self.assertEqual("qBittorrent", record["name"])
        self.assertEqual("QBittorrentSettings", record["configContract"])
        self.assertEqual(
            "qbittorrent",
            next(field["value"] for field in record["fields"] if field["name"] == "host"),
        )

    def test_build_schema_record_does_not_mutate_source_schema(self):
        schema = {"implementation": "X", "fields": [{"name": "host", "value": "old"}]}
        configure_stack.build_schema_record(schema, name="new", values={"host": "new"})
        self.assertEqual("old", schema["fields"][0]["value"])


if __name__ == "__main__":
    unittest.main()
