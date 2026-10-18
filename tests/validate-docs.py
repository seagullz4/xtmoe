#!/usr/bin/env python3
"""Validate the current product documentation without fetching external links."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
documents = [root / "README.md", root / "CHANGELOG.md", *sorted((root / "docs").glob("*.md"))]
top = {"on", "doctor", "list", "version", "help", "proot", "chroot", "uninstall", "update"}
actions = {
    "proot": {"install", "login", "exec", "list", "ps", "stop", "backup", "update-system", "status", "help"},
    "chroot": {"prepare", "install", "systemd-login", "stop", "status", "help"},
}
errors = []
for document in documents:
    text = document.read_text(encoding="utf-8")
    for target in re.findall(r"\]\(([^)]+)\)", text):
        if re.match(r"[a-z]+://", target) or target.startswith("#"):
            continue
        path = target.split("#", 1)[0]
        if not (document.parent / path).is_file():
            errors.append(f"{document.name}: missing link {target}")
    for fence in re.findall(r"```(?:sh|bash)?\n(.*?)```", text, re.S):
        for line in fence.splitlines():
            if not line.strip().startswith("xtmoe "):
                continue
            parts = line.strip().split()
            if parts[1] not in top:
                errors.append(f"{document.name}: unpublished command {line}")
            elif parts[1] in actions and (len(parts) < 3 or parts[2] not in actions[parts[1]]):
                errors.append(f"{document.name}: unpublished mode action {line}")
assert not errors, "\n".join(errors)
assert "XTMOE_VERSION='v1.0.0'" in (root / "src/bin/xtmoe").read_text(encoding="utf-8")
print(f"Documentation links and public commands verified: {len(documents)} files")
