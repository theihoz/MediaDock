# Season Vietsub Auto Search Design

## Goal

Allow a user to select one imported TV season and ask Bazarr to find and download the best Vietnamese subtitle for every episode in that season that is still missing Vietsub. The user must not need to select and search each episode individually.

## User experience

- Selecting a season continues to load its imported episodes lazily.
- The primary action becomes `Tìm Vietsub cho Season N` while a series season is selected.
- The existing episode selector remains available for exceptional manual search, replacement, and deletion.
- Starting a season search shows aggregate progress instead of individual search-result lists.
- The final result reports counts for:
  - episodes that already had Vietnamese subtitles;
  - episodes where Vietnamese subtitles were downloaded;
  - episodes with no acceptable result;
  - episodes that failed.
- After completion, the season coverage chip refreshes immediately.

## Backend contract

Add an authenticated endpoint:

`POST /v1/library/subtitle-media/{seriesId}/seasons/{seasonNumber}/search`

The request body does not accept destination paths or provider credentials. Vietnamese is the fixed primary language for this operation. The response is an aggregate job result:

```json
{
  "seriesId": 21,
  "seasonNumber": 1,
  "total": 24,
  "alreadyAvailable": 3,
  "downloaded": 18,
  "unavailable": 2,
  "failed": 1
}
```

The operation is idempotent at media level: episodes already carrying an explicit Vietnamese subtitle are skipped.

## Search and download flow

1. Resolve the series and imported episodes through Sonarr.
2. Resolve current subtitle coverage through Bazarr.
3. Restrict work to the selected season and episodes with imported files.
4. Skip episodes that already contain an explicit `vi` subtitle.
5. Search the remaining episodes through Bazarr. Bazarr uses all enabled providers concurrently: Gestdown, YIFY Subtitles, and OpenSubtitles.com when configured.
6. Choose the highest-scoring acceptable Vietnamese result returned for each episode and ask Bazarr to download it.
7. Limit episode concurrency so a large season does not overload Bazarr or trigger provider rate limits.
8. Isolate failures per episode; one provider or episode failure does not abort the season.
9. Rescan affected episodes and request a Jellyfin library refresh after the batch.
10. Reload season coverage for the Flutter client.

English remains the automatic fallback managed by the existing Bazarr profile, but English does not count as successful Vietsub coverage for this endpoint.

## Security and resilience

- Flutter never receives provider credentials, raw subtitle URLs, or Bazarr API keys.
- The backend accepts only numeric series and season identifiers and resolves every episode internally.
- Subtitle destination paths remain controlled by Bazarr/backend.
- Duplicate button presses are coalesced per `seriesId + seasonNumber` while a batch is active.
- Provider failures are represented only as sanitized aggregate counts and actionable messages.
- Closing Flutter does not cancel work already accepted by the backend/Bazarr.

## Tests

- A season request processes only imported episodes in the requested season.
- Episodes with Vietnamese subtitles are skipped.
- Missing episodes are searched and downloaded with bounded concurrency.
- The highest-scoring Vietnamese result is selected.
- Empty results increment `unavailable`; request failures increment `failed` without stopping other episodes.
- Concurrent duplicate requests share one in-flight batch.
- Flutter uses the season endpoint, shows aggregate progress, and refreshes `Vietsub x/y` after completion.
- Manual episode search remains available.
- Existing backend, controller, Flutter, Python, and Compose checks remain green.

## Out of scope

- Streaming from subtitle or torrent providers.
- Automatically replacing an existing Vietnamese subtitle.
- Whole-series searches spanning multiple seasons.
- Exposing provider login or API credentials to Flutter.
