#!/usr/bin/env python3
"""Render the caddy-coddy templates into a project directory.

    render.py [--check] [--diff] [--force-keep] [-v] [--templates DIR] [PROJECT_DIR]

Reads PROJECT_DIR/caddy-coddy.yml (default: the current directory), replaces every
`@@NAME@@` placeholder in the text templates with the manifest values (see
`manifest.py vars`), copies binary files verbatim and keeps each template's
executable bit. Paths listed under `keep:` in the manifest are created when
missing and otherwise left alone.

  --check       write nothing; print create / update / keep per file and exit 1
                when anything would be created or updated
  --diff        with --check, print a unified diff for files that would change
  --force-keep  overwrite `keep:` files as well
  -v            also list unchanged files

Exit status: 0 rendered (or, with --check, nothing to do); 1 differences in
--check mode, an unknown placeholder or an invalid manifest; 2 usage.
"""
from __future__ import annotations

import argparse
import difflib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import manifest as mf  # noqa: E402

DEFAULT_TEMPLATES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "references", "templates")
PLACEHOLDER = mf.re.compile(r"@@([A-Z][A-Z0-9_]*)@@")


def is_binary(data: bytes) -> bool:
    if b"\0" in data:
        return True
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return True
    return False


def render_all(templates: str, variables: dict[str, str]):
    """Return ([(relpath, bytes, mode)], [problems]) for every file under templates."""
    rendered, problems = [], []
    for root, dirs, files in os.walk(templates):
        dirs.sort()
        for name in sorted(files):
            src = os.path.join(root, name)
            rel = os.path.relpath(src, templates)
            with open(src, "rb") as fh:
                data = fh.read()
            if not is_binary(data):
                text = data.decode("utf-8")
                unknown = sorted({m.group(1) for m in PLACEHOLDER.finditer(text) if m.group(1) not in variables})
                if unknown:
                    problems.append(f"{rel}: unknown placeholder(s) {', '.join('@@' + u + '@@' for u in unknown)}")
                text = PLACEHOLDER.sub(lambda m: variables.get(m.group(1), m.group(0)), text)
                data = text.encode("utf-8")
            rendered.append((rel, data, os.stat(src).st_mode & 0o777))
    return rendered, problems


def show_diff(rel: str, current: bytes, new: bytes) -> None:
    if is_binary(current) or is_binary(new):
        print(f"          (binary file {rel} differs)")
        return
    diff = difflib.unified_diff(
        current.decode("utf-8").splitlines(), new.decode("utf-8").splitlines(),
        fromfile=f"{rel} (current)", tofile=f"{rel} (rendered)", lineterm="", n=2,
    )
    for line in diff:
        print("          " + line)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--diff", action="store_true")
    parser.add_argument("--force-keep", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--templates", default=DEFAULT_TEMPLATES)
    parser.add_argument("project", nargs="?", default=".")
    args = parser.parse_args(argv)

    project = os.path.abspath(args.project)
    templates = os.path.abspath(args.templates)
    if not os.path.isdir(templates):
        print(f"render: templates directory not found: {templates}", file=sys.stderr)
        return 1
    try:
        _, values = mf.read(os.path.join(project, mf.DEFAULT_FILE))
        variables = mf.render_vars(values)
    except mf.ManifestError as error:
        print(f"render: {error}", file=sys.stderr)
        return 1
    keep = {p for p in variables.get("KEEP", "").split(",") if p}

    rendered, problems = render_all(templates, variables)
    if problems:
        for problem in problems:
            print(f"render: {problem}", file=sys.stderr)
        print("render: nothing written (fix the templates or add the key to manifest.py FIELDS)", file=sys.stderr)
        return 1

    counts = {"create": 0, "update": 0, "unchanged": 0, "keep": 0}
    for rel, data, mode in rendered:
        dst = os.path.join(project, rel)
        current = None
        if os.path.exists(dst):
            with open(dst, "rb") as fh:
                current = fh.read()
        if current is None:
            status = "create"
        elif current == data:
            status = "unchanged"
        elif rel in keep and not args.force_keep:
            status = "keep"
        else:
            status = "update"
        counts[status] += 1
        if status != "unchanged" or args.verbose:
            print(f"{status:9} {rel}")
        if status in ("update", "keep") and args.check and args.diff:
            show_diff(rel, current, data)
        if status in ("create", "update") and not args.check:
            os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
            tmp = dst + ".tmp"
            with open(tmp, "wb") as fh:
                fh.write(data)
            os.chmod(tmp, mode)
            os.replace(tmp, dst)

    summary = ", ".join(f"{n} {status}" for status, n in counts.items() if n)
    if args.check:
        pending = counts["create"] + counts["update"]
        print(f"check: {summary}" + ("" if pending else "; project matches the templates"))
        return 1 if pending else 0
    print(f"rendered into {project}: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
