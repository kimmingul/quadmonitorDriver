# External archives and restoration

Immediately before converting to a product-focused repository, the entire project was copied to the location below. File contents, permissions, and symbolic links were verified to match. The copy includes original Git metadata and untracked files.

```text
/Users/min/Projects/quadmonitorDriver-backups/product-20260911-231636/
  project/                 # Complete project before reorganization
  manifest.json            # Original paths, SHA-256, permissions, and links
  verification.json        # Backup comparison results
  migration-map.json       # Previous and current paths of essential materials
  validation/              # Reorganization validation logs
```

Historical `research/runs/`, `research/packetlog/`, dated reports under `docs/`, handoff prompts, external-model responses, and old Python tools are available under `project/` at **their original paths**. Historical source references in the algorithm guide also refer to this archive. Local archive paths are not runtime dependencies.

The 0.2.0 recovery installer is at `project/build/archive/organization-20260911/QuadMonitor-0.2.0-arm64.pkg`. Older app backups from the preceding cleanup remain at their original paths under `/Users/min/Projects/quadmonitorDriver-backups/20260911-224742/project/`. Do not duplicate full backups inside the project.

To restore material, copy the required files to a new empty location and compare their hashes against the manifest. Do not overwrite the current working directory with the entire backup. The installed app and Application Support preferences are outside the project and outside this backup's scope. The current product build and essential tests must work without the external archives.

Git history is preserved. Cleanup did not use `git clean`, `reset --hard`, or history rewriting. Existing uncommitted product implementation requires separate review before committing.

## Backup before renaming the app source

`/Users/min/Projects/quadmonitorDriver-backups/rename-20260911-233805/` contains a verified `project/` copy of the entire working directory immediately before the rename, plus `manifest.json`. `rename.json` records the changes, `completion.json` records validation, and `release-check/build/` holds signed validation builds made after renaming. Those builds were not installed as the current release.

## Public repository boundary

The public GitHub repository starts with the current product source. Earlier local Git history, packet captures, extracted vendor executables, and `.mcp.json` are not published. That history remains in local archive branches and the full external backups; it was not rewritten or discarded.

The pre-release working directory and previous 0.3.0 build outputs are preserved at `/Users/min/Projects/quadmonitorDriver-backups/release-20260912-000459/` (`before/` and `previous-release/`). New signed-build, regression, sanitizer, and lifecycle evidence is in the same external directory.
