# FFXITrusts

A Windower 4 addon for managing **named trust party loadouts** with a
GSUI-style window. Save the current trust party, name it, and resummon
the whole set with one click.

## Install

```
cd path\to\Windower4\addons
git clone https://github.com/mullerdane85-hash/FFXITrusts.git
```

Then in-game:

```
//lua load FFXITrusts
```

To autoload every session, add `lua load FFXITrusts` to
`scripts\init.txt`.

## Window

Press the **T key** (with chat closed) to toggle the window, or run
`//ft`. The layout has two panels:

- **Left** — list of your saved sets. Hover to preview members on the
  right; click to call that set.
- **Right** — members of the currently hovered (or active) set.
- **Bottom (green)** — "+ Save Current Party" snapshots the trusts you
  have summoned right now and prompts you to name the set.
- **Bottom (red, while summoning)** — "STOP (i/N)" cancels the queue.

Drag the title bar to move the window. Mouse-wheel scrolls the sets
list when you have more than fits on screen.

## Commands

| Command | What |
|---|---|
| `//ft` | Toggle the window |
| `//ft save [<name>]` | Capture party. With name = save immediately. Without = staged save (then `//ft savename <name>` to commit). |
| `//ft savename <name>` | Commit a staged save |
| `//ft cancel` | Discard a staged save |
| `//ft call <name>` | Summon a saved set |
| `//ft stop` | Cancel the in-progress summon queue. *(Any cast already in flight will still finish.)* |
| `//ft delete <name>` | Remove a set |
| `//ft rename <old> <new>` | Rename a set |
| `//ft edit <set> <slot#> <name>` | Fix one member name (e.g. add `(UC)` suffix that the party display drops) |
| `//ft list` | Print all saved set names to chat |
| `//ft delay <seconds>` | Time between casts in the queue (default `3.0`) |
| `//ft prefix off` / `//ft prefix Trust:` | Spell-name prefix. Retail uses bare names; some private servers use `Trust:` |
| `//ft pos <x> <y>` | Move window programmatically |

## Queue behavior

The summon queue uses a **fixed time delay** between `/ma` commands —
default 3 seconds, runtime-tunable via `//ft delay` **or via the
`Delay: X.Xs [-] [+]` stepper in the window's header bar** (same UI
pattern as FFXISpammer's TP toggle, clamped 1.0–10.0s in 0.5s steps).
The addon does NOT listen for spell-finish events anymore; the delay
is the cadence.

Before the queue even starts, the set is **filtered against your current
party** — any trust already slotted is dropped so we don't waste 3 seconds
per redundant `/ma` (FFXI silently bounces those anyway). Name aliases
("Semih Lafihna" vs "SemihLafihna", "Shantotto" vs "Shantotto II") all
resolve to spell-ID candidates from the resource table, so it doesn't
matter which form your set was saved in. If every trust in the set is
already in your party you get a friendly "nothing to summon" line and
the queue doesn't run.

Two safety checks then fire before each `/ma` that does go out:

1. **Unowned-trust check.** If the spell isn't in your spell book
   (e.g. a `(UC)` trust you never unlocked), the queue prints
   `skip "<name>" (not learned)` and advances immediately. No wasted
   cast attempts.
2. **Castable-state check.** If you're event-locked, on chocobo,
   mounted, dead, or otherwise non-castable, the queue defers by 0.5s
   and re-checks. Won't burn `/ma` commands into a brick wall.

## Gotchas

These bit during development; documented so they don't bite again.

### `chat_open`, not `chatopen`

`windower.ffxi.get_info().chat_open` — with underscore. The lookalike
`chatopen` silently returns nil, so the T-key bind fires while you're
typing in chat.

### `empty` global vs string "empty"

`equip({sub = empty})` uses GearSwap's `empty` global. `equip({sub =
"empty"})` looks up an item literally named "empty" and silently
fails. Same gotcha for trust spell names — use the bare global where
expected.

### Party display names drop `(UC)`

The party UI shows `Yoran-Oran` for Unity Concord trusts even when the
spell is `Yoran-Oran (UC)`. If you `//ft save`, the saved set will
miss the `(UC)` and the next `//ft call` will fail to find the spell.
Use `//ft edit <set> <slot#> Yoran-Oran (UC)` to fix manually.

### Retail vs private servers

Retail `/ma "Trust Name" <me>` works with bare names. Some private
servers (rare) prefix `Trust: ` to spell names. If your server needs
that, `//ft prefix Trust:`.

### Mouse events block camera

The mouse handler returns `true` for any event over the window
bounding box (including right-clicks). Without this, FFXI grabs
right-clicks for camera rotation through the window.

### Stop can't cancel in-flight casts

`//ft stop` (or the red Stop button) sets the queue inactive and
prevents future `/ma` sends, but any cast already in flight to the
FFXI server will still resolve. Server-side casts can't be cancelled
client-side without something interrupting (movement, damage, /heal).

## Files

- `FFXITrusts.lua` — the entire addon (single-file)
- `data/settings.xml` — your saved sets and window position
  (gitignored; generated per-character)

## Author

Jason (2026). Part of the FFXIWindower personal setup.
