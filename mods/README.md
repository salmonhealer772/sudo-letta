# sudo-letta comm mods (vendored)

The three comm-tool mod packages an agent is born with:

- `list-siblings/`  -> `@letta-ai/list-siblings`  (tool `list_siblings`)
- `message-agent/`  -> `@letta-ai/message-agent`  (tool `message_agent`)
- `check-agent/`    -> `@letta-ai/check-agent`    (tool `check_agent`)

These are installed at deploy time by `kube-scripts/up.sh` (see the `NPM_MODS` /
`COMM_MODS` block) via `kubectl cp` + `letta install <path>`, and verified at
their exact pinned version the same way the official npm mods are.

CANONICAL SOURCE: `sudo-fleet` repo, `mods/<name>/` (comm-skills-tools branch),
with the packaging spec at `docs/comm-mods-PACKAGING.md`. This `mods/` dir is a
vendored snapshot for the factory image/deploy — when the packages change in
`sudo-fleet`, re-vendor them here and bump the versions in both `package.json`
and `up.sh` together.
