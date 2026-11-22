# The persisted chat data model

Answers the three questions in the FTS session's handoff (`docs/DATA_MODEL_INVESTIGATION.md`, 2026-08-26 — it lives on
`feat/fts-chat-search`, not on main): whether `sourcesJSON` belongs on the message, where orphans come from, and
what the model actually looks like. Diagram: `docs/data-model.html`.

**Current as of 2026-08-31.** The investigation was drafted against a pre-2026-08-30 tree. Three of
its premises have since changed on main and the text below reflects the tree, not the draft:
`SavedPlace` was excised (`ee7f375`), the per-thread orphan bug was fixed (`ThreadDeletion`), and the
container no longer `fatalError`s on an unmigratable store. **Q1 is the one thing still open.**

## The shape

`Schema(versionedSchema: TeemoonSchemaV1.self)` — `[Thread, Message]`, opened in `teemoonApp.swift`
through `TeemoonMigrationPlan`. Two tables, one relationship.

| | |
|---|---|
| `Thread` (`ChatModels.swift:57`) | `id`, `title` (**dead in production** — written only by `UITestStoreSeeding`), `timestamp`, `@Relationship var messages` |
| `Message` (`ChatModels.swift:18`) | `id`, `role`, `content`, `timestamp`, `generatingTime?`, `sourcesJSON?`, `isE2EE`, `thread?` |

**`Thread.messages` carries no delete rule** (`ChatModels.swift:62`), so SwiftData's default
`.nullify` applies at the store layer: deleting a thread cuts the edge and leaves the messages on
disk with `thread == nil`. That is unchanged and deliberate — the cascade lives one level up, in
`ThreadDeletion` (see Q2). `DataModelTests` pins both the raw `.nullify` behaviour and the
application-level cascade, so a future editor cannot "simplify" either into the other.

A store written by a build older than `ee7f375` still carries a `ZSAVEDPLACE` table on disk with no
model behind it. `store_shape.py` reads it when it is there (`savedPlaces.danglingThreadID`) and
skips it when it is not; that conditional is why the tool runs against both old and new stores.

## Q1 — does `sourcesJSON` belong on the message? **(open)**

**The relationship is right. The payload is wrong.** Citations are message-scoped
provenance; they belong to the reply that made them. What does not belong is *what* is
being stored in that column.

The write path, end to end:

1. Brave returns up to **10 pages per search** (`GroundingBudget.urlCap`, `BraveWebSearchTool.swift:189`).
2. Every search round in a turn **accumulates** into one array — `groundingSources.append(contentsOf:)`,
   `ChatGeneration+Stream.swift:26`. Three searches in a turn is thirty entries.
3. Each entry's `snippet` is **every passage for that page, joined** — the same
   `snippets.joined(separator: " […] ")` text handed to the model as context
   (`BraveWebSearchTool.swift:640`).
4. `citedOrAll` (`BraveWebSearchTool.swift:669`) keeps the cited links — **and falls back to
   *all* grounding sources when the model cited nothing.** The turns that ground the least
   store the most.
5. `ChatViewModel.swift:224-227` encodes the lot into the column.

Now the read path. **Nothing ever reads more than about two lines of it:**

- `GroundingSourcesView.swift:77-81` renders `displaySnippet` at `.lineLimit(2)`, 13.5pt —
  roughly 100–140 characters, and that is the ceiling, not the default.
- `displaySnippet` returns `""` outright for structured data (`BraveWebSearchTool.swift:32-34`).
  Snippets that arrived as JSON-LD are stored forever and shown **never**.
- Chat search (FTS5) indexes `content` only. Truncating costs **no** recall.
- The last-request card reads the *live tool result*, not the persisted message
  (`sourcesJSONString(tc.result)`, `RequestDebugView.swift:103` / `:332`).

So the column is write-only after the turn ends, and it is sized for a reader that does not
exist. The model consumed the full passage at generation time; that context is already gone.

**Recommendation, in order — neither has been implemented:**

1. **Cap the snippet at write time** — one clamp in `citedOrAll` or `encodedJSON`, ~300 bytes,
   comfortably above what two lines can show. `sourcesJSON` is a plain `String?`; writing
   shorter strings is **not a schema change and needs no new `VersionedSchema`**. It only affects
   new messages — old rows keep their bulk until something compacts them.
