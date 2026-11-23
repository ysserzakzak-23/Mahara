"""
Summarise Flutter's coverage/lcov.info as a table (no extra tools needed).

Run from the Flutter project root, after `flutter test --coverage`:

    python lcov_summary.py                 # all files, weakest first
    python lcov_summary.py --min 80        # only files under 80 %
    python lcov_summary.py path/to/lcov.info
"""
import sys
from pathlib import Path


def parse(path):
    files, current = {}, None
    for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            current = line[3:].replace("\\", "/")
            files[current] = {"found": 0, "hit": 0, "missed": []}
        elif line.startswith("DA:") and current:
            number, hits = line[3:].split(",")[:2]
            files[current]["found"] += 1
            if int(hits) > 0:
                files[current]["hit"] += 1
            else:
                files[current]["missed"].append(int(number))
    return files


def main():
    args = [a for a in sys.argv[1:]]
    threshold = 101.0
    if "--min" in args:
        i = args.index("--min")
        threshold = float(args[i + 1])
        del args[i:i + 2]
    path = args[0] if args else "coverage/lcov.info"
    if not Path(path).exists():
        sys.exit(f"{path} not found - run `flutter test --coverage` first "
                 "(from the project root).")

    files = parse(path)
    rows = []
    for name, d in files.items():
        pct = 100.0 * d["hit"] / d["found"] if d["found"] else 100.0
        rows.append((pct, name, d))
    rows.sort(key=lambda r: (r[0], r[1]))

    total_found = sum(d["found"] for _, _, d in rows)
    total_hit = sum(d["hit"] for _, _, d in rows)
    print(f"{'%':>6}  {'lines':>11}  file")
    for pct, name, d in rows:
        if pct < threshold:
            short = name.split("lib/", 1)[-1]
            print(f"{pct:6.1f}  {d['hit']:>5}/{d['found']:<5}  {short}")
    total = 100.0 * total_hit / total_found if total_found else 100.0
    print(f"\nTOTAL {total:.1f}%  ({total_hit}/{total_found} lines, {len(rows)} files)")


if __name__ == "__main__":
    main()
