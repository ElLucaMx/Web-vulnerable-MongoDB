#!/usr/bin/env python3
"""Ediciones conservadoras de net.bindIp y security.authorization en mongod.conf.

Conserva el resto del archivo y sus comentarios. El instalador crea una copia de
seguridad antes de ejecutar este script.
"""
from __future__ import annotations

import argparse
import os
import re
import stat
import tempfile
from pathlib import Path


def section_bounds(lines: list[str], section: str) -> tuple[int, int] | None:
    pat = re.compile(rf"^{re.escape(section)}\s*:\s*(?:#.*)?$")
    start = next((i for i, line in enumerate(lines) if pat.match(line.rstrip("\n"))), None)
    if start is None:
        return None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        line = lines[i].rstrip("\n")
        if line and not line[0].isspace() and not line.lstrip().startswith("#"):
            if re.match(r"^[A-Za-z0-9_.-]+\s*:", line):
                end = i
                break
    return start, end


def key_line(lines: list[str], start: int, end: int, key: str) -> int | None:
    pat = re.compile(rf"^(\s*){re.escape(key)}\s*:")
    for i in range(start + 1, end):
        if pat.match(lines[i].rstrip("\n")):
            return i
    return None


def uncommented_value(line: str) -> tuple[str, str, str]:
    m = re.match(r"^(\s*[A-Za-z0-9_.-]+\s*:\s*)(.*?)(\s+#.*)?$", line.rstrip("\n"))
    if not m:
        raise ValueError(f"No se puede interpretar una opción YAML: {line.rstrip()}")
    prefix = m.group(1)
    # YAML requires whitespace after the mapping colon before a plain scalar.
    # A block-list form such as "bindIp:" has no trailing space in the source;
    # keep the rewritten scalar valid instead of producing "bindIp:127.0.0.1".
    if prefix and not prefix[-1].isspace():
        prefix += " "
    return prefix, m.group(2).strip(), m.group(3) or ""


def clean_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value.strip()


def ensure_bind_ips(text: str, wanted: list[str]) -> tuple[str, bool, str]:
    lines = text.splitlines(keepends=True)
    bounds = section_bounds(lines, "net")
    if bounds is None:
        wanted = list(dict.fromkeys(wanted))
        lines.extend(["\n" if lines and not lines[-1].endswith("\n") else "", "net:\n", f"  bindIp: {','.join(wanted)}\n"])
        return "".join(lines), True, "Se ha añadido net.bindIp."

    start, end = bounds
    bind_all_idx = key_line(lines, start, end, "bindIpAll")
    if bind_all_idx is not None:
        _, raw, _ = uncommented_value(lines[bind_all_idx])
        if clean_scalar(raw).lower() in {"true", "yes", "1"}:
            return text, False, "net.bindIpAll ya permite escucha en todas las interfaces."

    idx = key_line(lines, start, end, "bindIp")
    if idx is None:
        indent_match = re.match(r"^(\s*)", lines[start + 1] if start + 1 < end else "  ")
        indent = indent_match.group(1) if indent_match and indent_match.group(1) else "  "
        lines.insert(end, f"{indent}bindIp: {','.join(dict.fromkeys(wanted))}\n")
        return "".join(lines), True, "Se ha añadido net.bindIp."

    key_indent = len(re.match(r"^\s*", lines[idx]).group(0))
    prefix, raw, comment = uncommented_value(lines[idx])
    values: list[str] = []
    child_end = idx + 1
    child_indent: int | None = None
    if raw == "":
        # Admite el formato YAML de lista multilínea: bindIp:\n  - 127.0.0.1
        while child_end < end:
            child = lines[child_end].rstrip("\n")
            if child.strip() == "" or child.lstrip().startswith("#"):
                child_end += 1
                continue
            indent = len(re.match(r"^\s*", child).group(0))
            if indent <= key_indent:
                break
            if not re.match(r"^\s*-\s+", child):
                raise ValueError("Formato net.bindIp multilínea no reconocido; no se modificó el archivo.")
            child_indent = indent
            item = re.sub(r"^\s*-\s+", "", child).split("#", 1)[0].strip()
            values.append(clean_scalar(item))
            child_end += 1
        if not values:
            values = []
        if any(v in {"0.0.0.0", "::", "*"} for v in values):
            return text, False, "net.bindIp ya contiene una dirección comodín."
        add = [ip for ip in wanted if ip not in values]
        if not add:
            return text, False, "net.bindIp ya contiene las interfaces requeridas."
        if child_indent is None:
            child_indent = key_indent + 2
        items = "".join(" " * child_indent + f"- {ip}\n" for ip in add)
        lines[child_end:child_end] = [items]
        return "".join(lines), True, "Se han añadido las interfaces requeridas a la lista net.bindIp."

    val = clean_scalar(raw)
    inline_list = val.startswith("[") and val.endswith("]")
    if inline_list:
        values = [clean_scalar(v) for v in val[1:-1].split(",") if clean_scalar(v)]
    else:
        values = [clean_scalar(v) for v in val.split(",") if clean_scalar(v)]
    if any(v in {"0.0.0.0", "::", "*"} for v in values):
        return text, False, "net.bindIp ya contiene una dirección comodín."
    add = [ip for ip in wanted if ip not in values]
    if not add:
        return text, False, "net.bindIp ya contiene las interfaces requeridas."
    updated = list(dict.fromkeys(values + add))
    rendered = f"[{', '.join(updated)}]" if inline_list else ",".join(updated)
    newline = "\n" if lines[idx].endswith("\n") else ""
    lines[idx] = f"{prefix}{rendered}{comment}{newline}"
    return "".join(lines), True, "Se han añadido las interfaces requeridas a net.bindIp."



