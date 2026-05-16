---
name: sticky-column-bleed-fix
description: Solve the "transparent sticky column reveals scrolling content underneath" bug in horizontally-scrolling layouts (week/day calendars, spreadsheets, timetables, Gantt charts, timeline editors). Use when content from buffered/off-screen columns visibly leaks into the area occupied by a `position: sticky; left: 0` label column whose background must remain see-through (wallpaper themes, glass UIs, brand transparency). Trigger phrases include "events showing through hours column", "wallpaper transparaît à travers la colonne sticky", "buffer days bleed", "événements qui bavent", "transparent sticky element shows scrolling content behind", "glassmorphism leaking events". DO NOT use this skill if an opaque background on the sticky column is acceptable to the user — that is a one-line fix (`background: var(--bg-secondary)`).
---

# Sticky-Column Bleed Fix

## The pattern (recognize before fixing)

You're working on a UI with **all** of these properties:

1. A horizontally-scrolling area (rows or columns of repeating content)
2. A **sticky-left label column** (hours, row numbers, person names…) — `position: sticky; left: 0`
3. **Buffer items** rendered beyond the visible viewport for smooth continuous scroll (common in virtualized or `±N` day calendars)
4. The user wants the sticky column **transparent** so a wallpaper / image / parent surface shows through

**The bug**: as the user scrolls horizontally, the buffer items slide *under* the sticky column. With no opaque background to mask them, their content (events, cell text, grid lines) becomes visible inside the sticky column's viewport bounds.

If any of those four conditions is missing, this skill does not apply.

## Why this is hard — the constraint set

Articulate all the constraints up front, **out loud**, before proposing fixes. Most failed attempts solve only a subset.

| Constraint | Source |
|---|---|
| Sticky column must remain **visually transparent** (wallpaper visible) | User aesthetic / theme requirement |
| Other-column content must **not** be visible inside the sticky column's viewport-x range | The bug we're fixing |
| Sticky column likely keeps `transform: translateZ(0)` (or similar GPU-promotion hint) | Usually there to fix a *different* z-index / overflow bug; removing it regresses that |
| Solution must survive horizontal scroll at any speed without flicker | UX |
| Solution must adapt to varying numbers of sticky-left elements (label + secondary timezones, etc.) | Layout flexibility |

## Naive fixes that DO NOT work — verified by elimination

Before reading the solution, internalize *why* each tempting approach fails. This is what made other AI assistants (Kimi, GLM) loop unproductively on this bug.

| Attempt | Why it fails |
|---|---|
| `background: var(--bg-secondary)` (or any solid color) on the sticky column | Hides the wallpaper. Violates constraint #1. |
| Layered `linear-gradient(--bg, --bg), rgb(20,22,30)` opaque fallback | Same as above — fully opaque, kills the wallpaper. |
| `backdrop-filter: blur(20px)` glassmorphism | Blurred ghosts of the bleeding events remain visible and identifiable. Plus blurs the wallpaper, which the user often doesn't want either. |
| Drop `transform: translateZ(0)` from the sticky column | Re-introduces whatever z-index / paint-order bug it was originally added to fix. Check git history for that prior commit before considering this. |
| `overflow: hidden` on a wrapper around the day columns | Day columns are flex children that **fit perfectly** in the wrapper's natural box — there is nothing to overflow. `overflow: hidden` only clips content escaping its parent's box, which doesn't happen here. |
| `clip-path` on a parent containing both sticky and non-sticky elements | `clip-path` applies to **all** descendants. Clipping the leftmost area would also clip the sticky column itself. |
| Simply remove the buffer rendering | Loses the smooth-scroll experience. Possibly acceptable but usually a regression. |

## The fix: scroll-driven `clip-path` on a wrapper around non-sticky content

### Core idea (one sentence)

Wrap **only the non-sticky content** of each scroll-row in an element whose `clip-path` clips its leading edge by exactly `scrollLeft` pixels — keeping its visible boundary pinned at `viewport_x = sticky_width` regardless of how many sticky-left siblings precede it.

### The math (derive it; don't memorize it)

Let:
- `S` = total CSS width of all sticky-left siblings preceding the wrapper (e.g. `64px` for a single hours column, `128px` for hours + tz column)
- `x` = current `scrollLeft` of the horizontal scroll container

At scroll position `x`:
- Wrapper's **document-x** = `S` (its natural flex position after the sticky siblings)
- Wrapper's **viewport-x** = `S - x` (after horizontal scroll translates content left)
- We want its visible content to begin at `viewport_x = S` (right at the sticky border)
- Clipping the wrapper's leading `c` pixels (in wrapper-local coords) places its visible left edge at `viewport_x = (S - x) + c`
- Solve `(S - x) + c = S` → **`c = x`**

So `clip-path: inset(0 0 0 var(--scroll-x, 0px))` is correct, **independent of `S`**. The same wrapper rule works whether the user has zero, one, or three sticky-left columns.

### Implementation pattern

**1. CSS on the scroll row and wrapper:**

```css
.scroll-row {
    display: flex;
    min-width: fit-content;
    isolation: isolate;         /* new stacking context, prevents z-index leaks */
}

.row-content {
    flex: 1;
    display: flex;
    min-width: 0;
    position: relative;           /* preserves abs-positioning of children */
    clip-path: inset(0 0 0 var(--scroll-x, 0px));
}
```

Add `isolation: isolate` on the scroll-row. Without it, GPU-promoted sticky columns and absolutely-positioned children (events, multi-day bars) can interfere across rows in unexpected ways.

**2. Scroll listener** (rAF-batched is mandatory; without it, fast scrolls produce visible flashes):

