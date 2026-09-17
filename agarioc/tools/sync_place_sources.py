#!/usr/bin/env python3
"""Copy edited source mirrors back into the Roblox XML place file."""

from __future__ import annotations

import html
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLACE = ROOT / "Agar.rbxlx"
SOURCES = {
    "Config": ROOT / "src/ReplicatedStorage/Agar2D/Shared/Config.lua",
    "GameService": ROOT / "src/ServerScriptService/Agar2D/GameService.lua",
    "Camera2D": ROOT / "src/StarterPlayer/StarterPlayerScripts/Agar2D/Camera2D.lua",
    "Renderer": ROOT / "src/StarterPlayer/StarterPlayerScripts/Agar2D/Renderer.lua",
}


def sync_source(place_text: str, script_name: str, source_path: Path) -> str:
    pattern = re.compile(
        r'(<Item class="(?:ModuleScript|Script|LocalScript)"[^>]*>\s*'
        r"<Properties>(?:(?!<Item\b|</Item>).)*?"
        r'<ProtectedString name="Source">)'
        r"((?:(?!<Item\b|</Item>).)*?)"
        r"(</ProtectedString>(?:(?!<Item\b|</Item>).)*?"
        r'<string name="Name">' + re.escape(script_name) + r"</string>.*?"
        r"</Properties>\s*</Item>)",
        re.DOTALL,
    )
    escaped_source = html.escape(source_path.read_text(encoding="utf-8"), quote=False)
    updated, count = pattern.subn(
        lambda match: match.group(1) + escaped_source + match.group(3),
        place_text,
        count=1,
    )
    if count != 1:
        raise RuntimeError(f"expected one {script_name!r} script in {PLACE}, found {count}")
    return updated


def main() -> None:
    place_text = PLACE.read_text(encoding="utf-8")
    for script_name, source_path in SOURCES.items():
        place_text = sync_source(place_text, script_name, source_path)
    PLACE.write_text(place_text, encoding="utf-8")


if __name__ == "__main__":
    main()
