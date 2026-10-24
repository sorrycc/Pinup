# AGENTS.md

Run `go test ./...` and `go tool mygo vet` before finishing a change. Tests set `PINUP_HOME` or `paths.SetRoot` to a temporary folder: never let one read or write the real `~/Library/Application Support/Pinup`.

## Commits

- One imperative subject line of 72 characters or fewer, for one change: `Let Pinup update itself`.
- Put any detail in a short body, not the subject.

## Changelog

- Add a bullet for every user-facing change under `## Unreleased` in CHANGELOG.md, creating that section above the latest version if it is missing.
- One sentence per bullet, about 100 characters at most, saying what the user sees.
- Use **bold** for menu paths and `code` for commands, keys and settings. Leave out internals.
- Split a big feature into several bullets rather than writing one long one.
- Skip changes users can't see: tests, CI, refactors.
