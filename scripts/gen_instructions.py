#!/usr/bin/env python3
"""Regenerates lua/masm/instructions.lua from masm-lsp's instruction metadata.

Usage:
    scripts/gen_instructions.py <masm-lsp>/crates/masm-instructions/data/instruction_reference.toml

The TOML lives in Trail of Bits' masm-lsp repository (MIT licensed) and is
itself generated from the official Miden Assembly instruction reference, so
this keeps descriptions and stack effects in sync with the docs without
hand-maintaining 160+ entries.
"""

import pathlib
import sys
import tomllib


def lua_quote(s: str) -> str:
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    # Multi-line TOML strings would otherwise emit an unfinished Lua literal.
    s = s.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return '"' + s + '"'


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip())
    with open(sys.argv[1], "rb") as f:
        entries = tomllib.load(f)["instructions"]

    out = pathlib.Path(__file__).resolve().parent.parent / "lua" / "masm" / "instructions.lua"
    lines = [
        "-- Miden Assembly instruction reference: { name, description, stack effect }.",
        "-- Immediate-operand variants keep the metadata's `{n}` placeholders.",
        "--",
        "-- GENERATED FILE -- regenerate with scripts/gen_instructions.py from the",
        "-- instruction metadata in Trail of Bits' masm-lsp (MIT licensed), itself",
        "-- derived from the official Miden instruction reference:",
        "--   https://github.com/trailofbits/masm-lsp",
        "--   crates/masm-instructions/data/instruction_reference.toml",
        "",
        "-- stylua: ignore",
        "local instructions = {",
    ]
    for e in entries:
        lines.append(
            "  { %s, %s, %s },"
            % (
                lua_quote(e["name"]),
                lua_quote(e.get("description", "")),
                lua_quote(e.get("stack_effect", "")),
            )
        )
    lines += [
        "}",
        "",
        "-- Reference gaps (mnemonics the metadata lacks but arity.lua simulates)",
        "-- are filled from the hand-maintained instructions_extra.lua; the",
        "-- generator emits this merge, so regeneration cannot lose them.",
        'for _, e in ipairs(require("masm.instructions_extra")) do',
        "  instructions[#instructions + 1] = e",
        "end",
        "return instructions",
    ]
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {out} ({len(entries)} instructions)")


if __name__ == "__main__":
    main()