2. **Do not build a shared `Source` @Model on speculation.** Adding a new `@Model` is a
   lightweight-stage change per `CLAUDE.md`, but the payoff is entirely the duplicate-citation
   rate, and nobody has measured it. `store_shape.py` reports it directly (`sources.dedup.savedPct`).
   Measure first — and note that step 1 shrinks the column by roughly an order of magnitude,
   which likely retires this option rather than informing it.

### The numbers

The handoff's figures — **93 MB of a 234 MB store, 7.7× the 12 MB of message text** — came
from a backup, via a session whose transcript was deleted. They are the best evidence we have
and they are stale: the live device store was 117.8 MB at last look. **Re-derive before acting.**

`tools/store_shape.py` is the instrument, and it is built so the re-derivation does not cost
anyone's privacy: every value it emits is a number, and `assert_numeric_only` enforces that on
the way out rather than trusting the author. It answers all of Q1 and Q2 in one pass —
`bytes.sourcesOverContent`, `sources.snippetShareOfSources`, `sources.dedup`, `orphans.*`.

```
tools/store_shape.py /path/to/default.store
tools/store_shape.py /path/to/default.store --shapes teemoon/thread_shapes.json
```

The `--shapes` mode is the handoff's "extend the shapes exporter" item: it regenerates
`thread_shapes.json` with `sourcesBytes` and `sourceCount` added per message. The Swift
seeder ignores keys it does not know, so an older build still loads the file.

**This has not been run against the real store.** It lives on the phone, and pulling a copy of
the maintainer's conversations off the device is his call, not a thing to do quietly. The tool is
verified end-to-end against a real SwiftData store file (schema, history tables, the lot) and
by 14 unit tests including a deliberate leak that the guard catches (`tools/test_store_shape.py`).

## Q2 — where orphans came from **(fixed)**

**Thread deletion was the only source**, and the two delete paths disagreed about it. The bulk
path swept messages a second time; the per-thread swipe deleted the `Thread` alone and nullified
every message in it into an invisible row. That asymmetry was the bug, and 266 single-message runs
among the reference store's 330 is what it looked like from the data side: abandoned one-message
threads, swiped away one at a time.

`ThreadDeletion` (`teemoon/Chat/ThreadDeletion.swift`) now owns both paths:

| path | what it deletes | orphans |
|---|---|---|
| `ChatsListView.deleteThread:417` | `ThreadDeletion.delete` — messages, then the thread | no |
| `ChatsSettingsView.deleteChats:60` | `ThreadDeletion.deleteAll` — `Thread.self`, then `Message.self` | no |
| `ChatViewModel` retry truncation (`:147`) | each `Message` directly | no |

The cascade is application-level on purpose. Switching `@Relationship` to `.cascade` reaches the
same behaviour through `CLAUDE.md`'s "ask first" door, for no benefit — **do not.**

**The existing orphan backlog is a separate decision and it is the maintainer's.** Those rows are
unreachable from any UI, excluded from the search index by design, and cost disk. They cannot be
re-parented: the nullify already destroyed the only link, and there is no `threadID` left on the
message to reattach *to*. So the real choice is **leave them** or **sweep them**, sweeping is
destructive and irreversible, and it should be made against a fresh count from `store_shape.py`,
not the stale 915.

## Where the store lives (1.1.0)

**The store is `Application Support/default.store` in the app's own container**, where 1.0.6 kept it
(`StoreLocation`, opened from `teemoonApp.swift`). The URL is passed explicitly. With
`ModelConfiguration(schema:)` alone, SwiftData follows the first App Group in the entitlements. 1.1.0
added `group.<bundle id>` for the share extension. So build 61 copied every chat into the group container on
its first launch and left the 1.0.6 file behind, out of reach of every later delete (audit LOW,
2026-11-15). The share extension never opens this store. The App Group holds only the share inbox
(`docs/SHARE_IN.md`).

