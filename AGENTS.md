# AGENTS.md

Add a line for every user-facing change under the `## Unreleased` section of CHANGELOG.md, creating that section above the latest version if it is missing.

Run `go test ./...` and `go tool mygo vet` before finishing a change. Tests set `PINUP_HOME` or `paths.SetRoot` to a temporary folder: never let one read or write the real `~/Library/Application Support/Pinup`.
