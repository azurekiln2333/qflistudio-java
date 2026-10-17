# Speed up project and page opening

Parent: `10-15-studio-polish` (read its hard constraints first).

## Problem

Opening a project from the home page always stutters, in every qfli product. Other pages also open slowly.

## Approach: measure first, then fix

1. Read the home → EditorPage open path and other page routes. List suspects with `file:line`: sync IO on the UI isolate (`*Sync`, recursive directory scans, `existsSync`), large JSON decode, syntax-highlight / re_editor init, a heavy first frame, work during the route transition, over-broad `ChangeNotifier` rebuilds, pages built eagerly (PageView / IndexedStack).
2. Add a repeatable measurement (widget test timing and/or a debug-only FrameTiming / Timeline log behind a flag). Record before numbers.
3. Fix: async IO or `compute` isolates, skeleton first then load, defer heavy work until the route animation completes, lazy file tree, narrower rebuilds (Selector / ValueListenable), `const`, `RepaintBoundary`, builder lists.
4. Record after numbers.

## Acceptance

- Bottleneck list with `file:line` and before/after timings in `notes/`.
- No behaviour change; related tests pass; online features of qflistudio untouched.