A build-61 install has its live chats in the group's `Library/Application Support/default.store`. On the
first launch of a later build, that store moves back to the app container once (the maintainer, 2026-11-15, "Pin, with
pm's 2 fixes"). The 1.0.6 path (the public update) has no group store, so nothing moves.

Names used below, all in the app container's `Application Support` unless noted:
- **data**: `default.store`.
- **group**: `default.store` in the App Group's `Library/Application Support`.
- **old**: the folder `StoreMove/old`. It holds the 1.0.6 set and `expected.json`, the group store's row counts.
- **incoming**: the folder `StoreMove/incoming`. It is the group's whole `Library/Application Support` folder,
  renamed in one step.
- **rollback**: the marker file `StoreMove/rollback`.

A *set* is a store and everything beside it: `-wal`, `-shm`, the `.default_SUPPORT` folder (image bytes)
and `chat-search-index.sqlite*`. A set moves file by file with `default.store` LAST, so no store is ever opened
without its `-wal`. A rollback moves `default.store` FIRST. Before anything moves, every destination is checked.
A `-shm` or search-index file in the way is a cache and is replaced. Any other conflict fails before a file
moves. *Counts* are the rows of `ZTHREAD`, `ZMESSAGE` and `ZIMAGEATTACHMENT`, read without writing and with no
integrity scan, which would read the whole file at launch. *Doubt* is an unreadable store, different counts, or
a failed move.

Every launch matches the files on disk against this table; the first matching row wins (`any` matches both).
`StoreLocationTableTests` reads this table and checks every one of the 32 combinations against
`StoreLocation.action`, then kills each row's work at every step and launches again.

| row | data | group | old | incoming | rollback | action |
|---|---|---|---|---|---|---|
| 1 | any | any | any | any | yes | rollBack |
| 2 | any | yes | any | yes | no | openGroupInPlace |
| 3 | any | no | any | yes | no | resumeIncoming |
| 4 | any | yes | yes | no | no | resumeOld |
| 5 | any | yes | no | no | no | move |
| 6 | yes | no | yes | no | no | finish |
| 7 | no | no | yes | no | no | restoreOld |
| 8 | yes | no | no | no | no | openData |
| 9 | no | no | no | no | no | openData |

- **move**: read the group store's counts. Doubt means open the group store in place and touch nothing. Otherwise
  write `old/expected.json` (rewritten on every resume, because the group store in place is the truth), move the data set into old, rename the group folder to incoming, move incoming's
  files into the app container, then finish. A 61 phone with no 1.0.6 store has an old folder holding only
  `expected.json`.
- **resumeOld** (killed while the data set was moving into old): the group store is untouched. Write
  `expected.json` if it is missing, move the rest of the data set into old, then continue as in move.
- **resumeIncoming** (killed while incoming was moving in): move the rest of incoming in, remove it, then finish.
- **finish** (killed after the move, before old was deleted): compare the data store's counts with
  `expected.json`. If they are equal, delete old. If both are readable and they differ, roll back. If either is
  missing or unreadable (for example a locked relaunch), open the data store, keep old, and finish on a later
  launch. It never restores the 1.0.6 set while the moved store is complete.
- **rollBack** (doubt after the move, or a kill during one):
  1. Write the marker.
  2. Move the data set into incoming.
  3. Rename incoming back to the group folder.
  4. Move old's 1.0.6 set back into the app container.
  5. Remove old, then the marker.
  6. Open the group store in place. The next launch tries the move again.
  If a rollback fails halfway, no store is opened from disk. The app runs in memory with the store banner and
  every file is kept: a store away from its `-wal` would show fewer chats.
  A 61 phone never shows the 1.0.6 chats in place of its live ones, and nothing is deleted while in doubt.
- **openGroupInPlace**: open the group store where it is, for this launch only. Nothing moves and nothing is
  deleted.
- **restoreOld** (no live store anywhere, only old; not reachable by the steps above): move old's set back
  and open it. If the set can't move back, open it inside old. Nothing is deleted.
- **openData**: the normal launch. A first launch creates the store here. Group sidecars with no group store
  beside them are deleted: they are search-index caches and `-shm` files of a store that has moved.

Accepted limit: a build with no App Group container (a provisioning break) sees no group store, so a 61 phone
would open its stale 1.0.6 copy. That build would also break sharing, so it is a release blocker anyway.

Launch cost: the table needs four existence checks and one `contentsOfDirectory`. Only a build-61 install
reads counts, once, which takes milliseconds.

## Constraints on any of this

The store is opened under `TeemoonMigrationPlan` (`teemoon/Chat/SchemaVersioning.swift`, adopted
2026-08-30). An open failure is no longer fatal: the store file stays untouched on disk, the app
boots on an empty in-memory container, and ContentView shows a banner
(`TeemoonApp.storeOpenFailure`). That is a net, not a licence — every schema change is still a new
`VersionedSchema` plus an explicit `MigrationStage`, and V1 is frozen.

Nothing recommended above touches the schema: the snippet cap writes shorter strings into an
existing column. The store is `isExcludedFromBackup` and there is still no export, so the in-app
store remains the only copy of the user's history.
