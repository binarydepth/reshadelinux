# shellcheck shell=bash
# SPDX-License-Identifier: GPL-2.0-or-later

# Inspect enabled preset values beside the matching uniforms from each ReShade effect.
function inspectReshadeParameters() {
    local _gamePath="$1" _output _status=0

    if [[ -f $_gamePath && ${_gamePath##*/} == ReShade.ini ]]; then
        _gamePath=$(dirname -- "$_gamePath")
    fi
    _output=$(python3 - "$_gamePath" <<'PYEOF'
import os
import re
import sys
from pathlib import Path


def fail(message):
    print(f"Could not inspect ReShade parameters: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_ini(path, ignore_errors=False):
    sections = {}
    section = ""
    try:
        with path.open(encoding="utf-8-sig") as stream:
            for raw_line in stream:
                line = raw_line.strip()
                if not line or line.startswith((";", "#")):
                    continue
                if line.startswith("[") and line.endswith("]"):
                    section = line[1:-1].strip()
                    sections.setdefault(section.lower(), {})
                elif section and "=" in line:
                    key, value = line.split("=", 1)
                    sections[section.lower()][key.strip()] = value.strip()
    except (OSError, UnicodeError) as error:
        if ignore_errors:
            return {}
        fail(f"cannot read '{path}': {error}")
    return sections


def ini_value(section, key):
    return next((value for name, value in section.items() if name.lower() == key.lower()), "")


def strip_comments(source):
    def preserve_lines(match):
        return "".join("\n" if character == "\n" else " " for character in match.group())
    return re.sub(r"/\*.*?\*/|//[^\n]*", preserve_lines, source, flags=re.DOTALL)


def annotation_values(annotation):
    values = {}
    for item in annotation.split(";"):
        key, separator, value = item.partition("=")
        if separator:
            values[key.strip().lower()] = value.strip().strip('"')
    return values


input_path = Path(sys.argv[1]).expanduser()
if input_path.is_file() and input_path.name.lower() == "reshade.ini":
    reshade_ini = input_path.resolve()
    game_path = reshade_ini.parent
elif input_path.is_dir():
    game_path = input_path.resolve()
    reshade_ini = game_path / "ReShade.ini"
else:
    fail(f"expected a game directory or its ReShade.ini file, got '{input_path}'")
if not reshade_ini.is_file():
    fail(f"'{reshade_ini}' was not found")

general = read_ini(reshade_ini).get("general", {})
preset_value = ini_value(general, "PresetPath").strip().strip('"')
if preset_value:
    preset_value = preset_value.replace("\\", os.sep)
    preset_path = Path(preset_value).expanduser()
    if not preset_path.is_absolute():
        preset_path = game_path / preset_path
else:
    preset_path = game_path / "ReShadePreset.ini"
if not preset_path.is_file() and not preset_value:
    candidates = []
    for candidate in sorted(game_path.glob("*.ini")):
        if candidate.name.lower() == "reshade.ini":
            continue
        candidate_general = read_ini(candidate, ignore_errors=True).get("general", {})
        if ini_value(candidate_general, "Techniques").strip():
            candidates.append(candidate)
    if len(candidates) == 1:
        preset_path = candidates[0]
    elif len(candidates) > 1:
        print("Multiple preset candidates found; set PresetPath in ReShade.ini or remove ambiguity:", file=sys.stderr)
        for candidate in candidates:
            print(f"  {candidate}", file=sys.stderr)
        raise SystemExit(1)
if not preset_path.is_file():
    print("__NO_RESHADE_PRESET_FOUND__")
    raise SystemExit(3)

preset_sections = read_ini(preset_path)
general = preset_sections.get("general", {})
techniques = [entry.strip() for entry in ini_value(general, "Techniques").split(",") if entry.strip()]
if not techniques:
    fail(f"'{preset_path}' does not list enabled ReShade techniques")

shader_dir = game_path / "ReShade_shaders" / "Merged" / "Shaders"
if not shader_dir.is_dir():
    fail(f"merged ReShade shader directory was not found: '{shader_dir}'")

print("ReShade parameter inspection")
print(f"Game: {game_path}")
print(f"Preset: {preset_path}")
print("Note: this reports ReShade preset values and source defaults; vkBasalt may not expose or honor them.")
print()

declaration = re.compile(
    r"\buniform\s+(?P<type>[A-Za-z_]\w*)\s+"
    r"(?P<name>[A-Za-z_]\w*)\s*"
    r"(?:<(?P<annotations>[^{}]*)>)?\s*"
    r"(?:=\s*(?P<default>[^;]+))?\s*;",
    re.DOTALL,
)
for entry in techniques:
    technique_name, separator, relative_path = entry.partition("@")
    relative_path = relative_path.strip().replace("\\", "/")
    if not separator or not technique_name.strip() or not relative_path.lower().endswith(".fx"):
        fail(f"cannot map enabled technique '{entry}' to a .fx file")
    effect_path = Path(relative_path)
    if effect_path.is_absolute() or ".." in effect_path.parts:
        fail(f"unsafe shader path in enabled technique '{entry}'")
    source_path = shader_dir / effect_path
    if not source_path.is_file():
        fail(f"shader file for enabled technique '{entry}' is missing: '{source_path}'")

    try:
        source = source_path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError) as error:
        fail(f"cannot read shader source '{source_path}': {error}")
    clean_source = strip_comments(source)
    effect_section = preset_sections.get(source_path.name.lower(), {})
    uniforms = list(declaration.finditer(clean_source))
    print(f"Technique: {technique_name}")
    print(f"Effect: {source_path}")
    if not uniforms:
        print("  No uniform declarations were recognized in this effect.")
    matched = set()
    for uniform in uniforms:
        name = uniform.group("name")
        matched.add(name.lower())
        annotations = annotation_values(uniform.group("annotations") or "")
        line_number = clean_source.count("\n", 0, uniform.start()) + 1
        print(f"  {name} ({uniform.group('type').strip()}, source line {line_number})")
        if "ui_label" in annotations:
            print(f"    Label: {annotations['ui_label']}")
        ui_options = [
            f"{key[3:]}={value}" for key, value in annotations.items()
            if key.startswith("ui_") and key not in ("ui_label", "ui_type")
        ]
        if ui_options:
            print(f"    UI: {', '.join(ui_options)}")
        default = (uniform.group("default") or "").strip()
        print(f"    Source default: {default or '<none declared>'}")
        print(f"    Preset value: {effect_section.get(name, '<not saved; source default applies>')}")

    unmatched = [
        f"{name}={value}" for name, value in effect_section.items()
        if name.lower() not in matched
    ]
    if unmatched:
        print(f"  Preset entries without a recognized uniform: {', '.join(unmatched)}")
    print()
PYEOF
    ) || _status=$?
    if [[ $_status -eq 3 && $_output == "__NO_RESHADE_PRESET_FOUND__" ]]; then
        _selectInstalledVkbasaltEffects "$_gamePath"
        return $?
    fi
    [[ $_status -eq 0 ]] || {
        printf '%s\n' "$_output"
        return "$_status"
    }
    printf '%s\n' "$_output"
}
