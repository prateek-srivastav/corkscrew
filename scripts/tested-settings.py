#!/usr/bin/env python3
"""Adds the settings from a Game report to the tested list.

Corkscrew fills in the report's "Corkscrew settings" field when a player shares the settings of a
Steam game that ran well. A maintainer's "tested" label on the report runs this script (from
.github/workflows/tested-settings.yml), which checks the settings, writes them into the tested list
(Packages/GameCore/Sources/GameCore/Stores/tested.json), and writes the pull request's title and text.

The report is untrusted: only known settings with safe values are taken, the entry isn't listed in
the library, and a game tested here (an entry without "source") is never replaced.

Usage: ISSUE_BODY=… ISSUE_URL=… tested-settings.py --title-out FILE --body-out FILE [--error-out FILE]
"""

import argparse
import json
import os
import re
import sys
import unicodedata
from pathlib import Path

LIST_FILE = Path(__file__).resolve().parent.parent / "Packages/GameCore/Sources/GameCore/Stores/tested.json"

SETTINGS_HEADING = "Corkscrew settings"
BACKENDS = {"d3dmetal", "dxmt", "dxvk", "wined3d"}
SWITCHES = ["metalFX", "retinaMode", "advertiseAVX", "steamOverlay", "modHooks"]
RESULTS = {"Plays well", "Plays, with issues"}

ARGUMENT = re.compile(r"[A-Za-z0-9_.,:=+\-]{1,64}")
ENV_NAME = re.compile(r"[A-Z][A-Z0-9_]{0,63}")
ENV_VALUE = re.compile(r"[A-Za-z0-9_.,:;=+\- ]{0,128}")
# Variables that pick what runs or where files are: never from a report.
ENV_DENIED_PREFIXES = ("DYLD_", "LD_", "WINE", "CX_", "CORKSCREW_")
ENV_DENIED = {"PATH", "HOME", "TMPDIR", "USER", "SHELL", "PYTHONPATH", "SSL_CERT_FILE", "CURL_CA_BUNDLE"}
# Allowed after all, since games need them: which DLLs Wine loads from the game's folder.
ENV_ALLOWED = {"WINEDLLOVERRIDES", "WINEESYNC", "WINEMSYNC", "WINE_LARGE_ADDRESS_AWARE"}


class Rejected(Exception):
    pass


def field(body, heading):
    """The text under a form field's "### heading", up to the next field. When that is one code
    block (the relay writes the player's text in one, the form the Corkscrew settings), what's in it."""
    match = re.search(r"^###\s+" + re.escape(heading) + r"[^\n]*\n(.*?)(?=^###\s|\Z)", body, re.M | re.S)
    value = match.group(1).strip() if match else ""
    fenced = re.fullmatch(r"(`{3,})[^`\n]*\n(.*?)\n\1", value, re.S)
    if fenced:
        value = fenced.group(2).strip()
    return "" if value == "_No response_" else value


def plain(text, limit):
    """One line of ordinary text, without control or formatting characters (bidi overrides can hide code)."""
    text = "".join(c for c in " ".join(str(text).split()) if unicodedata.category(c) not in ("Cc", "Cf", "Co", "Cs"))
    return text[:limit].rstrip()


def settings_from(body):
    block = field(body, SETTINGS_HEADING)
    match = re.search(r"```(?:json)?\s*\n(.*?)\n\s*```", block, re.S)
    text = match.group(1) if match else block
    if not text:
        raise Rejected("The report has no Corkscrew settings. Only reports that Corkscrew filled in can be added.")
    try:
        report = json.loads(text)
    except json.JSONDecodeError:
        raise Rejected("The Corkscrew settings aren't valid JSON.")
    if not isinstance(report, dict):
        raise Rejected("The Corkscrew settings aren't a JSON object.")
    return report


def checked_profile(profile):
    if not isinstance(profile, dict):
        raise Rejected("The settings have no profile.")
    unknown = set(profile) - {"backendOverride", "arguments", "environment", *SWITCHES}
    if unknown:
        # Not named: the error goes into an issue comment, and the names come from the report.
        raise Rejected("The profile has settings that aren't shared from Corkscrew.")
    checked = {}
    backend = profile.get("backendOverride")
    if backend is not None:
        if backend not in BACKENDS:
            raise Rejected("The graphics backend isn't one Corkscrew has.")
        checked["backendOverride"] = backend
    for name in SWITCHES:
        if name in profile:
            if not isinstance(profile[name], bool):
                raise Rejected(f"{name} isn't true or false.")
            checked[name] = profile[name]
    # Defaults are left out, like the entries written by hand.
    if checked.get("advertiseAVX") is True:
        del checked["advertiseAVX"]
    for name in ("metalFX", "retinaMode", "steamOverlay", "modHooks"):
        if checked.get(name) is False:
            del checked[name]

    arguments = profile.get("arguments", [])
    if not isinstance(arguments, list) or len(arguments) > 8:
        raise Rejected("The launch arguments aren't a short list.")
    for argument in arguments:
        if not isinstance(argument, str) or not ARGUMENT.fullmatch(argument):
            raise Rejected("A launch argument has characters that aren't allowed (letters, digits and - _ . , : = + only).")
    if arguments:
        checked["arguments"] = arguments

    environment = profile.get("environment", {})
    if not isinstance(environment, dict) or len(environment) > 8:
        raise Rejected("The environment variables aren't a short list.")
    for name, value in environment.items():
        if not ENV_NAME.fullmatch(name) or not isinstance(value, str) or not ENV_VALUE.fullmatch(value):
            raise Rejected("An environment variable has characters that aren't allowed.")
        if name not in ENV_ALLOWED and (name in ENV_DENIED or name.startswith(ENV_DENIED_PREFIXES)):
            raise Rejected(f"The environment variable {name} can't come from a report.")
    if environment:
        checked["environment"] = dict(sorted(environment.items()))
    return checked


