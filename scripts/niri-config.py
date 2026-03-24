#!/usr/bin/env python3
"""
niri-config.py — Niri compositor configuration helper for iNiR settings UI.

SAFETY: All persist/set commands do SURGICAL edits on existing KDL files.
They NEVER rewrite files from scratch. Unknown settings, comments, and
structure are always preserved.

Commands:
  outputs              JSON array of outputs with modes/capabilities
  apply-output NAME    Apply temporary output changes via niri msg
  persist-output NAME  Write output config to KDL config.d/15-outputs.kdl
  get-input            Read current input config from KDL
  get-layout           Read current layout config from KDL
  get-animations       Read current animation config from KDL
  set SECTION KEY VAL  Surgical edit of a single config value
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path


def get_niri_config_dir():
    """Resolve the Niri config directory."""
    xdg = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    return Path(xdg) / "niri"


def run_niri(*args):
    """Run niri msg and return output."""
    try:
        r = subprocess.run(
            ["niri", "msg", *args], capture_output=True, text=True, timeout=5
        )
        return r.stdout.strip(), r.returncode
    except Exception as e:
        return str(e), 1


# ─── Outputs ──────────────────────────────────────────────────────────


def cmd_outputs():
    """Get structured output info from Niri."""
    raw, rc = run_niri("-j", "outputs")
    if rc != 0:
        print(json.dumps({"error": f"niri msg failed: {raw}"}))
        return 1

    data = json.loads(raw)
    result = []

    for name, out in data.items():
        modes = out.get("modes", [])
        current_idx = out.get("current_mode", 0)
        logical = out.get("logical") or {}

        res_map = {}
        for i, m in enumerate(modes):
            key = f"{m['width']}x{m['height']}"
            rate = round(m["refresh_rate"] / 1000, 2)
            if key not in res_map:
                res_map[key] = {
                    "width": m["width"],
                    "height": m["height"],
                    "rates": [],
                    "preferred": m.get("is_preferred", False),
                }
            if rate not in [r["rate"] for r in res_map[key]["rates"]]:
                res_map[key]["rates"].append(
                    {
                        "rate": rate,
                        "mode_index": i,
                        "preferred": m.get("is_preferred", False),
                    }
                )
            elif m.get("is_preferred", False):
                res_map[key]["preferred"] = True

        current_mode = modes[current_idx] if current_idx < len(modes) else None
        current_res = ""
        current_rate = 0.0
        if current_mode:
            current_res = f"{current_mode['width']}x{current_mode['height']}"
            current_rate = round(current_mode["refresh_rate"] / 1000, 2)

        result.append(
            {
                "name": name,
                "make": out.get("make", ""),
                "model": out.get("model", ""),
                "serial": out.get("serial", ""),
                "physical_size": out.get("physical_size", [0, 0]),
                "current_resolution": current_res,
                "current_rate": current_rate,
                "scale": logical.get("scale", 1.0),
                "transform": logical.get("transform", "Normal"),
                "position": {"x": logical.get("x", 0), "y": logical.get("y", 0)},
                "vrr_supported": out.get("vrr_supported", False),
                "vrr_enabled": out.get("vrr_enabled", False),
                "resolutions": list(res_map.values()),
            }
        )

    print(json.dumps(result))
    return 0


def cmd_apply_output(args):
    """Apply temporary output changes via niri msg output."""
    if len(args) < 2:
        print(json.dumps({"error": "Usage: apply-output <name> <key=value>..."}))
        return 1

    output_name = args[0]
    changes = args[1:]
    results = []

    for change in changes:
        key, _, value = change.partition("=")
        if not value:
            results.append({"key": key, "error": "missing value"})
            continue

        if key == "mode":
            out, rc = run_niri("output", output_name, "mode", value)
        elif key == "scale":
            out, rc = run_niri("output", output_name, "scale", value)
        elif key == "transform":
            out, rc = run_niri("output", output_name, "transform", value)
        elif key == "vrr":
            out, rc = run_niri("output", output_name, "vrr", value)
        elif key == "position":
            parts = value.split(",")
            if len(parts) == 2:
                out, rc = run_niri(
                    "output", output_name, "position", "set", parts[0], parts[1]
                )
            else:
                out, rc = run_niri("output", output_name, "position", "auto")
        elif key == "dpms":
            out, rc = run_niri("output", output_name, value)
        else:
            results.append({"key": key, "error": "unknown key"})
            continue

        results.append({"key": key, "value": value, "success": rc == 0, "output": out})

    print(json.dumps({"results": results}))
    return 0


def cmd_persist_output(args):
    """Write output config to KDL config.d/15-outputs.kdl using surgical edits."""
    if len(args) < 2:
        print(json.dumps({"error": "Usage: persist-output <name> <key=value>..."}))
        return 1

    output_name = args[0]
    changes = dict(c.split("=", 1) for c in args[1:] if "=" in c)

    config_dir = get_niri_config_dir()
    outputs_file = config_dir / "config.d" / "15-outputs.kdl"
    outputs_file.parent.mkdir(parents=True, exist_ok=True)

    existing = outputs_file.read_text() if outputs_file.exists() else ""

    # Find existing output block for this name
    pattern = rf'(output\s+"{re.escape(output_name)}"\s*\{{)(.*?)(\}})'
    match = re.search(pattern, existing, re.DOTALL)

    if match:
        # Surgical edit within existing block
        block_content = match.group(2)

        for key, value in changes.items():
            if key == "mode":
                block_content = _set_in_block(block_content, "mode", f'"{value}"')
            elif key == "scale":
                block_content = _set_in_block(block_content, "scale", value)
            elif key == "transform":
                block_content = _set_in_block(block_content, "transform", f'"{value}"')
            elif key == "vrr":
                if value == "off":
                    # Remove variable-refresh-rate line
                    block_content = re.sub(
                        r"\n?\s*variable-refresh-rate[^\n]*", "", block_content
                    )
                elif value == "on-demand":
                    block_content = _set_in_block(
                        block_content, "variable-refresh-rate", "on-demand=true"
                    )
                else:
                    block_content = _set_in_block(
                        block_content, "variable-refresh-rate", ""
                    )
            elif key == "position":
                parts = value.split(",")
                if len(parts) == 2:
                    block_content = _set_in_block(
                        block_content, "position", f"x={parts[0]} y={parts[1]}"
                    )

        result = (
            existing[: match.start()]
            + match.group(1)
            + block_content
            + match.group(3)
            + existing[match.end() :]
        )
    else:
        # Create new output block
        lines = []
        if "mode" in changes:
            lines.append(f'    mode "{changes["mode"]}"')
        if "scale" in changes:
            lines.append(f"    scale {changes['scale']}")
        if "transform" in changes:
            lines.append(f'    transform "{changes["transform"]}"')
        if "position" in changes:
            parts = changes["position"].split(",")
            if len(parts) == 2:
                lines.append(f"    position x={parts[0]} y={parts[1]}")
        if "vrr" in changes:
            vrr_val = changes["vrr"]
            if vrr_val == "on-demand":
                lines.append("    variable-refresh-rate on-demand=true")
            elif vrr_val != "off":
                lines.append("    variable-refresh-rate")

        new_block = f'output "{output_name}" {{\n' + "\n".join(lines) + "\n}"

        if existing.strip():
            result = existing.rstrip() + "\n\n" + new_block + "\n"
        else:
            result = new_block + "\n"

    outputs_file.write_text(result)
    print(json.dumps({"success": True, "file": str(outputs_file)}))
    return 0


def _set_in_block(block_content, key, value):
    """Set a key=value inside a KDL block, preserving other content.
    If key exists, replace the line. If not, append it."""
    # Escape key for regex (handles hyphens)
    escaped = re.escape(key)
    # Try to replace existing line
    pattern = rf"(\n?\s*){escaped}\b[^\n]*"
    if re.search(pattern, block_content):
        if value:
            return re.sub(pattern, rf"\g<1>{key} {value}", block_content, count=1)
        else:
            # Flag-style (no value) like variable-refresh-rate
            return re.sub(pattern, rf"\g<1>{key}", block_content, count=1)
    else:
        # Append
        indent = "    "
        if value:
            return block_content.rstrip() + f"\n{indent}{key} {value}\n"
        else:
            return block_content.rstrip() + f"\n{indent}{key}\n"


# ─── Input ────────────────────────────────────────────────────────────


def cmd_get_input():
    """Read current input config from KDL file."""
    config_dir = get_niri_config_dir()
    input_file = config_dir / "config.d" / "10-input-and-cursor.kdl"

    result = {
        "keyboard": {
            "layout": "us",
            "repeat_delay": 600,
            "repeat_rate": 25,
            "numlock": False,
        },
        "touchpad": {
            "tap": False,
            "natural_scroll": False,
            "dwt": False,
            "accel_profile": "adaptive",
            "accel_speed": 0.0,
        },
        "mouse": {
            "natural_scroll": False,
            "accel_profile": "adaptive",
            "accel_speed": 0.0,
        },
        "cursor": {"theme": "", "size": 24, "hide_when_typing": False},
    }

    if not input_file.exists():
        print(json.dumps(result))
        return 0

    content = input_file.read_text()

    # Extract subsections — handle nested braces properly
    input_block = _extract_block(content, "input")
    cursor_block = _extract_block(content, "cursor")

    if input_block:
        kb_block = _extract_block(input_block, "keyboard")
        tp_block = _extract_block(input_block, "touchpad")
        mouse_block = _extract_block(input_block, "mouse")

        # Keyboard
        if kb_block:
            xkb_block = _extract_block(kb_block, "xkb")
            if xkb_block:
                m = re.search(r'layout\s+"([^"]*)"', xkb_block)
                if m:
                    result["keyboard"]["layout"] = m.group(1)
            m = re.search(r"repeat-delay\s+(\d+)", kb_block)
            if m:
                result["keyboard"]["repeat_delay"] = int(m.group(1))
            m = re.search(r"repeat-rate\s+(\d+)", kb_block)
            if m:
                result["keyboard"]["repeat_rate"] = int(m.group(1))
            # numlock is a standalone flag
            result["keyboard"]["numlock"] = bool(
                re.search(r"^\s*numlock\s*$", kb_block, re.MULTILINE)
            )

        # Touchpad
        if tp_block:
            result["touchpad"]["tap"] = bool(
                re.search(r"^\s*tap\s*$", tp_block, re.MULTILINE)
            )
            result["touchpad"]["natural_scroll"] = bool(
                re.search(r"^\s*natural-scroll\s*$", tp_block, re.MULTILINE)
            )
            result["touchpad"]["dwt"] = bool(
                re.search(r"^\s*dwt\s*$", tp_block, re.MULTILINE)
            )
            m = re.search(r'accel-profile\s+"([^"]*)"', tp_block)
            if m:
                result["touchpad"]["accel_profile"] = m.group(1)
            m = re.search(r"accel-speed\s+([\d.-]+)", tp_block)
            if m:
                result["touchpad"]["accel_speed"] = float(m.group(1))

        # Mouse
        if mouse_block:
            m = re.search(r'accel-profile\s+"([^"]*)"', mouse_block)
            if m:
                result["mouse"]["accel_profile"] = m.group(1)
            result["mouse"]["natural_scroll"] = bool(
                re.search(r"^\s*natural-scroll\s*$", mouse_block, re.MULTILINE)
            )
            m = re.search(r"accel-speed\s+([\d.-]+)", mouse_block)
            if m:
                result["mouse"]["accel_speed"] = float(m.group(1))

    # Cursor (top-level section, not inside input)
    if cursor_block:
        m = re.search(r'xcursor-theme\s+"([^"]*)"', cursor_block)
        if m:
            result["cursor"]["theme"] = m.group(1)
        m = re.search(r"xcursor-size\s+(\d+)", cursor_block)
        if m:
            result["cursor"]["size"] = int(m.group(1))
        result["cursor"]["hide_when_typing"] = bool(
            re.search(r"^\s*hide-when-typing\s*$", cursor_block, re.MULTILINE)
        )

    print(json.dumps(result))
    return 0


def _extract_block(content, section_name):
    """Extract the content of a top-level block { ... } handling nested braces.
    Returns the content BETWEEN the outermost braces, or None."""
    pattern = rf"(?:^|\n)\s*{re.escape(section_name)}\s*\{{"
    match = re.search(pattern, content)
    if not match:
        return None

    # Find matching closing brace
    start = match.end()
    depth = 1
    i = start
    while i < len(content) and depth > 0:
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
        i += 1

    if depth == 0:
        return content[start : i - 1]
    return None


# ─── Layout ───────────────────────────────────────────────────────────


def cmd_get_layout():
    """Read current layout config from KDL file."""
    config_dir = get_niri_config_dir()
    layout_file = config_dir / "config.d" / "20-layout-and-overview.kdl"

    result = {
        "gaps": 16,
        "center_focused": "never",
        "border": {"enabled": False, "width": 4},
        "focus_ring": {"enabled": True, "width": 4},
        "shadow": {"enabled": False},
        "overview_zoom": 0.7,
    }

    if not layout_file.exists():
        print(json.dumps(result))
        return 0

    content = layout_file.read_text()
    layout_block = _extract_block(content, "layout")

    if layout_block:
        m = re.search(r"gaps\s+([\d.]+)", layout_block)
        if m:
            result["gaps"] = int(float(m.group(1)))

        m = re.search(r'center-focused-column\s+"([^"]*)"', layout_block)
        if m:
            result["center_focused"] = m.group(1)

        # Subsections with on/off flags
        for section in ["border", "focus-ring", "shadow"]:
            block = _extract_block(layout_block, section)
            if block is not None:
                py_key = section.replace("-", "_")
                # "off" on its own line means disabled
                has_off = bool(re.search(r"^\s*off\s*$", block, re.MULTILINE))
                result[py_key]["enabled"] = not has_off
                m = re.search(r"width\s+(\d+)", block)
                if m and "width" in result[py_key]:
                    result[py_key]["width"] = int(m.group(1))

    overview_block = _extract_block(content, "overview")
    if overview_block:
        m = re.search(r"zoom\s+([\d.]+)", overview_block)
        if m:
            result["overview_zoom"] = float(m.group(1))

    print(json.dumps(result))
    return 0


# ─── Animations ───────────────────────────────────────────────────────


def cmd_get_animations():
    """Read current animation config from KDL file."""
    config_dir = get_niri_config_dir()
    anim_file = config_dir / "config.d" / "60-animations.kdl"

    result = {
        "enabled": True,
        "slowdown": 1.0,
    }

    if not anim_file.exists():
        print(json.dumps(result))
        return 0

    content = anim_file.read_text()
    anim_block = _extract_block(content, "animations")

    if anim_block:
        # "off" on its own line at top level means all disabled
        result["enabled"] = not bool(
            re.search(r"^\s*off\s*$", anim_block, re.MULTILINE)
        )
        m = re.search(r"slowdown\s+([\d.]+)", anim_block)
        if m:
            result["slowdown"] = float(m.group(1))

    print(json.dumps(result))
    return 0


# ─── Surgical Set ─────────────────────────────────────────────────────


def cmd_set(args):
    """Surgical edit of a single config value.

    Usage: set <section> <key> <value>

    Sections and keys:
      input  keyboard.layout "es"
      input  keyboard.repeat-delay 250
      input  keyboard.repeat-rate 50
      input  keyboard.numlock on|off
      input  touchpad.tap on|off
      input  touchpad.natural-scroll on|off
      input  touchpad.dwt on|off
      input  touchpad.accel-profile "flat"|"adaptive"
      input  touchpad.accel-speed -1.0..1.0
      input  mouse.accel-profile "flat"|"adaptive"
      input  mouse.natural-scroll on|off
      input  mouse.accel-speed -1.0..1.0
      input  cursor.xcursor-theme "name"
      input  cursor.xcursor-size 24
      input  cursor.hide-when-typing on|off
      layout gaps 25
      layout center-focused-column "never"|"always"|"on-overflow"
      layout border.enabled on|off
      layout border.width 4
      layout focus-ring.enabled on|off
      layout focus-ring.width 4
      layout shadow.enabled on|off
      layout overview.zoom 0.7
      animations enabled on|off
      animations slowdown 1.0
      output <name>.<key> <value>
    """
    if len(args) < 3:
        print(json.dumps({"error": "Usage: set <section> <key> <value>"}))
        return 1

    section = args[0]
    key = args[1]
    value = args[2]

    config_dir = get_niri_config_dir()

    if section == "input":
        return _set_input(config_dir, key, value)
    elif section == "layout":
        return _set_layout(config_dir, key, value)
    elif section == "animations":
        return _set_animations(config_dir, key, value)
    elif section == "output":
        # output HDMI-A-2.mode 1920x1080@74.973
        parts = key.split(".", 1)
        if len(parts) != 2:
            print(json.dumps({"error": "output key must be <name>.<prop>"}))
            return 1
        return cmd_persist_output([parts[0], f"{parts[1]}={value}"])
    else:
        print(json.dumps({"error": f"Unknown section: {section}"}))
        return 1


def _set_input(config_dir, key, value):
    """Surgical edit in 10-input-and-cursor.kdl."""
    input_file = config_dir / "config.d" / "10-input-and-cursor.kdl"
    if not input_file.exists():
        print(json.dumps({"error": "input config file not found"}))
        return 1

    content = input_file.read_text()
    parts = key.split(".", 1)

    if len(parts) != 2:
        print(json.dumps({"error": f"key must be section.property, got: {key}"}))
        return 1

    subsection, prop = parts

    if subsection == "keyboard":
        if prop == "layout":
            # Replace layout "X" inside xkb block
            content = re.sub(
                r'(layout\s+)"[^"]*"', rf'\g<1>"{value}"', content, count=1
            )
        elif prop in ("repeat-delay", "repeat-rate"):
            content = re.sub(
                rf"({re.escape(prop)}\s+)\d+", rf"\g<1>{value}", content, count=1
            )
        elif prop == "numlock":
            content = _toggle_flag(content, "keyboard", "numlock", value == "on")
        else:
            print(json.dumps({"error": f"Unknown keyboard prop: {prop}"}))
            return 1

    elif subsection == "touchpad":
        if prop in ("tap", "natural-scroll", "dwt", "dwtp"):
            content = _toggle_flag(content, "touchpad", prop, value == "on")
        elif prop == "accel-profile":
            content = _set_value_in_subsection(
                content, "touchpad", "accel-profile", f'"{value}"'
            )
        elif prop == "accel-speed":
            content = _set_value_in_subsection(
                content, "touchpad", "accel-speed", value
            )
        else:
            print(json.dumps({"error": f"Unknown touchpad prop: {prop}"}))
            return 1

    elif subsection == "mouse":
        if prop == "natural-scroll":
            content = _toggle_flag(content, "mouse", prop, value == "on")
        elif prop == "accel-profile":
            content = _set_value_in_subsection(
                content, "mouse", "accel-profile", f'"{value}"'
            )
        elif prop == "accel-speed":
            content = _set_value_in_subsection(content, "mouse", "accel-speed", value)
        else:
            print(json.dumps({"error": f"Unknown mouse prop: {prop}"}))
            return 1

    elif subsection == "cursor":
        if prop == "xcursor-theme":
            content = re.sub(
                r'(xcursor-theme\s+)"[^"]*"', rf'\g<1>"{value}"', content, count=1
            )
        elif prop == "xcursor-size":
            content = re.sub(
                r"(xcursor-size\s+)\d+", rf"\g<1>{value}", content, count=1
            )
        elif prop == "hide-when-typing":
            content = _toggle_flag(content, "cursor", "hide-when-typing", value == "on")
        else:
            print(json.dumps({"error": f"Unknown cursor prop: {prop}"}))
            return 1
    else:
        print(json.dumps({"error": f"Unknown input subsection: {subsection}"}))
        return 1

    input_file.write_text(content)
    print(json.dumps({"success": True, "file": str(input_file)}))
    return 0


def _set_layout(config_dir, key, value):
    """Surgical edit in 20-layout-and-overview.kdl."""
    layout_file = config_dir / "config.d" / "20-layout-and-overview.kdl"
    if not layout_file.exists():
        print(json.dumps({"error": "layout config file not found"}))
        return 1

    content = layout_file.read_text()

    if key == "gaps":
        content = re.sub(r"(gaps\s+)[\d.]+", rf"\g<1>{value}", content, count=1)

    elif key == "center-focused-column":
        content = re.sub(
            r'(center-focused-column\s+)"[^"]*"',
            rf'\g<1>"{value}"',
            content,
            count=1,
        )

    elif key == "overview.zoom" or key == "overview-zoom":
        # overview zoom is in a separate top-level block
        content = re.sub(r"(zoom\s+)[\d.]+", rf"\g<1>{value}", content, count=1)

    elif "." in key:
        subsection, prop = key.split(".", 1)

        if prop == "enabled":
            # Toggle off/on flag inside a subsection block
            content = _toggle_subsection_enabled(content, subsection, value == "on")
        elif prop == "width":
            content = _set_value_in_subsection(content, subsection, "width", value)
        else:
            print(json.dumps({"error": f"Unknown layout sub-prop: {key}"}))
            return 1

    else:
        print(json.dumps({"error": f"Unknown layout key: {key}"}))
        return 1

    layout_file.write_text(content)
    print(json.dumps({"success": True, "file": str(layout_file)}))
    return 0


def _set_animations(config_dir, key, value):
    """Surgical edit in 60-animations.kdl."""
    anim_file = config_dir / "config.d" / "60-animations.kdl"
    if not anim_file.exists():
        print(json.dumps({"error": "animations config file not found"}))
        return 1

    content = anim_file.read_text()

    if key == "enabled":
        # Add or remove "off" flag at top of animations block
        anim_block = _extract_block(content, "animations")
        if anim_block is None:
            print(json.dumps({"error": "animations block not found"}))
            return 1

        has_off = bool(re.search(r"^\s*off\s*$", anim_block, re.MULTILINE))

        if value == "on" and has_off:
            # Remove the "off" line
            content = re.sub(
                r"(animations\s*\{)\s*\n\s*off\s*\n",
                r"\g<1>\n",
                content,
                count=1,
            )
        elif value == "off" and not has_off:
            # Add "off" right after opening brace
            content = re.sub(
                r"(animations\s*\{)\s*\n",
                r"\g<1>\n    off\n",
                content,
                count=1,
            )

    elif key == "slowdown":
        anim_block = _extract_block(content, "animations")
        if anim_block and "slowdown" in anim_block:
            content = re.sub(r"(slowdown\s+)[\d.]+", rf"\g<1>{value}", content, count=1)
        else:
            # Add slowdown after opening brace
            content = re.sub(
                r"(animations\s*\{)\s*\n",
                rf"\g<1>\n    slowdown {value}\n",
                content,
                count=1,
            )

    else:
        print(json.dumps({"error": f"Unknown animations key: {key}"}))
        return 1

    anim_file.write_text(content)
    print(json.dumps({"success": True, "file": str(anim_file)}))
    return 0


# ─── Surgical helpers ─────────────────────────────────────────────────


def _toggle_flag(content, parent_section, flag_name, enable):
    """Toggle a standalone flag (like `tap`, `natural-scroll`, `numlock`)
    inside a KDL subsection. Enable=True adds/uncomments, Enable=False
    removes/comments the flag line."""
    escaped_flag = re.escape(flag_name)

    # Find the parent section block boundaries
    block = _extract_block(content, parent_section)
    if block is None:
        return content

    # Find the block in the original content to know where to edit
    block_pattern = rf"({re.escape(parent_section)}\s*\{{)(.*?)(\}})"
    block_match = re.search(block_pattern, content, re.DOTALL)
    if not block_match:
        return content

    block_content = block_match.group(2)

    # Check if flag exists (uncommented)
    has_flag = bool(re.search(rf"^\s*{escaped_flag}\s*$", block_content, re.MULTILINE))
    # Check if flag exists commented out
    has_commented = bool(
        re.search(rf"^\s*//\s*{escaped_flag}\s*$", block_content, re.MULTILINE)
    )

    if enable and has_flag:
        return content  # Already enabled
    elif enable and has_commented:
        # Uncomment
        new_block = re.sub(
            rf"^(\s*)//\s*{escaped_flag}\s*$",
            rf"\g<1>{flag_name}",
            block_content,
            flags=re.MULTILINE,
            count=1,
        )
    elif enable:
        # Add flag — find good insertion point (before closing brace)
        new_block = block_content.rstrip() + f"\n        {flag_name}\n    "
    elif not enable and has_flag:
        new_block = re.sub(
            rf"^[ \t]*{escaped_flag}[ \t]*\n",
            "",
            block_content,
            flags=re.MULTILINE,
            count=1,
        )
    elif not enable and has_commented:
        return content  # Already disabled
    else:
        return content  # Flag doesn't exist and we want it off — nothing to do

    return (
        content[: block_match.start()]
        + block_match.group(1)
        + new_block
        + block_match.group(3)
        + content[block_match.end() :]
    )


def _set_value_in_subsection(content, section, prop, value):
    """Replace a key-value pair inside a section block."""
    escaped_prop = re.escape(prop)

    block_pattern = rf"({re.escape(section)}\s*\{{)(.*?)(\}})"
    block_match = re.search(block_pattern, content, re.DOTALL)
    if not block_match:
        return content

    block_content = block_match.group(2)

    # Try to replace existing
    if re.search(rf"^\s*{escaped_prop}\s", block_content, re.MULTILINE):
        new_block = re.sub(
            rf"^(\s*){escaped_prop}\s+\S+.*$",
            rf"\g<1>{prop} {value}",
            block_content,
            flags=re.MULTILINE,
            count=1,
        )
    else:
        # Append
        new_block = block_content.rstrip() + f"\n        {prop} {value}\n    "

    return (
        content[: block_match.start()]
        + block_match.group(1)
        + new_block
        + block_match.group(3)
        + content[block_match.end() :]
    )


def _toggle_subsection_enabled(content, section, enable):
    """Toggle the `off` flag inside a subsection block (border, focus-ring, shadow)."""
    block_pattern = rf"({re.escape(section)}\s*\{{)(.*?)(\}})"
    block_match = re.search(block_pattern, content, re.DOTALL)
    if not block_match:
        return content

    block_content = block_match.group(2)
    has_off = bool(re.search(r"^\s*off\s*$", block_content, re.MULTILINE))

    if enable and has_off:
        new_block = re.sub(
            r"^[ \t]*off\s*\n", "", block_content, flags=re.MULTILINE, count=1
        )
    elif not enable and not has_off:
        new_block = "\n        off\n" + block_content.lstrip("\n")
    else:
        return content  # Already in desired state

    return (
        content[: block_match.start()]
        + block_match.group(1)
        + new_block
        + block_match.group(3)
        + content[block_match.end() :]
    )


# ─── Main ─────────────────────────────────────────────────────────────


def main():
    if len(sys.argv) < 2:
        print(
            json.dumps(
                {
                    "error": "No command. Use: outputs, apply-output, persist-output, get-input, get-layout, get-animations, set"
                }
            )
        )
        return 1

    cmd = sys.argv[1]
    args = sys.argv[2:]

    commands = {
        "outputs": lambda: cmd_outputs(),
        "apply-output": lambda: cmd_apply_output(args),
        "persist-output": lambda: cmd_persist_output(args),
        "get-input": lambda: cmd_get_input(),
        "get-layout": lambda: cmd_get_layout(),
        "get-animations": lambda: cmd_get_animations(),
        "set": lambda: cmd_set(args),
    }

    fn = commands.get(cmd)
    if not fn:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))
        return 1

    return fn()


if __name__ == "__main__":
    sys.exit(main() or 0)
