# Open Island

Native macOS companion that monitors local AI coding agent sessions from the notch. This glossary fixes the vocabulary the codebase and issues use.

## Language

### Workspace hooks feature

**Workspace**:
The directory a ZCode session runs in; the unit Open Island manages hooks for. May or may not be a git repository.
_Avoid_: project, repo

**Workspace config**:
The project-level `zcode.json` file ZCode reads hooks from for app sessions, as opposed to the user-level `~/.zcode/cli/config.json` only terminal sessions load.
_Avoid_: project config, local config

**Managed write**:
A file change Open Island makes inside a user's workspace (workspace config file, `.git/info/exclude` entry), always recorded before or atomically with the change itself.
_Avoid_: install, inject

**Managed writes registry**:
The authoritative record of every managed write, consumed wholesale by disable/uninstall cleanup.
_Avoid_: tracking table, write log

**Workspace root**:
The first ancestor of a session's working directory that contains `.git`, or the working directory itself when none does — where ZCode's workspace config discovery stops and collects from.
_Avoid_: repo root, project root

**Trust grant**:
ZCode's persisted approval binding a workspace identity to a hook declaration digest; any later change to the declaration invalidates the grant (stale digest).
_Avoid_: whitelist entry, approval
