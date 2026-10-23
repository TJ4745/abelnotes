# Pages tray

Copy and move pages inside a notebook and across notebooks. One batch of
pages (the tray) follows the user through the library, the editor and the
page manager.

## Model

- Verbs are Copy and Move. Move is non-destructive: nothing leaves the
  source until the move is confirmed at the destination. Until then the pages
  stay in the source, dimmed with a "moving" tag.
- The tray holds one batch. A new Copy or Move replaces it silently. A copy
  tray survives pastes (paste it as often as you like); a move tray is
  consumed by the confirmed move.
- The tray is local to the device and never synced, but persisted so it
  survives a restart (`tray_store.dart`, below).
- Where the destination notebook has chapters, a chapter is mandatory: the
  chapter of the tapped page, changeable among the real chapters. Flat
  notebooks stay flat. Nothing is ever auto-created and the source chapter
  is never recreated (`page_transfer.dart`, `resolveChapter`).

## Layers

| File | Role |
| --- | --- |
| `domain/pages_tray.dart` | Immutable tray model (mode, source, pages, journal). |
| `domain/page_transfer.dart` | Pure planners: slot defaults, chapter resolution, insert, remove, in-notebook move. Used by the open canvas and by the headless editor, so both produce identical documents. |
| `data/tray_store.dart` | Disk persistence of the tray. |
| `data/closed_notebook_editor.dart` | Edits a notebook that is not open, on its loose store. |
| `application/pages_tray_provider.dart` | Controller: copy, move, confirm, cancel, undo, startup reconcile. |
| `presentation/` | Tray pill, destination card, toasts, notebook chooser. |

## Persistence

`<app support dir>/pages_tray/`, outside the notebook store and never
uploaded:

```
tray.json        manifest: id, mode, source ids/titles, entries, journal
pages/<n>.json   page data, same compact codec as the loose store
assets/<id>      bytes of every asset the pages reference
thumbs/<n>.png   the (up to 3) previews of the pill
```

The directory is written whole under a temporary name and renamed into
place, so a crash never leaves a half tray. Clearing moves it to a
`graveyard` sibling that is deleted after the undo window (and at the next
start). The cap is 200 pages per tray; beyond that Copy/Move refuse and say
so. The pill only shows "Saved on this device" once the write finished.

## Cross-notebook move (the hard part)

The app holds one notebook open. Confirming a move into notebook B while
notebook A is the source:

1. Write the journal (`pending`: destination id + the new page ids) into
   `tray.json`.
2. Insert into B. If B is open, `CanvasNotifier.pastePages` and then
   `saveNow()`, which forces the local save and returns only when the loose
   store is on disk. If B is closed (library card menu), the headless
   editor does the same insertion on B's loose store.
3. Verify from disk that B's `document.json` lists the new page ids and
   their files exist. If not, roll the insertion back and stop: nothing was
   removed from A, the tray is intact.
4. Remove the pages from A with the headless editor (A is never open then).
5. Clear the tray (to the graveyard), record the undo, toast.

Invariants:

- (a) Destination is saved first (steps 2-3), the source edited after (4).
- (b) A failed source edit leaves the pages in A. B has them too, so the
  tray becomes a copy of them and the user is told. Nothing is lost.
- (c) A crash between 3 and 5 leaves the pages in both notebooks. At the
  next start the journal is reconciled: if B's document has all the new
  ids, the removal from A is finished and the tray cleared; if it has none,
  the journal is dropped and the move is still pending.
- (d) The headless edit goes through the same persistence and sync marking
  as a closed notebook with unpushed edits (see below), so A's removal and
  B's additions reach the server.
- (e) Pasted pages carry their asset bytes; they are materialised in B's
  store exactly as `pastePages` always did.

### Headless edit and sync

`closed_notebook_editor.dart` writes `metadata.json`, then `document.json`,
then deletes page files (the order `saveNotebookIncremental` already uses),
all under the per-notebook store lock. It then does what a failed upload of
a closed notebook does (see `notebook_provider._pushUnpushed`):

- `dirty_pages` gets `doc` and, for insertions, each new page file and
  `asset:<id>`;
- `pending_page_deletes_<id>` gets the deleted page file names;
- `unpushed_base_doc_<id>` / `_meta_<id>` keep the pre-edit document and
  metadata as the 3-way merge baseline, unless an older baseline exists;
- the DB row is marked modified and its page count updated.

The library's pending-upload retry then pushes it when the server did not
move meanwhile; otherwise the editor merges on the next open, as for any
unpushed notebook. The source's page count, `chapters[].pageIds`, thumbnail
and library card are refreshed. A notebook that is open in the editor is
refused (the editor owns it).

If every page of the source is moved, the source keeps one blank page (a
notebook never has zero pages). Assets that only the moved pages used stay
in the source until its next page deletion prunes orphans; that costs space,
never data.

After a headless edit the controller asks the library to push pending
uploads at once instead of waiting for its next tick. A closed notebook this
device never opened or synced has no server baseline (`delta_meta_etag_<id>`),
so its edit stays local, shows the library's "not uploaded yet" notice and goes
up the first time the notebook is opened (the editor merges and pushes). A
failed headless write takes its `dirty_pages` pre-mark back.

## Delete and Duplicate

Delete keeps its confirmation. Pages deleted from the notebook a move comes
from also leave the tray (`pagesDeleted`), so a move cannot bring back what the
user deleted. Duplicate puts each copy right after its original, keeps its
chapter, and has the same Undo as a paste.

## Undo

The editor's undo is per page and cannot revert page structure, so the
toast Undo is explicit. The toast has no countdown bar; it goes on the next
screen change or canvas edit, or after 10 s without the pointer over it. It reverts the destination by page id (never a whole
snapshot, so edits made meanwhile survive), re-inserts the moved pages into
the source at their old position with their old ids, and restores the tray
from the graveyard.

## Source deleted

`onNotebookDeleted` turns a pending move into a copy with the note "was
deleted, these pages are now a copy". The same check runs at startup and
before a paste.
