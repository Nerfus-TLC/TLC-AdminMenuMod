"""Check the mod's Lua files without starting the game.

Two passes:

  1. Syntax, using a real Lua 5.4 parser through lupa. It only compiles - nothing runs.

  2. Local functions used before they are declared. Lua binds names at compile time, so
     referring to `foo` above `local function foo` compiles into a global lookup that is
     nil forever. The syntax is valid, so pass 1 sees nothing wrong, and the game dies at
     runtime on

         attempt to call a nil value (global 'foo')

     which costs a restart to discover. This pass has caught that bug for real.

Requires lupa:  pip install lupa

Usage:  python tools/luacheck.py AdminMenuMod/Scripts/*.lua
"""

import re
import sys

import lupa.lua54 as lua54

DECL_FUNCTION = re.compile(r"^\s*local\s+function\s+([A-Za-z_]\w*)")
DECL_VARIABLE = re.compile(r"^\s*local\s+([A-Za-z_][\w\s,]*?)\s*=")


def strip_noise(source: str) -> str:
    """Remove block comments, line comments and strings, keeping the line numbering."""
    source = re.sub(r"--\[\[.*?\]\]", lambda m: "\n" * m.group(0).count("\n"), source,
                    flags=re.S)
    source = re.sub(r"--[^\n]*", "", source)
    source = re.sub(r'"[^"\n]*"', '""', source)
    source = re.sub(r"'[^'\n]*'", "''", source)
    return source


def check_syntax(path: str, source: str) -> bool:
    runtime = lua54.LuaRuntime(unpack_returned_tuples=True)
    result = runtime.globals().load(source, "@" + path)

    # load() returns one value on success, and (nil, message) on a syntax error.
    if isinstance(result, tuple):
        _, err = result
        print("SYNTAX  " + path)
        print("        " + str(err))
        return False
    return True


def check_declaration_order(path: str, source: str) -> bool:
    lines = strip_noise(source).splitlines()

    declared = {}
    for number, line in enumerate(lines, 1):
        match = DECL_FUNCTION.match(line)
        if match:
            declared.setdefault(match.group(1), number)
            continue
        match = DECL_VARIABLE.match(line)
        if match:
            for name in match.group(1).split(","):
                name = name.strip()
                if name.isidentifier():
                    declared.setdefault(name, number)

    problems = []
    for name, decl_line in declared.items():
        pattern = re.compile(r"\b" + re.escape(name) + r"\s*\(")
        for number, line in enumerate(lines, 1):
            if number >= decl_line:
                break
            if pattern.search(line):
                problems.append((number, name, decl_line))

    for number, name, decl_line in sorted(problems):
        print("ORDER   %s:%d calls '%s', first declared on line %d"
              % (path, number, name, decl_line))
    return not problems


def check(path: str) -> bool:
    with open(path, "r", encoding="utf-8") as handle:
        source = handle.read()

    ok = check_syntax(path, source)
    if ok:
        ok = check_declaration_order(path, source)
    if ok:
        print("ok      " + path)
    return ok


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    return 0 if all([check(p) for p in sys.argv[1:]]) else 1


if __name__ == "__main__":
    sys.exit(main())
