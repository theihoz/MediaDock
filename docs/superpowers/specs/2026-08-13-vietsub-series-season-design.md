# Vietsub Series/Season Design

## Goal

Make the subtitle tab compact for TV shows and anime while prioritizing Vietnamese subtitles from OpenSubtitles.com and Gestdown.

## Provider policy

- Enable only `gestdown` by default when no credentials are present.
- Enable `opensubtitlescom` when both `OPENSUBTITLES_USERNAME` and `OPENSUBTITLES_PASSWORD` exist in the private `.env`.
- Do not enable AnimeTosho, AnimeKalesi, AnimeSubInfo, or YIFY Subtitles.
- Keep the existing language profile ordered `vi`, then `en`, with cutoff `vi`.
- English is a fallback and never marks Vietnamese coverage complete.
- Missing Vietnamese subtitles remain eligible for the six-hour wanted search.
- Never return credentials from backend APIs or Flutter.

## Subtitle catalog API

`GET /v1/library/subtitle-media` returns movie rows plus compact series rows. A series row contains `mediaId` (Sonarr series ID), `type: series`, title, year, poster, episode count, Vietnamese subtitle count, missing Vietnamese count, and seasons with the same counts. It does not return every episode.

`GET /v1/library/subtitle-media/{seriesId}/seasons/{seasonNumber}` returns only that season's imported episodes. Each episode contains the Sonarr/Bazarr episode ID, title, media path, and Vietnamese subtitle availability. Existing episode search/download/refresh endpoints keep using that episode ID.

Coverage is determined from Bazarr episode data when available and from `.vi.*` sidecar metadata reported by Bazarr. Failure to read Bazarr coverage must not remove imported Sonarr episodes; it returns zero known Vietnamese subtitles and a degraded coverage flag.

## Flutter interaction

- Movies remain selectable as before.
- TV shows render as one expandable card per series.
- Expanding a series shows season rows such as `Season 1 — Vietsub 18/24`.
- Episodes are fetched only after selecting a season.
- Missing-Vietsub episodes appear first.
- Search defaults to Vietnamese for episodes. English remains selectable as a manual fallback.
- Returning from an episode list preserves the selected series and season.

## Bootstrap and settings

Bootstrap reconciles providers idempotently. `Gestdown` is ready without credentials. OpenSubtitles.com reports `needs_credentials` until both private environment values exist, then Bazarr is restarted during the user-initiated Start/bootstrap flow. Media stack restart policy remains `no`.

## Verification

- Provider reconciliation is idempotent and never writes secrets to logs.
- The initial subtitle response contains no individual TV episodes.
- Selecting a season returns only imported episodes for that season.
- Vietnamese coverage remains incomplete when only English exists.
- Existing movie subtitle behavior remains compatible.
- Backend tests, bootstrap tests, Flutter tests/analyze/build, Compose validation, and runtime smoke tests pass.
