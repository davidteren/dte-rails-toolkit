#!/usr/bin/env python3
"""skill_lint.py — deterministic SKILL.md quality gate.

Clean-room implementation of Anthropic's Agent Skills authoring best practices
(https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices).
Original code — not derived from any third-party linter. MIT.

Rules (each names the failure that produces no error):
  frontmatter.present     SKILL.md opens with a `---` YAML block
  frontmatter.name        has `name:`, kebab-case, equal to the parent dir name
  frontmatter.description  has `description:`, <= 1024 chars, contains no `<...>` XML tag
  reference.toc           a reference .md over 100 lines has a `## Contents` in its first 30 lines
  reference.length        every reference .md is <= 500 lines
  reference.linked        every reference .md is linked from SKILL.md by a real markdown link
  reference.links_resolve  relative markdown links in SKILL.md / references resolve to a file

A "reference file" is every *.md in the skill dir except SKILL.md.

Usage:  skill_lint.py [<skill-dir | SKILL.md> ...]   # default: ./skills/*/SKILL.md
Exit:   0 = all pass, 1 = any fail, 2 = usage error.
"""
import os
import re
import sys

KEBAB = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
XML_TAG = re.compile(r"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^>]*)?/?>")
MD_LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def split_frontmatter(text):
    """Return (frontmatter_str, body_str) or (None, text) if no `---` block."""
    if not text.startswith("---"):
        return None, text
    m = re.match(r"---\s*\n(.*?)\n---\s*\n?(.*)", text, re.S)
    if not m:
        return None, text
    return m.group(1), m.group(2)


def fm_value(fm, key):
    """Pull a scalar or folded value for `key` from a simple YAML frontmatter block."""
    lines = fm.splitlines()
    for i, line in enumerate(lines):
        m = re.match(rf"{key}:\s*(.*)$", line)
        if not m:
            continue
        val = m.group(1).strip()
        if val in (">", "|", ">-", "|-", ">+", "|+"):  # folded/literal block
            block = []
            for cont in lines[i + 1:]:
                if cont and not cont[0].isspace():
                    break
                block.append(cont.strip())
            return " ".join(b for b in block if b)
        return val.strip().strip("'\"")
    return None


def references(skill_dir):
    out = []
    for dirpath, _dirs, files in os.walk(skill_dir):
        for f in files:
            if f.endswith(".md") and not (dirpath == skill_dir and f == "SKILL.md"):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def linecount(path):
    with open(path, encoding="utf-8") as fh:
        return sum(1 for _ in fh)


def check_skill(skill_md):
    fails = []
    skill_dir = os.path.dirname(skill_md)
    name_expected = os.path.basename(skill_dir)
    text = open(skill_md, encoding="utf-8").read()

    fm, body = split_frontmatter(text)
    if fm is None:
        return ["frontmatter.present — no `---` YAML frontmatter block at the top of SKILL.md"]

    name = fm_value(fm, "name")
    if not name:
        fails.append("frontmatter.name — no `name:` in frontmatter")
    else:
        if not KEBAB.match(name):
            fails.append(f"frontmatter.name — `{name}` is not kebab-case")
        if name != name_expected:
            fails.append(f"frontmatter.name — `{name}` != skill dir name `{name_expected}`")

    desc = fm_value(fm, "description")
    if not desc:
        fails.append("frontmatter.description — no `description:` in frontmatter")
    else:
        if len(desc) > 1024:
            fails.append(f"frontmatter.description — {len(desc)} chars > 1024 cap")
        tag = XML_TAG.search(desc)
        if tag:
            fails.append(f"frontmatter.description — contains an XML/HTML tag '{tag.group(0)}' "
                         "(reword, e.g. `turbo-frame` element, not `<turbo-frame>`)")

    # reference files
    refs = references(skill_dir)
    body_links = {m for m in MD_LINK.findall(text)}
    for ref in refs:
        rel = os.path.relpath(ref, skill_dir)
        n = linecount(ref)
        if n > 500:
            fails.append(f"reference.length — {rel} is {n} lines > 500 cap")
        if n > 100:
            head = "\n".join(open(ref, encoding="utf-8").read().splitlines()[:30])
            if "## Contents" not in head:
                fails.append(f"reference.toc — {rel} ({n} lines) needs a '## Contents' in its first 30 lines")
        # linked from SKILL.md by a markdown link whose target resolves to this ref
        linked = any(
            os.path.normpath(os.path.join(skill_dir, l.split("#")[0])) == os.path.normpath(ref)
            for l in body_links if not l.startswith(("http://", "https://", "#"))
        )
        if not linked:
            fails.append(f"reference.linked — {rel} is not linked from SKILL.md by a markdown link (a backtick mention doesn't count)")

    # links resolve (SKILL.md relative links)
    for l in body_links:
        target = l.split("#")[0]
        if not target or l.startswith(("http://", "https://", "#")):
            continue
        if not os.path.exists(os.path.normpath(os.path.join(skill_dir, target))):
            fails.append(f"reference.links_resolve — link `{target}` in SKILL.md resolves to no file")

    return fails


def discover(root):
    skills_dir = os.path.join(root, "skills")
    found = []
    if os.path.isdir(skills_dir):
        for entry in sorted(os.listdir(skills_dir)):
            sm = os.path.join(skills_dir, entry, "SKILL.md")
            if os.path.isfile(sm):
                found.append(sm)
    return found


def main(argv):
    if argv:
        skills = []
        for a in argv:
            skills.append(a if a.endswith("SKILL.md") else os.path.join(a, "SKILL.md"))
    else:
        skills = discover(os.getcwd())
    if not skills:
        print("skill_lint: no skills found (pass a skill dir, or run from a repo with skills/)", file=sys.stderr)
        return 2

    total_fail = 0
    print(f"Linting {len(skills)} skill(s)...\n")
    for sm in skills:
        if not os.path.isfile(sm):
            print(f"  ?? {sm} — not found"); total_fail += 1; continue
        fails = check_skill(sm)
        name = os.path.basename(os.path.dirname(sm))
        if not fails:
            print(f"  ✓ {name} — pass")
        else:
            total_fail += 1
            print(f"  ✗ {name} — FAIL")
            for f in fails:
                print(f"      {f}")
    print(f"\n{len(skills) - total_fail} pass, {total_fail} fail (out of {len(skills)})")
    return 1 if total_fail else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