```ts
useEffect(() => {
    const el = scrollRootRef.current;
    if (!el) return;
    let frame = 0;
    const update = () => {
        frame = 0;
        el.style.setProperty("--scroll-x", el.scrollLeft + "px");
    };
    const onScroll = () => {
        if (frame) return;
        frame = requestAnimationFrame(update);
    };
    update();                                           // initial paint
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => {
        el.removeEventListener("scroll", onScroll);
        if (frame) cancelAnimationFrame(frame);
    };
}, []);
```

The custom property must be set on an **ancestor** of `.row-content` (the scroll root is fine — CSS variables inherit through descendants).

**3. DOM** — wrap *only* the non-sticky children of each row:

```jsx
<div className="scroll-row">
    <div className="sticky-label" />              {/* sticky, NOT wrapped */}
    {/* …optionally more sticky-left siblings… */}
    <div className="row-content">                  {/* wrapper applies clip-path */}
        {non-sticky children: headers / cells / day columns / gantt rows…}
    </div>
</div>
```

Apply this to **every** scroll-row in the layout: header row, all-day / pinned-rows, body rows. Each row gets its own `.row-content`.

**4. Sticky column styling:**

Since the sticky column is now transparent, its internal border must remain legible over whatever wallpaper shows through. In the Neo Calendar fix, the default theme border (`var(--nc-border)`) was too faint against wallpapers, so it was replaced with a fixed semi-transparent gray:

```css
.sticky-label {
    position: sticky;
    left: 0;
    z-index: 999;                      /* stay above the clipped content */
    border-right: 1px solid rgba(128, 128, 128, 0.5);
    transform: translateZ(0);           /* GPU compositor layer, usually already present */
    /* deliberately NO background property */
}
```

Use `z-index: 999` (or any value higher than wrapper children) so the sticky column paints above the `.row-content` layer. Keep `transform: translateZ(0)` if it was already there to solve a prior compositing bug — removing it regresses that earlier fix.

## Adaptation guide

| Layout | Sticky-left typically is | Wrapper should contain |
|---|---|---|
| Week/day calendar (Notion/Google-style) | Hours column, optional tz columns | Day headers, all-day cells, day columns |
| Spreadsheet | Row numbers + frozen columns | All non-frozen cells of each row |
| Gantt chart | Task name column | Timeline bars, today line |
| Timeline editor | Track labels | Clip blocks, ruler ticks |
| Multi-resource scheduler | Resource names | Time blocks per resource |

In all cases the math `c = scrollLeft` is unchanged.

## Diagnostic methodology — before writing any CSS

When this bug is reported, **investigate before patching**. The pattern repeats across themes and codebases.

1. **Read git history of prior attempts on the same files**:
   ```bash
   git log -p --follow <css-file> | head -200
   ```
   If you see commits like "Fix: opaque background on sticky column", "Fix: glassmorphism", "Fix: match sidebar opacity", they tried solid-fill solutions that conflict with the user's transparency requirement. Don't repeat them.

2. **Identify the wallpaper / transparency mechanism**. In Obsidian themes it's often a class like `.anp-background-image-toggle` setting `background: url(...)` on `.app-container` and overriding `.view-content` with a translucent `--card-foreground-color`. Knowing the source helps you reason about which CSS variables are actually opaque vs translucent in the user's environment.

3. **Confirm `transform: translateZ(0)` is present** on the sticky column and **why**. The original commit message will usually say "fix event z-index" or "GPU compositor". This means GPU-promoted layers are the right fix path, and the bleed is happening *despite* the column being on its own GPU layer because parent layers above it (e.g. with `backdrop-filter`) interfere.

4. **State the constraint set out loud** to the user before coding. Confirm "you want X transparent AND Y not visible AND Z preserved" — this prevents the solve-only-half-the-problem trap.

## Verification checklist

After applying:

- [ ] Scroll horizontally fast (mousewheel + shift, trackpad two-finger swipe). No flash of bleeding content into the sticky-left area.
- [ ] Wallpaper / parent surface remains visible through the sticky column.
- [ ] Labels, borders, and content **on** the sticky column render normally (not clipped — they're not in the wrapper).
- [ ] Absolutely-positioned children of the wrapper (multi-day bars at `left: %`, now-indicator lines, drag previews) align correctly — `position: relative` on the wrapper is preserved.
- [ ] Window resize: scroll position recalculates correctly. The clip is pure pixel offset; layout changes update `scrollLeft` automatically.
- [ ] No layout shift: `clip-path` does not change box dimensions.
- [ ] Initial render before any scroll event: the `update()` call runs once on mount so `--scroll-x` starts at the actual `scrollLeft` (not undefined → 0px fallback) — important if the layout restores a saved scroll position on mount.

## Pitfalls

- **Don't apply `clip-path` to the row itself** — clip-path applies to all descendants and would clip the sticky elements too.
- **Don't put the CSS variable on the wrapper** — it must be on an ancestor (typically the scroll container) to inherit.
- **Don't skip `requestAnimationFrame`** — synchronous CSS variable writes inside a `scroll` handler at every event create jank on fast scrolls and a one-frame lag visible as a brief bleed flash.
- **Don't forget to clean up the listener and pending rAF** in the effect cleanup.
- **Don't apply to the header row only**. The bleed happens on all rows. If you forget the all-day row, multi-day bars from buffer days will leak.

## When NOT to apply

- Opaque sticky column is acceptable → `background: var(--bg-secondary)` on the sticky column, done.
- No buffer rendering (single-week view fits viewport, no scroll) → no bleed possible.
- Vertical-only scroll (`position: sticky; top: 0` row, no horizontal scroll) → `c = scrollTop` analog, but rare for this bug pattern.