def set_bind_ips(text: str, wanted: list[str]) -> tuple[str, bool, str]:
    """Force net.bindIp to a specific list, disabling bindIpAll if necessary."""
    wanted = list(dict.fromkeys(wanted))
    lines = text.splitlines(keepends=True)
    bounds = section_bounds(lines, "net")
    if bounds is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.extend(["net:\n", f"  bindIp: {','.join(wanted)}\n"])
        return "".join(lines), True, f"net.bindIp temporal establecido en {','.join(wanted)}."

    start, end = bounds
    bind_all_idx = key_line(lines, start, end, "bindIpAll")
    changed = False
    if bind_all_idx is not None:
        prefix, raw, comment = uncommented_value(lines[bind_all_idx])
        if clean_scalar(raw).lower() not in {"false", "no", "0"}:
            newline = "\n" if lines[bind_all_idx].endswith("\n") else ""
            lines[bind_all_idx] = f"{prefix}false{comment}{newline}"
            changed = True

    # Recompute bounds in the (same-size) net section and set the bindIp scalar.
    bounds = section_bounds(lines, "net")
    assert bounds is not None
    start, end = bounds
    idx = key_line(lines, start, end, "bindIp")
    rendered = ",".join(wanted)
    if idx is None:
        lines.insert(end, f"  bindIp: {rendered}\n")
        changed = True
    else:
        key_indent = len(re.match(r"^\s*", lines[idx]).group(0))
        prefix, raw, comment = uncommented_value(lines[idx])
        newline = "\n" if lines[idx].endswith("\n") else ""
        new_line = f"{prefix}{rendered}{comment}{newline}"
        if new_line != lines[idx]:
            lines[idx] = new_line
            changed = True
        # If bindIp was a YAML block list, remove its child list items so that
        # they do not remain under the scalar value. They are direct children of
        # bindIp and stop at the next same-indentation option.
        j = idx + 1
        while j < end:
            child = lines[j].rstrip("\n")
            if child.strip() == "":
                j += 1
                continue
            indent = len(re.match(r"^\s*", child).group(0))
            if indent <= key_indent:
                break
            del lines[j]
            end -= 1
            changed = True
    if changed:
        return "".join(lines), True, f"net.bindIp temporal establecido en {rendered}."
    return text, False, "net.bindIp ya tenía la configuración temporal solicitada."

def set_authorization(text: str, value: str) -> tuple[str, bool, str]:
    lines = text.splitlines(keepends=True)
    bounds = section_bounds(lines, "security")
    if bounds is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        if lines and lines[-1].strip() != "":
            lines.append("\n")
        lines.extend(["security:\n", f"  authorization: {value}\n"])
        changed_message = "Se ha activado security.authorization." if value == "enabled" else "Se ha desactivado temporalmente security.authorization."
        return "".join(lines), True, changed_message

    start, end = bounds
    idx = key_line(lines, start, end, "authorization")
    if idx is not None:
        prefix, raw, comment = uncommented_value(lines[idx])
        if clean_scalar(raw).lower() == value:
            if value == "enabled":
                return text, False, "security.authorization ya está habilitado."
            return text, False, "security.authorization ya está desactivado."
        newline = "\n" if lines[idx].endswith("\n") else ""
        lines[idx] = f"{prefix}{value}{comment}{newline}"
        changed_message = "Se ha activado security.authorization." if value == "enabled" else "Se ha desactivado temporalmente security.authorization."
        return "".join(lines), True, changed_message

    indent = "  "
    for i in range(start + 1, end):
        m = re.match(r"^(\s+)\S", lines[i])
        if m:
            indent = m.group(1)
            break
    lines.insert(end, f"{indent}authorization: {value}\n")
    changed_message = "Se ha añadido security.authorization: enabled." if value == "enabled" else "Se ha añadido security.authorization: disabled."
    return "".join(lines), True, changed_message


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    bind = sub.add_parser("ensure-bind")
    bind.add_argument("--ip", action="append", required=True, help="Dirección a añadir a net.bindIp; se puede repetir.")
    sub.add_parser("enable-auth")
    sub.add_parser("disable-auth")
    local_recovery = sub.add_parser("recovery-local")
    local_recovery.add_argument("--ip", action="append", required=True, help="Interfaces de escucha temporales durante recuperación.")
    set_bind = sub.add_parser("set-bind")
    set_bind.add_argument("--ip", action="append", required=True, help="Direcciones exactas para net.bindIp.")
    args = parser.parse_args()

    if not args.config.is_file():
        raise SystemExit(f"ERROR: no existe el archivo de configuración {args.config}")
    old_stat = args.config.stat()
    original = args.config.read_text(encoding="utf-8")
    if args.command == "ensure-bind":
        new, changed, message = ensure_bind_ips(original, args.ip)
    elif args.command == "set-bind":
        new, changed, message = set_bind_ips(original, args.ip)
    elif args.command == "recovery-local":
        new, bind_changed, bind_message = set_bind_ips(original, args.ip)
        new, auth_changed, auth_message = set_authorization(new, "disabled")
        changed = bind_changed or auth_changed
        message = f"{bind_message} {auth_message}"
    elif args.command == "enable-auth":
        new, changed, message = set_authorization(original, "enabled")
    else:
        new, changed, message = set_authorization(original, "disabled")
    print(message)
    if not changed:
        print("unchanged")
        return 0

    fd, temp_name = tempfile.mkstemp(prefix=args.config.name + ".", dir=str(args.config.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(new)
        os.chmod(temp_name, stat.S_IMODE(old_stat.st_mode))
        os.chown(temp_name, old_stat.st_uid, old_stat.st_gid)
        os.replace(temp_name, args.config)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
    print("changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
