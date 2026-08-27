"""Reconcile Bazarr's default Vietnamese/English profile while Bazarr is stopped."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
from pathlib import Path


PROFILE_NAME = "Vietnamese-English"
PROFILE_ITEMS = [
    {"id": 1, "language": "vi", "audio_exclude": "False", "audio_only_include": "False", "hi": "False", "forced": "False"},
    {"id": 2, "language": "en", "audio_exclude": "False", "audio_only_include": "False", "hi": "False", "forced": "False"},
]
GENERAL_VALUES = {
    "adaptive_searching": "true",
    "concurrent_jobs": "4",
    "movie_default_enabled": "true",
    "serie_default_enabled": "true",
    "single_language": "false",
    "use_embedded_subs": "false",
    "utf8_encode": "true",
    "wanted_search_frequency": "6",
}


def _backup_database(connection: sqlite3.Connection, backup_dir: Path, timestamp: str) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    target = backup_dir / f"bazarr-before-profile-{timestamp}.db"
    backup = sqlite3.connect(target)
    try:
        connection.backup(backup)
    finally:
        backup.close()
    return target


def _reconcile_config(
    config_path: Path,
    profile_id: int,
    opensubtitles_username: str = "",
    opensubtitles_password: str = "",
) -> None:
    lines = config_path.read_text(encoding="utf-8").splitlines()
    wanted = {**GENERAL_VALUES, "movie_default_profile": str(profile_id), "serie_default_profile": str(profile_id)}
    output: list[str] = []
    seen: set[str] = set()
    in_general = False
    in_opensubtitles = False
    skipping_providers = False
    opensubtitles_enabled = bool(opensubtitles_username and opensubtitles_password)

    for line in lines:
        if line and not line.startswith(" ") and line.endswith(":"):
            if in_general:
                for key, value in wanted.items():
                    if key not in seen:
                        output.append(f"  {key}: {value}")
            in_general = line == "general:"
            in_opensubtitles = line == "opensubtitlescom:"
            skipping_providers = False
        if in_general and skipping_providers:
            if line.startswith("  - "):
                continue
            skipping_providers = False
        if in_general and line.startswith("  enabled_providers:"):
            output.extend(["  enabled_providers:", "  - gestdown", "  - yifysubtitles"])
            if opensubtitles_enabled:
                output.append("  - opensubtitlescom")
            skipping_providers = True
            continue
        if in_general:
            stripped = line.strip()
            key = stripped.split(":", 1)[0] if ":" in stripped else ""
            if key in wanted:
                output.append(f"  {key}: {wanted[key]}")
                seen.add(key)
                continue
        if in_opensubtitles and line.startswith("  username:"):
            output.append(f"  username: {json.dumps(opensubtitles_username if opensubtitles_enabled else '')}")
            continue
        if in_opensubtitles and line.startswith("  password:"):
            output.append(f"  password: {json.dumps(opensubtitles_password if opensubtitles_enabled else '')}")
            continue
        output.append(line)

    if in_general:
        for key, value in wanted.items():
            if key not in seen:
                output.append(f"  {key}: {value}")
    temporary = config_path.with_suffix(config_path.suffix + ".tmp")
    temporary.write_text("\n".join(output) + "\n", encoding="utf-8")
    os.replace(temporary, config_path)


def configure_profile(
    db_path: Path,
    config_path: Path,
    backup_dir: Path,
    timestamp: str,
    opensubtitles_username: str = "",
    opensubtitles_password: str = "",
) -> dict:
    db_path, config_path, backup_dir = Path(db_path), Path(config_path), Path(backup_dir)
    connection = sqlite3.connect(db_path)
    try:
        backup_path = _backup_database(connection, backup_dir, timestamp)
        existing = connection.execute(
            "SELECT profileId FROM table_languages_profiles WHERE name=? ORDER BY profileId", (PROFILE_NAME,)
        ).fetchall()
        profile_id = existing[0][0] if existing else (connection.execute("SELECT coalesce(max(profileId), 0) + 1 FROM table_languages_profiles").fetchone()[0])
        duplicate_ids = [row[0] for row in existing[1:]]

        movie_updates = connection.execute("SELECT count(*) FROM table_movies WHERE profileId IS NULL OR profileId != ?", (profile_id,)).fetchone()[0]
        series_updates = connection.execute("SELECT count(*) FROM table_shows WHERE profileId IS NULL OR profileId != ?", (profile_id,)).fetchone()[0]
        connection.execute(
            "INSERT INTO table_languages_profiles(profileId, cutoff, originalFormat, items, name, mustContain, mustNotContain, tag) VALUES(?,?,?,?,?,?,?,?) "
            "ON CONFLICT(profileId) DO UPDATE SET cutoff=excluded.cutoff, originalFormat=excluded.originalFormat, items=excluded.items, name=excluded.name, mustContain=excluded.mustContain, mustNotContain=excluded.mustNotContain, tag=excluded.tag",
            (profile_id, 1, 0, json.dumps(PROFILE_ITEMS, separators=(",", ":")), PROFILE_NAME, "[]", "[]", "vi-en"),
        )
        connection.execute("UPDATE table_movies SET profileId=? WHERE profileId IS NULL OR profileId != ?", (profile_id, profile_id))
        connection.execute("UPDATE table_shows SET profileId=? WHERE profileId IS NULL OR profileId != ?", (profile_id, profile_id))
        if duplicate_ids:
            placeholders = ",".join("?" for _ in duplicate_ids)
            connection.execute(f"DELETE FROM table_languages_profiles WHERE profileId IN ({placeholders})", duplicate_ids)
        for code3, code2, name in (("vie", "vi", "Vietnamese"), ("eng", "en", "English")):
            connection.execute(
                "INSERT INTO table_settings_languages(code3, code2, code3b, enabled, name) VALUES(?,?,?,?,?) "
                "ON CONFLICT(code3) DO UPDATE SET code2=excluded.code2, enabled=1, name=excluded.name",
                (code3, code2, code3, 1, name),
            )
        connection.commit()
    finally:
        connection.close()

    _reconcile_config(config_path, profile_id, opensubtitles_username, opensubtitles_password)
    return {"profileId": profile_id, "moviesUpdated": movie_updates, "seriesUpdated": series_updates, "backupPath": str(backup_path)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--backup-dir", required=True, type=Path)
    parser.add_argument("--timestamp", required=True)
    parser.add_argument("--opensubtitles-username", default="")
    parser.add_argument("--opensubtitles-password", default="")
    args = parser.parse_args()
    print(json.dumps(configure_profile(
        args.db, args.config, args.backup_dir, args.timestamp,
        args.opensubtitles_username, args.opensubtitles_password,
    ), separators=(",", ":")))


if __name__ == "__main__":
    main()
