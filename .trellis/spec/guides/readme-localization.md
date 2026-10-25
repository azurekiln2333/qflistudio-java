# README localization

The root README set is `README.md` (Simplified Chinese), `README.zh-TW.md`
(Traditional Chinese), and `README.en.md` (English). Each file links the other
two. Keep capabilities, prerequisites, commands and verification limits aligned.

## Before writing

- Read `pubspec.yaml`, the relevant product source and the native JDK recipes.
- Check commands and paths against files included in the published checkout.
- Bind verification claims to their date, target, runtime and tested scope.
- Keep historical results distinct from acceptance of later source changes.
- Preserve uncertainty. Do not turn "may" into "will" during translation.

## Controlled Chinese

- Use one action per sentence and name its actor.
- Use one term for each concept throughout a document.
- Limit instructions to 25 characters and explanations to 40 characters.
- Do not join actions with semicolons.
- Remove nominalizations, empty phrases, marketing adjectives and vague words.
- Keep commands, paths, environment keys and technical identifiers literal.
- Review Traditional Chinese manually because the linter has limited coverage.

Run the mechanical first check from the repository root:

```bash
python scripts/ste-lint-zh.py README.md README.zh-TW.md
```

Check procedural sentences against the stricter limit. A document can use the
stricter limit throughout:

```bash
python scripts/ste-lint-zh.py --max-chars 25 README.md README.zh-TW.md
```

Do not raise the baseline or disable rules to make a rewritten README pass.
Mechanical checks do not establish factual accuracy, translation parity or
one-action sentences. Review those separately and check local Markdown links.

## Examples

Use two sentences for compiling a project and starting its entry class.
Do not combine those actions merely because they fit the length limit.

Describe a successful emulator run with its architecture and date.
Do not infer physical ARM64 acceptance from that result or from a signed build.
