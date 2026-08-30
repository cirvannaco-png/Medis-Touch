"""
tools/_pathutil.py — one function, used by every tools/*.py script that
needs to import the bridge's `app` package (for its DB models/session).

Two layouts this has to work from, and the difference matters:

  REPO CHECKOUT       tools/ is a sibling of telegram-bridge/, and the
                       bridge code lives at telegram-bridge/app/.

  DEPLOYED CONTAINER   telegram-bridge/Dockerfile COPYs tools/ and app/
                       as siblings directly under /app (WORKDIR) — there
                       is no telegram-bridge/ directory inside the image
                       at all. See that Dockerfile's COPY lines.

Hardcoding either assumption breaks the other. This tries both, in that
order, and uses whichever actually has app/config.py under it.
"""
import os
import sys


def ensure_bridge_importable(from_file: str) -> str:
    base = os.path.dirname(os.path.abspath(from_file))
    candidates = [
        os.path.normpath(os.path.join(base, "..", "telegram-bridge")),  # repo checkout
        os.path.normpath(os.path.join(base, "..")),                     # deployed container
    ]
    for candidate in candidates:
        if os.path.exists(os.path.join(candidate, "app", "config.py")):
            if candidate not in sys.path:
                sys.path.insert(0, candidate)
            return candidate
    raise ImportError(
        "Couldn't locate the bridge's `app` package from either a repo "
        "checkout (tools/ sibling of telegram-bridge/) or a deployed "
        "container layout (tools/ and app/ as siblings) — searched: "
        + ", ".join(candidates)
    )