def entry_from(body, source):
    result = field(body, "Result")
    if result not in RESULTS:
        raise Rejected("The report doesn't say the game plays.")
    report = settings_from(body)
    app_id = str(report.get("appID", ""))
    if not re.fullmatch(r"[0-9]{1,10}", app_id):
        raise Rejected("The Steam app ID isn't a number.")
    name = plain(report.get("name", ""), 100)
    if not name:
        raise Rejected("The game has no name.")
    entry = {"appID": app_id, "name": name, "listed": False, "profile": checked_profile(report.get("profile"))}
    notes = "; ".join(filter(None, [plain(field(body, "Settings and performance"), 300),
                                    plain(field(body, "Issues and workarounds"), 300)]))
    entry["notes"] = (f"{result}. " + notes).strip() if notes else f"{result}."
    entry["source"] = source
    return entry


def format_list(entries):
    """The layout of the hand-written list: one key per line, the profile on one line."""
    def value(v):
        return json.dumps(v, ensure_ascii=False)
    lines = ["["]
    for index, entry in enumerate(entries):
        lines.append("  {")
        keys = list(entry)
        for k, key in enumerate(keys):
            lines.append(f"    {value(key)}: {value(entry[key])}" + ("," if k < len(keys) - 1 else ""))
        lines.append("  }" + ("," if index < len(entries) - 1 else ""))
    lines.append("]")
    return "\n".join(lines) + "\n"


def add(entry):
    """Adds or replaces the entry. Returns the replaced one, if any."""
    entries = json.loads(LIST_FILE.read_text())
    old = next((e for e in entries if e.get("appID") == entry["appID"]), None)
    if old is not None and not old.get("source"):
        raise Rejected(f"{old['name']} is tested on the developer's Mac; its settings are changed by hand, not from a report.")
    if old is not None:
        entry["listed"] = old.get("listed", False)
        entries[entries.index(old)] = entry
    else:
        entries.append(entry)
    LIST_FILE.write_text(format_list(entries))
    return old


def describe(profile):
    names = {"d3dmetal": "D3DMetal", "dxmt": "DXMT", "dxvk": "DXVK", "wined3d": "WineD3D"}
    lines = [f"- Graphics: {names.get(profile.get('backendOverride'), 'Automatic')}"]
    lines += [f"- {name}: on" for name in ("metalFX", "retinaMode", "steamOverlay") if profile.get(name)]
    if profile.get("modHooks"):
        lines.append("- **modHooks: on (a mod hooks the game's graphics: check which)**")
    if profile.get("advertiseAVX") is False:
        lines.append("- advertiseAVX: off")
    if profile.get("arguments"):
        lines.append("- **Launch arguments (check them):** `" + " ".join(profile["arguments"]) + "`")
    for name, value in profile.get("environment", {}).items():
        lines.append(f"- **Environment (check it):** `{name}={value}`")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--title-out", required=True)
    parser.add_argument("--body-out", required=True)
    parser.add_argument("--error-out")
    args = parser.parse_args()
    body = os.environ.get("ISSUE_BODY", "").replace("\r\n", "\n")
    source = os.environ.get("ISSUE_URL", "")
    if not re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+/issues/[0-9]+", source):
        raise SystemExit("ISSUE_URL isn't an issue link.")
    try:
        entry = entry_from(body, source)
        old = add(entry)
    except Rejected as error:
        if args.error_out:
            Path(args.error_out).write_text(str(error))
        print(error, file=sys.stderr)
        return 1
    number = source.rsplit("/", 1)[1]
    title = f"{'Update' if old else 'Add'} tested settings for {entry['name']}"
    Path(args.title_out).write_text(title)
    Path(args.body_out).write_text(
        f"From #{number}, which a maintainer labeled **tested**. Closes #{number}.\n\n"
        f"**{entry['name']}** ([Steam app {entry['appID']}](https://store.steampowered.com/app/{entry['appID']}/))\n\n"
        f"{describe(entry['profile'])}\n\n"
        f"Notes: {entry['notes']}\n\n"
        + ("The entry replaces the one from " + old["source"] + ".\n\n" if old else "")
        + "Not listed in the library before it's installed: set `listed` to `true` after playing it here.\n"
        "Pull requests made by Actions don't start CI: close and reopen this one to run the tests.\n")
    print(f"{title}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
