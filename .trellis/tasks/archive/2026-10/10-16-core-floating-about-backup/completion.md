# Completion

Shared core commits:

- 40d9251 feat(editor): allow moving and collapsing the restore control
- 84f68a7 feat(settings): show product details on a dedicated About page
- 104dc5f feat(backup): export and restore whole application data as qfliz

All implementation is in qfli_studio_core; language products inherit it through
their existing local core dependency. No other product workspace, build, device
or remote push was used for this task.

## Parallel delivery

Three Herdr Pi ran in the Java workspace: wE:p7 (floating control, then safety
tests), wE:pB (About, then Settings interaction/disposal), wE:pC (backup service,
startup integration and transaction fixes). Native check workers additionally
reviewed/fixed drag accumulation, startup gates and recovery regressions.

## Validation

- Core full suite: 570 passed, 1 Unix-only chmod/link test skipped on Windows.
- Java full suite: 84 passed.
- Core and Java dart analyze lib test: no issues.
- Scoped diff whitespace checks: clean.
- Logs: build/core-work/floating-about/{core-full-tests,java-full-tests,
  core-analysis,java-analysis}.log.

## Restore behavior

Settings only validates and stages an import. Fully close/reopen to apply before
stores load; the completion page requests another full close/reopen so native
runtime caches and restored data agree. Recovery failures also keep Home gated.
The ZIP includes app_info.json at root, data/ for storage and private_<key>/ for
additional confirmed roots. Hidden/binary/runtime files, empty roots and link
entities are preserved; arbitrary external project references stay external.

Device behavior and Unix permission semantics were not validated by the Windows
test run. Local frontend specs record the archive/transaction contract and
per-frame drag accumulation; ignored spec files were not force-added.
