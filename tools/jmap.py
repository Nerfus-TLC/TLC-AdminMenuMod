"""Pull objects out of a UE4SS reflection dump without loading 174 MB into memory.

UE4SS writes the dump with CTRL + Numpad 5 while the game runs. It is pretty printed
JSON where every object is a key indented by four spaces, so a key can be caught with a
regex and its lines collected until the block closes at the same indent.

Bear in mind the dump only contains what was loaded at the moment it was taken. A missing
object proves nothing - get the game to load it, then dump again.

Usage:
    python tools/jmap.py <dump.jmap> <regex matched against object names> [--full]

Without --full it prints a summary: super_struct, child functions, and each property
with its name, type and parameter flags. With --full it prints the whole block.

In Git Bash, prefix the command with MSYS_NO_PATHCONV=1 or the shell will rewrite a
pattern starting with / into a Windows path.
"""

import re
import sys

KEY = re.compile(r'^ {4}"([^"]+)":\s*\{')
FIELD = re.compile(
    r'^\s*"(name|type|struct|property_class|super_struct|flags)":\s*"?([^",]+)"?,?\s*$')


def blocks(path):
    """Yield (name, lines) for every top level object in the dump."""
    current = None
    lines = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if current is None:
                match = KEY.match(line)
                if match:
                    current = match.group(1)
                    lines = [line]
                continue

            lines.append(line)
            if line.startswith("    }"):
                yield current, lines
                current = None
                lines = []


def summarise(name, lines):
    print("=" * 78)
    print(name)

    in_children = False
    params = []
    pending = {}

    for line in lines:
        stripped = line.strip()

        if stripped.startswith('"children"'):
            # An empty list closes on the same line and never opens a block.
            in_children = not stripped.startswith('"children": []')
            continue
        if in_children:
            if stripped.startswith("]"):
                in_children = False
            elif stripped.startswith('"'):
                print("   fn   " + stripped.strip('",').split(":")[-1])
            continue

        match = FIELD.match(line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()

        if key == "super_struct":
            print("   super_struct: " + value)
        elif key == "name":
            if pending:
                params.append(pending)
            pending = {"name": value}
        elif pending:
            pending[key] = value

    if pending:
        params.append(pending)

    for p in params:
        flags = p.get("flags", "")
        kind = "-"
        for flag, label in (("CPF_ReturnParm", "return"), ("CPF_OutParm", "out"),
                            ("CPF_Parm", "param")):
            if flag in flags:
                kind = label
                break
        extra = p.get("struct") or p.get("property_class") or ""
        print("   %-8s %-38s %-22s %s" % (kind, p["name"], p.get("type", "?"), extra))


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    path, pattern = sys.argv[1], sys.argv[2]
    full = "--full" in sys.argv
    needle = re.compile(pattern)

    hits = 0
    for name, lines in blocks(path):
        if not needle.search(name):
            continue
        hits += 1
        if full:
            print("=" * 78)
            print("".join(lines))
        else:
            summarise(name, lines)
        if hits >= 40:
            print("... stopping after 40 matches")
            break

    if hits == 0:
        print("no match for " + pattern)
    return 0


if __name__ == "__main__":
    sys.exit(main())
