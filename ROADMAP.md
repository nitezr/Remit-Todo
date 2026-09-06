# Remit — Native Rebuild Roadmap

Distilled from `REMITPROMPTS.md` (79 prompts, 2026-08-27 → 2026-08-31, building the Glaze/Electron
version). Later entries supersede earlier ones where they conflict; this list already resolves
those conflicts. Prompt numbers in `(#N)` trace back to the original log for context.

Screenshots referenced throughout the original build live in `design-references/` (copied out of
the Glaze project — match these pixel-for-pixel where a prompt says "make it look like this").

## Original concept

> A task management app that combines Apple Reminders' reliable backend with Todoist's
> intuitive navigation, keyboard shortcuts, and view options.

Backend: Apple Reminders via EventKit. Interface: Todoist. Nothing here changes that brief —
only the implementation (native SwiftUI instead of Electron/Glaze).

---

## P0 — Core loop (must work before anything else)

- [ ] EventKit read/write: Reminders lists = Projects, reminders = Tasks (#27 confirms Apple
      Tags map to Labels — see Labels section)
- [ ] Today / Inbox / Upcoming views actually load and show correct counts — the Electron build
      had a recurring bug here (#2 "Today is not loading", #79 "2 task vs 17 tasks in Today,
      something wrong... Apple reminders show 19 task"). Get the EKReminder due-date/predicate
      logic right the first time; this bit them twice, 4 days apart.
- [ ] Quick add with natural-language parsing: `Pay rent tomorrow p1 #Home @bills` sets due
      date, priority, project, label in one line
- [ ] Task completion: checkbox, strike-through, then removal — with a completion sound and a
      brief animation (#4 — "no animation... at least a completion sound and a little animation")
- [ ] Arrow-key / J-K navigation between tasks that never skips items — this broke twice in the
      Electron build (#6, #50) after working correctly at least once (#51); test explicitly after
      any list-diffing or virtualization change

## P1 — Todoist-parity views & layout

- [ ] Every view (Today, Upcoming, a Project) supports three layouts: **List**, **Board**
      (kanban), **Calendar** (month grid) (#3, #15, #26)
- [ ] Upcoming Board: task cards, moving a task from Tomorrow to Today visibly moves it to the
      Today column instead of disappearing (#7 was a real bug — verify the board's date-bucket
      recompute happens on every drop, not just on reload)
- [ ] Upcoming List: only the section under the cursor (Overdue / Today / Tomorrow) scrolls, not
      the whole page; no visible boundary line between sections — only individual task cards
      have borders, matching Todoist exactly (#20)
- [ ] Sleeping-hours hide toggle: default hide 10PM–8AM on time-based views, user-configurable
      (#10)
- [ ] Task row: line 1 = title, line 2 = notes/description in a smaller, lower-contrast font — no
      panel auto-opens on click (#4); clicking instead opens a small **mini detail window**
      (peek), available from List, Board, and Calendar alike (#47)
- [ ] Project color-coding is visibly distinct per project on every task row (#4 — in the
      Electron build "all the projects seem to be the same color")
- [ ] Card design in Board view matches the reference screenshots exactly — borders, spacing,
      metadata layout (#14, #23)
- [ ] Font choices match Todoist's (#12) — this was called out as "what makes Todoist
      attractive"; treat typography as a first-class design decision, not a default
- [ ] Dark mode matches Todoist's dark theme, not a generic system-dark palette (#24)
- [ ] "Display" / view-options control (sort, group, filter) available consistently across every
      view, not just some (#15, #26)

## P1 — Sidebar & navigation

- [ ] Sidebar visually matches Todoist — this took ~6 rounds of "still not professional enough"
      in the Electron build (#13, #22, #40, #43, #45); treat spacing, icon weight, and hierarchy
      as needing explicit design passes, not a first-guess implementation
- [ ] Projects can nest (sub-projects) and show a live task count (#17)
- [ ] All projects live under a collapsible "My Projects" section, matching a to-do-list-style
      collapse icon (#34)
- [ ] **Favorites** section pinned above My Projects — projects, filters, or labels can be
      favorited (#28, #44, #46)
- [x] Settings gear icon accessible from the sidebar itself, icon-only (#38)
- [ ] Sidebar can be hidden/shown with **⌘S**, and the toggle must actually persist and the
      keyboard shortcut must actually fire — both regressed at least once in the Electron build
      (#76, #77, #78) — write a test/manual-check step for this specifically
- [ ] Help/keyboard-shortcut panel must not cover the project list when both are visible while
      scrolling (#35 was a real layout bug — a sticky panel ate the project list's scroll space)

## P1 — Sections

- [ ] Sections within a project, Todoist-style, independent of whether Reminders has any native
      concept of sections — this is a Remit-only layer on top of EventKit, same as the Electron
      build (#9)
- [ ] Sections and their tasks render as cards matching the reference screenshot (#14)
- [ ] Drag-and-drop reorder: sections left/right and above/below within a project (#75); this
      broke at least once in the Electron build after project-level drag-and-drop was fixed —
      test section reordering separately from project reordering
- [ ] "Add task" affordance appears inline **at the end of each section's task list**, not
      floating between the section header and its first task (#71, #72, #73 — this was corrected
      twice; the wrong placement was explicitly called "so out of place")

## P1 — Labels & filters

- [x] Labels are a **Remit-only** concept, stored in MetadataStore alongside sections and project
      nesting. This supersedes the original #27/#32 plan of mapping them to Apple Tags, which was
      tested on 2026-08-31 and is not possible: `EKReminder` exposes no tags property and is not
      even KVC-compliant for the key, the Reminders AppleScript dictionary has no tag property,
      and a reminder created via EventKit with "#bills" in its title stays plain text in
      Reminders.app rather than being promoted to a tag. Apple ships no public API for Reminders
      tags on any surface. Consequence: labels do not sync to iPhone and are invisible in
      Reminders.app. Do not re-attempt this.
- [x] Filters are built from scratch in Remit (Reminders has no native filter concept) (#27) --
      saved from any view's Display menu, listed with their criteria on the Filters & Labels page
- [ ] Group-by-Label option in view options (#70)
- [x] Label picker/list is legible — the Electron build shipped a label section the user
      couldn't even read (#42); treat contrast/sizing as a real requirement, not a detail

## P1 — Drag-and-drop (full scope)

- [ ] Tasks: reorder within a list, between board columns/days, between sections (#21, #7)
- [ ] Projects: reorder above/below, not just nest under one another — this was a real,
      reported-twice bug in the Electron build (#58, #60)
- [ ] Sections: reorder left/right, above/below (#75)

## P1 — Keyboard & command palette

- [ ] ⌘K command palette: search tasks and general app actions (#19)
- [ ] Full Todoist-equivalent shortcut set, minimum: task complete, set due today/tomorrow,
      priority 1–4, quick add, search, go-to-view, undo, delete (#63, #64, #65)
- [ ] `T`/`U`/`W`/`N` = today/tomorrow/weekend/next week; confirm `U` specifically maps to
      tomorrow (#66 asked for this explicitly)
- [ ] `#` while typing a task recommends projects/lists; `@` recommends labels — both were
      reported broken/missing in the Electron build (#68, #69) — get autocomplete triggers right
      the first time
- [ ] Search accessible from the quick-add/command surface too, not only ⌘K (#67)
- [x] All shortcuts remappable from a dedicated **Settings → Shortcuts** panel inside a
      multi-tab settings window (#74); this must be a real, working panel — a `⌘S` sidebar
      toggle was requested, "added," and reported broken twice before it actually worked (#76–78)

## P2 — Templates

- [ ] Save a project's structure (sections, default labels) as a template; create new projects
      from a template or from scratch (#29, #34)

## P2 — First-run & account lifecycle

- [ ] First launch: explicit "Connect to Apple Reminders" step with the system permission
      prompt, not a silent background request (#41)
- [ ] A "disconnect from Reminders / start fresh" option in Settings, for wiping the Remit-layer
      metadata without touching Reminders data itself (#36)
- [ ] Ability to delete a project such that it actually disappears from Reminders too, not just
      from Remit's view (#34)

## P2 — MCP / automation integration

- [ ] Optional MCP server so AI agents (Claude Cowork, etc.) can read/write tasks — this already
      exists in the Electron build (`@modelcontextprotocol/sdk`) and needs a native-Swift or
      companion-process equivalent
- [ ] Settings panel with explicit MCP opt-in and connection status, discoverable — in the
      Electron build this setting was requested three separate times because it kept not
      shipping or not being visible (#18, #30, #36, #39)
- [ ] Optional ngrok tunnel for remote access to the MCP server, token stored in the system
      keychain, never in the repo (matches the existing README's stated security model)

## Known traps from the last build (don't repeat these)

- Today/Upcoming task counts silently diverging from what Reminders.app itself shows (#2, #79) —
  write the "what counts as due today" predicate once, test it against real data, and reuse it
  everywhere rather than recomputing it per view
- Arrow-key navigation skipping list items after any change to list rendering (#6, #50)
- Drag-and-drop for one entity type (tasks) working while a structurally similar one (projects,
  sections) silently doesn't (#58, #60, #75)
- A feature reported as "added" that turns out not to be wired to its keyboard shortcut, or to
  regress on a later change (#76, #77, #78 — the ⌘S sidebar toggle round-tripped three times)
- Settings that exist in code but aren't reachable/visible in the UI (#18, #30, #36, #39 — MCP
  settings specifically)

## Explicitly out of scope for v1

- Kanban/Calendar/Board polish beyond matching the reference screenshots — ship List view fully
  first, then Board, then Calendar (the original build did all three in parallel and that's
  partly why sections regressed repeatedly)
- Template marketplace / sharing templates with other people — just local save/apply for now
