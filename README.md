# Noty

Sticky notes that live at the edge of your screen. A native macOS app in Swift,
SwiftUI and AppKit.

No dock icon, no window to manage. Slide the pointer to the right edge and the
deck fans out.

**[noty-sepia.vercel.app](https://noty-sepia.vercel.app)** ·
**[Download the latest DMG](https://github.com/aimen08/noty/releases/latest/download/Noty.dmg)**

![Noty in use: the deck fans out from the screen edge, a checklist is pulled open, two tasks are ticked off, and the note is dismissed by clicking away](demo.gif)

| At rest | Fanned | A note pulled open |
|---|---|---|
| ![The deck at rest: a thin pill of coloured dashes on the screen edge](screenshots/rest.png) | ![The deck fanned into shingled paper tabs](screenshots/fan.png) | ![A note pulled clear of the deck, carrying its tab down the left side](screenshots/open.png) |

## Three states, one movement

| State | What you see | Trigger |
|---|---|---|
| **Rest** | A 12 pt pill on the screen edge — one coloured dash per note | idle |
| **Fan** | Notes shingle down the edge 45 ms apart as vertical tabs, each keeping its colour and carrying its label turned on its side | pointer enters the pill |
| **Expanded** | The note slides clear of the deck at full size, level with its own tab, which stays visible behind it | click a tab |

The deck shows **five notes at a time** and puts the rest behind a `+N` tab, which
opens the full list in a scrolling deck. A `+` button sits in the bottom corner
while the deck is open.

Tabs **shingle**: each one is full height but sits only a strip below the one
before, lapping over it like a roof tile. That is what keeps the deck to roughly
half the screen height instead of running its full length. The strip is sized to
the longest title currently on the deck, so labels read in full and ellipsise
cleanly rather than being clipped mid-word.

The fan is only 56 pt wide, so the deck covers almost none of what is behind it.

### Two deck styles

Right-click the pill → **Deck style**:

| | |
|---|---|
| **Labelled tabs** | Full-size tabs carrying their titles — the default |
| **Colour chips** | Colour only, no labels; the deck shrinks to a row of chips |

The open note carries its own tab along as a left gutter, separated by a dashed
rule, so it reads as growing out of the deck rather than floating beside it.

**Deck size** scales every metric off one multiplier — tab width, the lap between
tabs, the label type, the chips and the resting pill — so the deck grows without
drifting out of proportion with itself. Settings → Deck → *Size* (70–180%), or
right-click the pill → *Deck size* for the four presets.

**Keep deck open** makes the fan the resting state instead of the pill, so the
tabs and their labels stay on the edge without being hovered first. Off by
default; notes still open, close and idle away exactly as before.

## Shortcuts

All of these are listed in Settings (`⌘,`), and the first four can be rebound
there. Global ones are registered through the Carbon hotkey API, so **no
Accessibility permission is required**:

| | |
|---|---|
| `⌥⌘N` | new note (opens it straight away) |
| `⌥⌘A` | All Notes |
| `⌥⌘L` | the Archive window |

Inside a note:

| | |
|---|---|
| `Esc` | close the note, back to the tabs (or dismiss the find bar) |
| `⌘F` | find in note |
| `⌘.` | cycle its colour |
| `⌘T` | turn the current line into a task, or strip the checkbox off |
| `⌘⌫` | delete, with ten seconds to undo |
| `⇧⌘A` | archive the note you are looking at |
| — | every shortcut here can be rebound in Settings |
| `⌘P` | pin the note so it stays open |
| `⌃+` / `⌃-` | bigger / smaller note text |

Standard editing (`⌘C` / `⌘V` / `⌘Z` / `⌘A`) works everywhere — the app builds a
main menu at launch purely so those key equivalents dispatch, even though an
accessory app draws no menu bar.

## Checkbox tasks

Any line can be a task. `⌘T` (or the checklist button in a note's header) puts a
checkbox on the current line; **click the box to tick it off** and the line is
struck through and dimmed. Return carries the list on to the next task, and
Return on an empty task ends the list.

Tasks live inline in the note body as `☐` / `☑` prefixes, so a note stays plain
text. Markdown export writes them as standard `- [ ]` / `- [x]` task syntax and
import reads that back. All Notes shows a `done/total` count per note.

## Everything else

- **Archived, not deleted.** Archiving pulls a note out of the deck but keeps it
  in All Notes → Archive, restorable at any time.
- **All Notes** (`⌥⌘A`) — one window, search across every note body and title,
  with an editable detail pane.
- **Multi-display & relocation** — show the deck on all displays, only the main
  screen, or a specific monitor. Hold `⌥ Option` and drag the pill to dock it to
  any edge, height, or display. Displays are tracked by `CGDirectDisplayID`, so
  hot-plugging rebuilds the decks with graceful fallback.
- **Over full-screen apps** — right-click the pill → *Show over full-screen apps*.
  This raises the panel to `.statusBar` level; `.floating` alone does not draw
  over a full-screen space.
- **Autosave** 250 ms after you stop typing, and again on close.
- **Settings** (`⌘,`, the cog under the deck's `+`, or right-click the pill) —
  four tabs. *Shortcuts* rebinds all twelve. *Deck* covers style, size, which
  display carries it, the edge, how far from it the pointer wakes the deck, and
  whether the tabs stay out. *Notes* has the face, text size, note size and
  Markdown. *Updates* shows the version, when it last checked, and checks now.
  Everything applies immediately.
- **Open on hover.** Off by default: turn it on and resting the pointer on a tab
  opens that note without a click.
- **Tab preview on hover.** Rest on any tab to peek at a flyout card showing its title, checklist progress and content snippet without opening the full note.
- **Markdown as you type.** `# headings`, `**bold**`, `*italic*`, `` `code` ``,
  `~~struck~~`, `> quotes`, `- bullets` and `[links](https://example.com)` are
  styled in place. Markers are hidden on every line but the one the caret is on,
  which shows them dimmed so they can still be edited — the stored text is
  exactly what you typed and exports unchanged.
- **⌘-click a link to open it.** A plain click still places the caret, since a
  note is a thing you edit first. Only `http`, `https` and `mailto` are ever
  made clickable; anything else is styled and inert, so an imported note can
  never turn into a launcher.
- **Drag to reorder.** Drag a tab up or down and the others step aside to show
  where it will land.
- **Pin a note to keep it open.** The pin in a note's header (or `⌘P`) stops it
  being dismissed by anything you did not aim at it — clicking away in another
  app, or leaving it idle. Esc and Close still close it. Pinned tabs carry a dot,
  and the pin is remembered.
- **Closing a note steps back to the deck.** Esc, Close, archiving or deleting
  leaves the tabs where they were; only moving away from the edge puts the deck
  back to sleep. Clicking in another app dismisses the whole thing.
- **Tidies itself away.** A fan left untouched collapses after 4 seconds; an open
  note after a minute idle.
- **Export** — Markdown (one `.md` per note), plain text (one `.txt` per note),
  a single document, or a `.stickies` archive that preserves colours, archived
  state and dates. **Import** reads `.stickies` back, and will also take loose
  `.md` / `.txt` files.
- Right-click the pill for the full menu: new note, windows, edge side, launch at
  login, export, import, quit.

## Your notes stay on your Mac

- Local SQLite database in `~/Library/Application Support/Noty/`.
- **Note bodies are encrypted with AES-GCM** (CryptoKit, 256-bit). Titles,
  colours and timestamps stay in plaintext so lists render without unsealing
  every row.
- No account, no server, no analytics, no telemetry, no tracking SDKs.
- **One network request, ever:** Sparkle fetches the appcast to see whether a
  newer version exists. Nothing about your notes is sent — it is a plain GET of
  a public XML file. Turn it off with *Check automatically* in the pill's menu,
  and it never fires again.
- No Accessibility permission, no Screen Recording, no system permissions.

Verify it yourself:

```sh
sqlite3 ~/Library/Application\ Support/Noty/notes.db "SELECT hex(substr(body,1,24)) FROM notes;"
strings ~/Library/Application\ Support/Noty/notes.db | grep "some text from a note body"   # finds nothing
```

## Build

Requires the Swift toolchain from Command Line Tools (**Xcode is not needed**)
and macOS 15+.

```sh
./scripts/fetch-sparkle.sh   # once — pulls the Sparkle binary framework
./build.sh                   # release build → build/Noty.app
./build.sh debug             # fast, unoptimised
./build.sh release run       # build, then relaunch
./scripts/test-editor.sh     # focused editor range/style/input regression checks
open build/Noty.app
```

`build.sh` drives `swiftc` directly over `Sources/*.swift`, assembles the
`.app` bundle around `Info.plist`, embeds Sparkle, and signs it.

Sparkle is optional. Without `Sparkle/Sparkle.framework` the app still builds —
`Updater.swift` compiles to a stub and the update menu says so.

### Branches

`dev` is where work lands — every pull request targets it, and CI builds it.
`main` is the release branch: **merging `dev` into `main` is what cuts a
release**, so nothing reaches `main` until it has been tried.

### Releasing

```sh
git checkout main && git merge --no-ff dev -m "release: 1.2.0"
git push origin main
```

That fires `.github/workflows/release.yml`, which builds the app, packages a
DMG, signs it with the EdDSA key, writes `appcast.xml`, publishes a GitHub
Release and commits the appcast so installed copies can see the update.

The version comes from **`release: X.Y.Z`** anywhere in the merge commit
message. Leave it out and the patch is bumped from the newest tag, which is
what a hotfix wants. A version that is already tagged is a no-op, so re-running
the job is safe.

Release notes are written by `scripts/make-release-notes.sh` from the pull
requests the release actually contains — matched by whether their merge commit
is reachable, not by date, since work merged into `dev` sits unreleased until
`dev` lands. Every one of them is listed with a link and its author, on the
release page and in the Sparkle update dialog. Run it yourself to see what the
next release will say:

```sh
VERSION=1.2.0 ./scripts/make-release-notes.sh
```

Work that ships without a pull request of its own being merged — a cherry-pick,
or a branch only part of which was taken — is credited with a trailer on the
commit that takes it, which the same script turns into a **Thanks** section:

```
Thanks-to: @handle — what it was for
```

Documentation, the site, the media and the appcast are excluded from the
trigger, so a README push to `main` never cuts a release. `workflow_dispatch`
with a version is the manual escape hatch.

It needs one repository secret, **`SPARKLE_PRIVATE_KEY`** — the contents of the
key `scripts/fetch-sparkle.sh`'s toolchain generated. The matching public key is
already in `Info.plist` as `SUPublicEDKey`; an update signed by any other key is
refused by the installed app.

To build a DMG by hand:

```sh
./build.sh release && ./scripts/make-dmg.sh 1.0.1
```

**Signing note.** Sparkle ships signed by its own team, and dyld refuses to load
a framework whose Team ID differs from the process — so `build.sh` re-signs the
framework (innermost bundle first) with the same identity as the app. Set
`CODESIGN_IDENTITY` to use a Developer ID instead of an ad-hoc signature.

## Layout

```
Sources/
  Main.swift            @main entry point; NSApplication, accessory policy
  AppDelegate.swift     wiring, actions, main menu
  Core.swift            Paths, AES-GCM Crypto, colour palette, Note model
  Store.swift           SQLite (C API) — schema, load, upsert, delete
  NoteStore.swift       observable model; the single source of truth
  Settings.swift        UserDefaults prefs + launch-at-login
  HotKeys.swift         Carbon global shortcuts (no permissions)
  DeckPanel.swift       geometry, NSPanel subclass, tracking container
  DeckController.swift  one deck per display + the state machine
  DeckViews.swift       pill, fan, tabs, the 45 ms stagger
  NoteEditor.swift      NSTextView bridge, find, 250 ms autosave
  LibraryWindow.swift   All Notes / Archive
  ExportImport.swift    md / txt / single file / .stickies
  UndoToast.swift       the ten-second undo after a delete
```

Four details worth knowing if you touch the deck:

- A borderless `.nonactivatingPanel` returns `false` from `canBecomeKey`, so the
  expanded note silently refuses keystrokes unless it is overridden.
- Views default `acceptsFirstMouse` to `false`, so the first click on a tab is
  otherwise eaten to activate the panel instead of opening the note — which is
  the *normal* case, since you are always in another app when you reach for the deck.
- The shingle relies on **ZStack declaration order**, not `zIndex`. Adding an
  explicit `zIndex` per tab reordered neighbouring tabs and broke the lap.
- `rotationEffect` is a render transform, not a layout one: a rotated label still
  measures at its unrotated width, so anything sized around one has to be
  constrained and clipped separately or it bleeds across the note.

Set `NOTY_DEBUG_DECK=1` in the environment to trace deck state transitions on stderr.

## Differences from the original

- **Not sandboxed**, so data lives in `~/Library/Application Support/Noty/`
  rather than `~/Library/Containers/`. Sandboxing needs a provisioning profile,
  which needs Xcode and a developer account.
- The AES key is a `0600` file beside the database. The Keychain is the right
  home for it in a distributed build, but an ad-hoc signature changes on every
  rebuild, which makes the Keychain re-prompt or deny each time.
- `.stickies` here is Noty's own JSON archive format — the original's is opaque,
  so the two are not interchangeable. This one round-trips its own exports with
  full fidelity.
- No licensing, trial, or update machinery.
- Ad-hoc signed and not notarised, so Gatekeeper will want a right-click → Open
  the first time if the app is moved off this machine.

## Licence

MIT — see [LICENSE](LICENSE). Do what you like with it; keep the copyright
notice.

Noty bundles [Sparkle](https://github.com/sparkle-project/Sparkle) (also MIT)
for updates. Its notice is reproduced in
[licenses/THIRD-PARTY.txt](licenses/THIRD-PARTY.txt) and copied into
`Noty.app/Contents/Resources/`, so it travels with every DMG as its licence
requires.
