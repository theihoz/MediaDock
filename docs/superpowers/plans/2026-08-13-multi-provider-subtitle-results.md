# Multi-provider Subtitle Results Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display all enabled Bazarr providers and preserve each provider's usable Vietnamese or English fallback results.

**Architecture:** Correct provider-aware deduplication in the subtitle normalization layer, make the all-provider API include safe English fallback rows, then group results in Flutter while retaining single-provider behavior.

**Tech Stack:** Node.js ESM/node:test, Bazarr REST API, Flutter/Dart widget tests.

## Global Constraints

- Bazarr remains the single concurrent provider search coordinator.
- Automatic season downloads remain Vietnamese-only.
- Provider credentials and raw download URLs remain backend-only.
- Deduplication never crosses provider boundaries.

---

### Task 1: Provider-aware merge and fallback contract

**Files:**
- Modify: `backend/test/subtitle-providers.test.mjs`
- Modify: `backend/src/subtitle-providers.mjs`
- Modify: `backend/src/server.mjs`

**Interfaces:**
- Produces provider-aware `mergeSubtitleResults(groups)` and `bazarrResults(..., { includeEnglishFallback })` behavior.

- [ ] Write failing tests proving cross-provider rows survive, same-provider duplicates collapse, all-provider includes English fallback, and explicit provider remains language-strict.
- [ ] Run targeted Node tests and verify RED.
- [ ] Add provider/format/HI to the merge identity and mark fallback rows.
- [ ] Run targeted tests and verify GREEN.

### Task 2: Flutter provider groups

**Files:**
- Modify: `flutter_app/test/widget_test.dart`
- Modify: `flutter_app/lib/main.dart`

**Interfaces:**
- Consumes API rows containing `provider`, `language`, `fallback`, and `downloadToken`.
- Produces grouped provider headings, counts, fallback labels, and empty states.

- [ ] Write a failing widget test with OpenSubtitles Vietsub, Gestdown English fallback, YIFY result, and one empty provider.
- [ ] Run the focused widget test and verify RED.
- [ ] Group all-provider results in stable provider order and render each result independently.
- [ ] Run focused and full Flutter tests, analyze, and Windows build.

### Task 3: Runtime verification

**Files:** No production edits expected.

- [ ] Run full Node/controller tests and Compose validation.
- [ ] Rebuild only the API service and verify `/health` is `ready`.
- [ ] Query one real imported episode and confirm provider counts are preserved without printing URLs or credentials.
- [ ] Run GitNexus `detect_changes` and review affected flows.
