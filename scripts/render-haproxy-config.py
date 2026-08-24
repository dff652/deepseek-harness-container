#!/usr/bin/env python3
"""Render the HAProxy candidate config from deployment-owned values.

The input template is tracked, but the expected IP authority and crypt hash
come only from the caller's environment.  The renderer deliberately accepts a
narrow grammar so that values cannot introduce HAProxy directives or comments.
"""

from __future__ import annotations

import argparse
import ipaddress
import os
import pathlib
import re
import stat
import sys


USERNAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}\Z")
SHA256_CRYPT_RE = re.compile(
    r"\$5\$(?:rounds=[1-9][0-9]{3,8}\$)?[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{43}\Z"
)


def required_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"missing required environment variable: {name}")
    return value


def reject_control(name: str, value: str) -> None:
    if any(char in value for char in "\r\n\x00"):
        raise SystemExit(f"{name} contains a prohibited control character")


def host_authority(ip_text: str, port_text: str) -> str:
    try:
        address = ipaddress.ip_address(ip_text)
    except ValueError as exc:
        raise SystemExit("DSH_LAN_IP must be a literal IPv4 address") from exc
    if address.version != 4:
        raise SystemExit("the HAProxy Compose PoC currently supports IPv4 only")
    if address.is_unspecified:
        raise SystemExit("DSH_LAN_IP must not be the wildcard address 0.0.0.0")
    if not port_text.isascii() or not port_text.isdecimal():
        raise SystemExit("DSH_HTTPS_PORT must be a decimal TCP port")
    port = int(port_text, 10)
    if not 1 <= port <= 65535:
        raise SystemExit("DSH_HTTPS_PORT must be between 1 and 65535")
    return str(address) if port == 443 else f"{address}:{port}"


def write_private(path: pathlib.Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, stat.S_IRUSR | stat.S_IWUSR)
    except OSError as exc:
        raise SystemExit(f"cannot safely open output file: {path}: {exc}") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise SystemExit(f"output must be one regular, non-hardlinked file: {path}")
        os.fchmod(descriptor, stat.S_IRUSR | stat.S_IWUSR)
        os.ftruncate(descriptor, 0)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            handle.write(content)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--template",
        default=str(pathlib.Path(__file__).resolve().parents[1] / "haproxy/haproxy.cfg.tmpl"),
    )
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    username = required_env("DSH_HAPROXY_USERNAME")
    password_hash = required_env("DSH_HAPROXY_PASSWORD_HASH")
    lan_ip = required_env("DSH_LAN_IP")
    https_port = os.environ.get("DSH_HTTPS_PORT", "443")
    reject_control("DSH_HAPROXY_USERNAME", username)
    reject_control("DSH_HAPROXY_PASSWORD_HASH", password_hash)
    reject_control("DSH_LAN_IP", lan_ip)
    reject_control("DSH_HTTPS_PORT", https_port)
    if not USERNAME_RE.fullmatch(username):
        raise SystemExit("DSH_HAPROXY_USERNAME must be a single safe HAProxy user token")
    if not SHA256_CRYPT_RE.fullmatch(password_hash):
        raise SystemExit("DSH_HAPROXY_PASSWORD_HASH must be a SHA-256 crypt $5$ hash")

    authority = host_authority(lan_ip, https_port)
    template_path = pathlib.Path(args.template)
    template = template_path.read_text(encoding="utf-8")
    replacements = {
        "__DSH_USERNAME__": username,
        "__DSH_PASSWORD_HASH__": password_hash,
        "__DSH_HOST_AUTHORITY__": authority,
    }
    rendered = template
    for marker, replacement in replacements.items():
        rendered = rendered.replace(marker, replacement)
    leftovers = sorted(set(re.findall(r"__[A-Z0-9_]+__", rendered)))
    if leftovers:
        raise SystemExit(f"unresolved HAProxy template markers: {', '.join(leftovers)}")
    write_private(pathlib.Path(args.output), rendered)
    print(f"rendered HAProxy config for {authority} to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
