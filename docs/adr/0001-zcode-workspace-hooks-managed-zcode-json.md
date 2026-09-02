# ZCode.app coverage via managed workspace zcode.json, written once

ZCode.app sessions never execute user-level config hooks (the app host does not inject them; verified live 2026-09-02), so Open Island covers them through ZCode's own workspace mechanism instead: a managed write of `zcode.json` at the workspace root (first `.git` ancestor of the session's working directory, mirroring ZCode's config discovery), git-excluded via `.git/info/exclude`, tracked in the managed writes registry for wholesale removal on disable/uninstall. We deliberately never rewrite the file after trust is granted: ZCode keys trust on a digest covering command text, args, timeouts, and position indexes, so any rewrite silently invalidates it. We rewrite only when the hook binary path changes, and resurface the trust guide card when we do. We add no duplicate-event defense — code inspection shows terminal sessions never register workspace hooks and app sessions don't run user-level hooks, so no double-report path exists today; the residual risk is recorded in `docs/hooks.md`.

## Considered Options

- Fixed-path shim binary (stable command → trust never expires): rejected — an extra always-current component to maintain outweighs a rare re-trust click after the app moves.
- `.zcode/config.json` instead of `zcode.json`: rejected — that filename is ZCode.app's own editable target, risking the app's workspace-config writer colliding with ours.

## Consequences

- Removing the managed write leaves orphaned (inert) trust grants in ZCode's own trust store; ZCode exposes no external revoke API, and mutating its private store is out of bounds.
- Moving/renaming the Open Island app bundle invalidates trust once (stale digest) — the guide card handles re-trust.
