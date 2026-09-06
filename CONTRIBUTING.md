# Working on Remit

## Day-to-day loop

```
./run.sh              build debug, wrap in a .app, relaunch
swift test            run the test suite
swift build           compile only
```

`run.sh` exists because a bare SwiftPM executable has no bundle, and macOS grants Reminders
access to a *bundle identity*. Running `.build/debug/Remit` directly means the permission is
attributed to your terminal, and the grant evaporates on the next rebuild. Always use `run.sh`.

Once `/Applications/Remit.app` exists, `run.sh` keeps it in sync automatically — otherwise you
end up testing a stale installed copy while the fix sits in `.build`, which looks exactly like a
fix that didn't work.

## Branching

`main` is what CI builds and what releases are cut from. Work on a branch, merge when green:

```
git checkout -b feature/board-drag-and-drop
# ...work...
swift test
git checkout main && git merge --no-ff feature/board-drag-and-drop
```

## Cutting a release

Tagging *is* the release trigger. There is no separate publish step.

```
swift test                     # must pass; CI runs it again anyway
git tag v0.2.0
git push origin main --tags
```

`.github/workflows/release.yml` then builds the DMG on a macOS runner and attaches it to a
GitHub Release. To build one locally instead:

```
./release.sh 0.2.0             # -> dist/Remit-0.2.0.dmg
./release.sh 0.2.0 --install   # also installs to /Applications
```

Versions: the marketing version comes from the tag. `CFBundleVersion` is the commit count, so it
increases monotonically — required by macOS's "a newer version is already installed" check and by
Sparkle later.

## Signing and notarization

**Current state: ad-hoc signed, not notarized.** The app runs fine on the machine that built it.
Any machine that *downloads* it will have Gatekeeper refuse to open it (`spctl` reports
`rejected`) until the user right-clicks → Open, or runs:

```
xattr -dr com.apple.quarantine /Applications/Remit.app
```

To fix this properly you need a paid Apple Developer ID ($99/yr). Once you have one,
`release.sh` picks it up automatically — it greps for a "Developer ID Application" identity and
switches to a hardened-runtime, timestamped signature with no code change. Notarization is then
two commands, printed by the script:

```
xcrun notarytool submit dist/Remit-0.2.0.dmg --keychain-profile <profile> --wait
xcrun stapler staple dist/Remit-0.2.0.dmg
```

## Where your data lives

Remit is a *view* over Apple Reminders. It has never stored a task or a list.

| What | Where | Losing it costs you |
|---|---|---|
| Tasks, lists, due dates, priorities, tags | Apple Reminders (EventKit) | Nothing Remit can cause — it's Apple's database, synced via iCloud |
| Sections, labels, saved filters, templates, project emoji, nesting, favourites | `~/Library/Application Support/Remit/metadata.json` | Only the Remit decoration layer |
| Per-view layout, sort, grouping, filters | `UserDefaults` (`com.nitesh.remit`) | View preferences only |

### Backing up the metadata layer

```
cp ~/Library/Application\ Support/Remit/metadata.json ~/Desktop/remit-backup.json
```

Remit maintains its own safety net too:

- Every write rolls the previous file into `metadata.backup.json` first, so there is never a
  moment with zero readable copies on disk.
- A file that won't decode is **moved aside** as `metadata.corrupt-<timestamp>.json`, never
  overwritten, and the last good backup is restored automatically.
- Anything unusual is reported in a banner at the top of the window rather than swallowed.

### The failure this replaced

Swift's synthesised `Codable` initialiser throws `keyNotFound` on a missing key *even when the
property has a default value*. The original loader decoded with `try?` and fell back to an empty
store on failure — and since every mutation calls `persist()`, a file written by an older build
would fail to decode, load as empty, and be overwritten by the next favourite toggle.

`labels`, `labelAssignments`, `templates` and `filters` were all added after v0.1, so this was
one field away from wiping the metadata layer. `RemitMetadata` now decodes field by field with
`decodeIfPresent`, which means **adding a field is safe** — older files still load.

If you add a field to `RemitMetadata`, add it to `CodingKeys` and to `init(from:)` with a
default. Only bump `schemaVersion` when a field changes *meaning*; additions don't need it.
`Tests/RemitTests/MetadataStoreTests.swift` covers all of this — keep it passing.
