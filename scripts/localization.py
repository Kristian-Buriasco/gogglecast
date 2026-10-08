#!/usr/bin/env python3
"""Keeps the app's Localizable.strings files in step with the Swift sources.

The English text in the source is the key. This script finds every key in
Apps/GogglesView/Sources/GogglesView and compares it with each
Apps/GogglesView/BundleResources/Localization/<lang>.lproj/Localizable.strings.

Usage:
  scripts/localization.py extract          print the keys found in the sources
  scripts/localization.py check            report missing / extra keys and format mismatches (exit 1 on problems)
  scripts/localization.py stub             append missing keys to every non-English file, English text as placeholder
  scripts/localization.py sync-en          rewrite en.lproj from the sources (English = identity table)
  scripts/localization.py new <lang>       create <lang>.lproj with every key stubbed (then translate it)

Keys come from:
  * L("...") and NSLocalizedString("...") calls
  * string literals passed to the common SwiftUI initialisers and modifiers
    (Text, Button, Toggle, Label, Picker, Section, TextField, SecureField, Stepper,
    LabeledContent, DisclosureGroup, Menu, GroupBox, .help, .accessibilityLabel,
    .accessibilityHint, .accessibilityValue, .accessibilityAction(named:), .alert,
    .confirmationDialog, ...). SwiftUI looks these up in the app bundle by itself.

Literals with interpolation are not allowed there (their key depends on the argument
types). Use Text(verbatim:) for text that must not be translated, or L("... %@", x)
for text that must. Files listed in EXCLUDED_FILES are developer tools that stay in
English on purpose.
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCES = os.path.join(ROOT, "Apps", "GogglesView", "Sources", "GogglesView")
LOCALIZATION = os.path.join(ROOT, "Apps", "GogglesView", "BundleResources", "Localization")
TABLE = "Localizable.strings"
SOURCE_LANGUAGE = "en"

# Developer tools and files whose text stays English on purpose.
EXCLUDED_FILES = {
    "BenchmarkView.swift",
    "BenchmarkStats.swift",
    "BenchmarkSettingsSection.swift",
    "SelfTestView.swift",
    "SessionLogsView.swift",
    "DocShots.swift",
    "ShortcutsIntents.swift",
    "WebViewerPage.swift",
}

SWIFTUI_CALLS = (
    "Text|Button|Toggle|Label|Picker|Section|TextField|SecureField|Stepper|LabeledContent|"
    "DisclosureGroup|Menu|GroupBox|Link|ProgressView|Slider|DatePicker"
)
SWIFTUI_MODIFIERS = (
    r"\.help|\.accessibilityLabel|\.accessibilityHint|\.accessibilityValue|\.navigationTitle|"
    r"\.alert|\.confirmationDialog|\.accessibilityAction\(named:|\.accessibilityLabel"
)

STRING = r'"((?:[^"\\\n]|\\.)*)"'
RE_L = re.compile(r"(?<![A-Za-z0-9_.])(?:L|NSLocalizedString)\(\s*" + STRING)
RE_UI = re.compile(r"(?<![A-Za-z0-9_.])(?:" + SWIFTUI_CALLS + r")\(\s*" + STRING)
RE_MOD = re.compile(r"(?:" + SWIFTUI_MODIFIERS + r")\(\s*" + STRING)
RE_PROMPT = re.compile(r"prompt:\s*Text\(\s*" + STRING)
RE_NAMED = re.compile(r"named:\s*" + STRING)

# printf style specifiers, positional form included. A space is not accepted as a flag so that
# "100% of" is not read as a specifier.
RE_SPEC = re.compile(r"%(?:(\d+)\$)?[-+0#]*(?:\d+|\*)?(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSp])")


def unescape_swift(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "u" and i + 2 < len(s) and s[i + 2] == "{":
                j = s.index("}", i)
                out.append(chr(int(s[i + 3:j], 16)))
                i = j + 1
                continue
            out.append({"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def has_letters(s):
    return any(ch.isalpha() for ch in s)


def scan():
    """Returns (keys, problems). keys is an ordered list of (key, 'File.swift:line')."""
    keys, seen, problems = [], set(), []
    for name in sorted(os.listdir(SOURCES)):
        if not name.endswith(".swift") or name in EXCLUDED_FILES:
            continue
        path = os.path.join(SOURCES, name)
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        for no, line in enumerate(lines, 1):
            code = line.split("//")[0] if line.lstrip().startswith("//") else line
            if code.lstrip().startswith("///") or code.lstrip().startswith("//"):
                continue
            where = f"{name}:{no}"
            found = []
            for rx, kind in ((RE_L, "L"), (RE_UI, "ui"), (RE_MOD, "ui"), (RE_PROMPT, "ui"), (RE_NAMED, "ui")):
                for m in rx.finditer(code):
                    raw = m.group(1)
                    if "\\(" in raw:
                        problems.append(f"{where}: interpolated literal in {'L()' if kind == 'L' else 'a SwiftUI initialiser'} "
                                        f"(use L(\"... %@\", x) or Text(verbatim:)): \"{raw[:60]}\"")
                        continue
                    found.append((m.start(), unescape_swift(raw)))
            # a verbatim: Text(verbatim: "...") is not matched by RE_UI because of the label.
            for _, key in sorted(found):
                if not key or not has_letters(key):
                    continue
                if key not in seen:
                    seen.add(key)
                    keys.append((key, where))
    return keys, problems


def lint_ternaries():
    """Warnings for a string literal ternary directly inside a SwiftUI call (it may not be localized)."""
    out = []
    rx = re.compile(r"(?:" + SWIFTUI_CALLS + r"|" + SWIFTUI_MODIFIERS + r")\([^()\n]*\?[^()\n]*" + STRING + r"\s*:\s*" + STRING)
    for name in sorted(os.listdir(SOURCES)):
        if not name.endswith(".swift") or name in EXCLUDED_FILES:
            continue
        with open(os.path.join(SOURCES, name), encoding="utf-8") as f:
            for no, line in enumerate(f, 1):
                if line.lstrip().startswith("//"):
                    continue
                m = rx.search(line)
                if m and 'L("' not in line[m.start():m.end() + 1] and "systemImage" not in line and "systemName" not in line:
                    out.append(f"{name}:{no}: literal ternary in a SwiftUI call, wrap each branch in L(): {line.strip()[:90]}")
    return out


# ---------------------------------------------------------------- .strings files

RE_ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def parse_strings(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?m)^\s*//.*$", "", text)
    table = {}
    for m in RE_ENTRY.finditer(text):
        table[unescape_swift(m.group(1))] = unescape_swift(m.group(2))
    return table


def escape_strings(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def entry(key, value):
    return f'"{escape_strings(key)}" = "{escape_strings(value)}";\n'


def specs(s):
    """List of (position or None, kind) for the format specifiers in s."""
    t = s.replace("%%", "")
    out = []
    for m in RE_SPEC.finditer(t):
        conv = m.group(2)
        kind = {"@": "object", "s": "string", "S": "string", "c": "char", "C": "char", "p": "pointer"}.get(conv)
        if kind is None:
            kind = "float" if conv in "fFeEgG" else "int"
        out.append((int(m.group(1)) if m.group(1) else None, kind))
    return out


def spec_problem(key, value):
    a, b = specs(key), specs(value)
    if len(a) != len(b):
        return f"{len(a)} specifier(s) in the key, {len(b)} in the translation"
    kinds_a = [k for _, k in a]
    if any(p is not None for p, _ in b):
        if not all(p is not None for p, _ in b):
            return "mixes positional and plain specifiers"
        by_pos = {}
        for p, k in b:
            by_pos[p] = k
        if sorted(by_pos) != list(range(1, len(a) + 1)):
            return "positional indexes must be 1..%d, each once" % len(a)
        if [by_pos[i + 1] for i in range(len(a))] != kinds_a:
            return "specifier kinds differ from the key"
    elif [k for _, k in b] != kinds_a:
        return "specifier kinds differ from the key"
    return None


def languages():
    if not os.path.isdir(LOCALIZATION):
        return []
    return sorted(d[:-6] for d in os.listdir(LOCALIZATION) if d.endswith(".lproj"))


def lproj_path(lang):
    return os.path.join(LOCALIZATION, lang + ".lproj", TABLE)


def write_header(f, lang):
    f.write("/* GogglesView user interface strings (%s). The English text is the key. */\n" % lang)
    f.write("/* Check with scripts/localization.py check. See docs/localization.md. */\n\n")


# ---------------------------------------------------------------- commands

def cmd_extract():
    keys, problems = scan()
    for key, where in keys:
        print(f"{where}\t{key}")
    for p in problems:
        print("PROBLEM", p, file=sys.stderr)
    print(f"{len(keys)} keys", file=sys.stderr)
    return 1 if problems else 0


def cmd_check():
    keys, problems = scan()
    key_set = {k for k, _ in keys}
    errors = list(problems)
    for w in lint_ternaries():
        print("warning:", w)
    langs = languages()
    if SOURCE_LANGUAGE not in langs:
        errors.append(f"{SOURCE_LANGUAGE}.lproj is missing (run: scripts/localization.py sync-en)")
    for lang in langs:
        path = lproj_path(lang)
        if not os.path.exists(path):
            errors.append(f"{lang}.lproj has no {TABLE}")
            continue
        table = parse_strings(path)
        missing = [k for k, _ in keys if k not in table]
        extra = [k for k in table if k not in key_set]
        for k in missing:
            errors.append(f"[{lang}] missing: {k!r}")
        for k in extra:
            errors.append(f"[{lang}] extra (no longer in the sources): {k!r}")
        for k, v in table.items():
            if k in key_set:
                bad = spec_problem(k, v)
                if bad:
                    errors.append(f"[{lang}] format mismatch ({bad}): {k!r} -> {v!r}")
        print(f"{lang}: {len(table)} entries, {len(missing)} missing, {len(extra)} extra")
    print(f"{len(keys)} keys in the sources")
    for e in errors:
        print("error:", e)
    return 1 if errors else 0


def cmd_sync_en():
    keys, problems = scan()
    if problems:
        for p in problems:
            print("error:", p)
        return 1
    os.makedirs(os.path.dirname(lproj_path(SOURCE_LANGUAGE)), exist_ok=True)
    with open(lproj_path(SOURCE_LANGUAGE), "w", encoding="utf-8") as f:
        write_header(f, SOURCE_LANGUAGE)
        cur = None
        for key, where in keys:
            fname = where.split(":")[0]
            if fname != cur:
                f.write(f"/* {fname} */\n")
                cur = fname
            f.write(entry(key, key))
    print(f"wrote {len(keys)} keys to {lproj_path(SOURCE_LANGUAGE)}")
    return 0


def stub_lang(lang, keys):
    path = lproj_path(lang)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    table = parse_strings(path) if os.path.exists(path) else {}
    missing = [(k, w) for k, w in keys if k not in table]
    if not os.path.exists(path):
        with open(path, "w", encoding="utf-8") as f:
            write_header(f, lang)
    if missing:
        with open(path, "a", encoding="utf-8") as f:
            f.write("\n/* TODO: translate (English placeholder) */\n")
            for k, _ in missing:
                f.write(entry(k, k))
    print(f"{lang}: added {len(missing)} placeholder(s)")


def cmd_stub():
    keys, problems = scan()
    if problems:
        for p in problems:
            print("error:", p)
        return 1
    for lang in languages():
        if lang != SOURCE_LANGUAGE:
            stub_lang(lang, keys)
    return 0


def cmd_new(lang):
    keys, problems = scan()
    if problems:
        for p in problems:
            print("error:", p)
        return 1
    stub_lang(lang, keys)
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "extract":
        return cmd_extract()
    if len(argv) >= 2 and argv[1] == "check":
        return cmd_check()
    if len(argv) >= 2 and argv[1] == "stub":
        return cmd_stub()
    if len(argv) >= 2 and argv[1] == "sync-en":
        return cmd_sync_en()
    if len(argv) >= 3 and argv[1] == "new":
        return cmd_new(argv[2])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
