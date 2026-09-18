"""frev review application: schema, file store, loopback server, Emacs bridge, CLI.

Standard library only.  Sessions are plain files under the frev data root; the
server only reads session files and appends submissions.  Nothing here executes
Fleet actions: the only write toward Fleet is the fixed-format notice queued by
``scripts/frev.el`` through ``emacsclient``.
"""

__all__ = ["schema", "store", "bridge", "server", "cli"]
