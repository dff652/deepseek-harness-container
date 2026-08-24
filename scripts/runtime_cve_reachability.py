#!/usr/bin/env python3
"""Normalize runtime CVE evidence collected from an exact container image."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import sys


def parse_proc_net(source: str, output: str) -> int:
    with open(source, encoding="utf-8") as stream:
        data = json.load(stream)
    def decode(value, proto):
        raw, port = value.rsplit(":", 1)
        if proto in ("tcp", "udp"):
            return str(ipaddress.IPv4Address(bytes.fromhex(raw)[::-1])), int(port, 16)
        packed = b"".join(bytes.fromhex(raw[index:index + 8])[::-1]
                           for index in range(0, len(raw), 8))
        return str(ipaddress.IPv6Address(packed)), int(port, 16)

    with open(output, "w", encoding="utf-8") as stream:
        for proto in ("tcp", "tcp6", "udp", "udp6"):
            text = data.get(proto, "")
            if text.startswith("ERROR:"):
                raise SystemExit(f"{proto} evidence unavailable: {text}")
            for line in text.splitlines()[1:]:
                fields = line.split()
                if len(fields) < 4:
                    continue
                if proto.startswith("tcp") and fields[3] != "0A":
                    continue
                address, port = decode(fields[1], proto)
                state = "LISTEN" if proto.startswith("tcp") else "UNCONN"
                stream.write(f"{proto}\t{address}\t{port}\t{state}\tproc-net\n")
    return 0


def build_report(root: str, requested_ref: str, requested_platform: str) -> int:
    def invalid(message):
        print(message, file=sys.stderr)
        raise SystemExit(2)


    def read_tsv(path, count):
        result = []
        with open(path, encoding="utf-8") as stream:
            for number, line in enumerate(stream, 1):
                line = line.rstrip("\n")
                if not line:
                    continue
                values = line.split("\t")
                if len(values) != count:
                    invalid(f"malformed {os.path.basename(path)} line {number}")
                result.append(values)
        return result


    def read_metadata(path):
        result = {}
        with open(path, encoding="utf-8") as stream:
            for number, line in enumerate(stream, 1):
                line = line.rstrip("\n")
                if not line:
                    continue
                values = line.split("\t", 1)
                if len(values) != 2 or not values[0] or values[0] in result:
                    invalid(f"malformed metadata.tsv line {number}")
                result[values[0]] = values[1]
        return result


    meta = read_metadata(os.path.join(root, "metadata.tsv"))
    elf_rows = read_tsv(os.path.join(root, "elf.tsv"), 8)
    listener_rows = read_tsv(os.path.join(root, "listeners.tsv"), 5)
    required = {
        "actual_argv", "cmd", "elf_complete", "elf_count", "entrypoint",
        "glibc_version", "image_id", "image_ref", "image_version",
        "listeners_complete", "network_mode", "openssl_version", "platform",
        "published_ports", "repo_digest_match", "requested_digest",
        "runtime_status",
    }
    missing = sorted(required - set(meta))
    if missing:
        invalid("metadata.tsv is missing: " + ", ".join(missing))
    if meta["image_ref"] != requested_ref:
        invalid("evidence does not bind to the requested exact image ref")
    if meta.get("requested_digest") and meta["requested_digest"] != requested_ref.rsplit("@", 1)[1]:
        invalid("evidence requested digest does not match the exact image ref")
    if meta.get("repo_digest_match") != "yes":
        invalid("the exact requested digest is not positively bound to repository evidence")
    if requested_platform and meta["platform"] != requested_platform:
        invalid(f"evidence platform is {meta['platform']}, expected {requested_platform}")
    if meta["platform"] not in ("linux/amd64", "linux/arm64"):
        invalid("evidence platform is not an allowed Linux AMD64/ARM64 child")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", meta["image_id"]):
        invalid("image evidence has no content-addressed image ID")
    if meta["image_version"] != "0.1.1-rc.2":
        invalid("image version is not exactly 0.1.1-rc.2")
    if meta["elf_complete"] not in ("yes", "no") or meta["listeners_complete"] not in ("yes", "no"):
        invalid("evidence completeness fields must be yes or no")

    if meta.get("elf_count") and meta["elf_count"] != str(len(elf_rows)):
        invalid("elf_count does not match the ELF evidence rows")
    elf_complete = (
        meta["elf_complete"] == "yes"
        and bool(elf_rows)
        and meta.get("elf_count") == str(len(elf_rows))
    )
    listeners_complete = (
        meta["listeners_complete"] == "yes"
        and meta.get("runtime_status") == "ready"
    )
    for row in listener_rows:
        if row[0] not in ("tcp", "tcp6", "udp", "udp6"):
            invalid("listener evidence contains an unsupported protocol")
        try:
            port = int(row[2])
        except ValueError:
            invalid("listener evidence contains a non-numeric port")
        if not 0 <= port <= 65535:
            invalid("listener evidence contains an invalid port")
        try:
            address = ipaddress.ip_address(row[1])
        except ValueError:
            invalid("listener evidence contains an invalid IP address")
        if (row[0].endswith("6")) != (address.version == 6):
            invalid("listener protocol and address family do not match")
        expected_state = "LISTEN" if row[0].startswith("tcp") else "UNCONN"
        if row[3] != expected_state or row[4] != "proc-net":
            invalid("listener state or source is not canonical proc-net evidence")
    expected_listener = ["tcp", "127.0.0.1", "3080", "LISTEN", "proc-net"]
    expected_listener_observed = expected_listener in listener_rows
    listeners_complete = listeners_complete and expected_listener_observed
    native_modules = [row[0] for row in elf_rows if row[1] == "native-module"]
    dynamic_needed = sorted({
        item for row in elf_rows for item in row[6].split(",") if item and item != "none"
    })
    relevant_imports = {}
    for row in elf_rows:
        for symbol in row[7].split(","):
            if symbol and symbol != "none":
                relevant_imports.setdefault(symbol, []).append(row[0])
    for symbol in relevant_imports:
        relevant_imports[symbol].sort()

    has_glibc = "libc.so.6" in dynamic_needed or any(
        os.path.basename(row[0]).startswith("libc.so.6") for row in elf_rows
    )
    has_openssl = (
        any(item.startswith(("libssl.so", "libcrypto.so")) for item in dynamic_needed)
        or any(
            os.path.basename(row[0]).startswith(("libssl.so", "libcrypto.so"))
            for row in elf_rows
        )
    )

    glibc_symbols = {
        "CVE-2026-5435": {"ns_printrrf", "ns_printrr", "fp_nquery"},
        "CVE-2026-5450": {
            "scanf", "__isoc99_scanf", "__isoc23_scanf", "fscanf",
            "__isoc99_fscanf", "__isoc23_fscanf", "sscanf", "__isoc99_sscanf",
            "__isoc23_sscanf", "vscanf", "__isoc23_vscanf", "vfscanf",
            "__isoc99_vfscanf", "__isoc23_vfscanf", "vsscanf", "__isoc99_vsscanf",
            "__isoc23_vsscanf",
        },
        "CVE-2026-5928": {"ungetwc"},
    }
    quic_symbols = {
        "OSSL_QUIC_server_method",
        "SSL_CTX_set_quic_method",
        "SSL_accept_connection",
        "SSL_new_listener",
        "SSL_set_quic_method",
    }


    def make_finding(cve, status, reason, evidence):
        allowed = {"evidence", "unknown", "not-applicable-candidate"}
        if status not in allowed:
            invalid(f"invalid status generated for {cve}: {status}")
        return {
            "cve": cve,
            "status": status,
            "reason": reason,
            "evidence": sorted(set(evidence)),
        }


    findings = []
    for cve, symbols in glibc_symbols.items():
        observed = sorted(symbols.intersection(relevant_imports))
        if not elf_complete:
            findings.append(make_finding(
                cve, "unknown",
                "ELF evidence is incomplete; no reachability conclusion is permitted",
                ["elf_complete=" + meta["elf_complete"]],
            ))
        elif not has_glibc:
            findings.append(make_finding(
                cve, "not-applicable-candidate",
                "the ELF closure has no dynamically linked glibc libc.so.6",
                ["dynamic_needed=" + ",".join(dynamic_needed or ["none"])],
            ))
        elif observed:
            paths = [path for symbol in observed for path in relevant_imports[symbol]]
            findings.append(make_finding(
                cve, "evidence",
                "a relevant glibc symbol is directly imported by an ELF in the image",
                [
                    "glibc=present",
                    "symbols=" + ",".join(observed),
                    "paths=" + ",".join(sorted(set(paths))),
                ],
            ))
        else:
            findings.append(make_finding(
                cve, "unknown",
                "glibc is in the ELF closure; no direct symbol import was observed, which is not proof of absence",
                ["glibc=present", "symbols=none-observed", "native_modules=" + str(len(native_modules))],
            ))

    try:
        image_entrypoint = json.loads(meta["entrypoint"])
        image_command = json.loads(meta["cmd"])
        actual_argv = json.loads(meta["actual_argv"])
    except json.JSONDecodeError:
        image_entrypoint = image_command = actual_argv = None
    expected_entrypoint = [
        "/nodejs/bin/node",
        "--expose-internals",
        "/opt/dsh/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js",
    ]
    expected_command = [
        "web",
        "--host",
        "127.0.0.1",
        "--port",
        "3080",
        "--no-open",
    ]
    runtime_contract = (
        image_entrypoint == expected_entrypoint
        and image_command == expected_command
        and actual_argv == expected_entrypoint + expected_command
        and meta.get("network_mode") == "none"
        and meta.get("published_ports") == "none"
        and expected_listener_observed
    )
    udp_rows = [row for row in listener_rows if row[0] in ("udp", "udp6")]
    quic_observed = sorted(quic_symbols.intersection(relevant_imports))
    if not elf_complete or not listeners_complete:
        findings.append(make_finding(
            "CVE-2026-14456", "unknown",
            "ELF or runtime listener evidence is incomplete; no reachability conclusion is permitted",
            [
                "elf_complete=" + meta["elf_complete"],
                "listeners_complete=" + meta["listeners_complete"],
            ],
        ))
    elif udp_rows and quic_observed:
        findings.append(make_finding(
            "CVE-2026-14456", "evidence",
            "a UDP runtime endpoint and direct OpenSSL QUIC API import are both observed",
            ["udp_endpoints=" + str(len(udp_rows)), "symbols=" + ",".join(quic_observed)],
        ))
    elif udp_rows:
        findings.append(make_finding(
            "CVE-2026-14456", "unknown",
            "a UDP runtime endpoint is observed; no direct QUIC import was observed, which is not proof of absence",
            ["udp_endpoints=" + str(len(udp_rows)), "symbols=none-observed"],
        ))
    elif quic_observed:
        findings.append(make_finding(
            "CVE-2026-14456", "unknown",
            "OpenSSL QUIC API imports are observed but no UDP endpoint appeared in this runtime sample",
            ["udp_endpoints=0", "symbols=" + ",".join(quic_observed)],
        ))
    elif not runtime_contract:
        findings.append(make_finding(
            "CVE-2026-14456", "unknown",
            "the exact loopback Web command and no-publication runtime contract was not proven",
            [
                "command=" + json.dumps(image_command, separators=(",", ":")),
                "entrypoint=" + json.dumps(image_entrypoint, separators=(",", ":")),
                "actual_argv=" + json.dumps(actual_argv, separators=(",", ":")),
                "network_mode=" + meta.get("network_mode", "unknown"),
                "published_ports=" + meta.get("published_ports", "unknown"),
            ],
        ))
    else:
        findings.append(make_finding(
            "CVE-2026-14456", "not-applicable-candidate",
            "the exact loopback Web runtime is TCP-only, unpublished, and has no direct OpenSSL QUIC API import",
            [
                "udp_endpoints=0",
                "tcp_endpoints=" + str(sum(row[0] in ("tcp", "tcp6") for row in listener_rows)),
                "openssl=" + ("present" if has_openssl else "absent"),
                "symbols=none-observed",
            ],
        ))

    findings.sort(key=lambda item: item["cve"])
    blocking = [item["cve"] for item in findings if item["status"] != "not-applicable-candidate"]
    report = {
        "schemaVersion": 1,
        "tool": "audit-runtime-cve-reachability",
        "image": {
            "ref": meta["image_ref"],
            "id": meta["image_id"],
            "platform": meta["platform"],
            "version": meta.get("image_version", "unknown"),
            "repoDigestMatch": meta.get("repo_digest_match", "unknown"),
        },
        "evidence": {
            "elf": {
                "complete": elf_complete,
                "count": len(elf_rows),
                "nativeModules": native_modules,
                "dynamicNeeded": dynamic_needed,
                "relevantImports": relevant_imports,
                "glibc": meta.get("glibc_version", "unknown"),
                "openssl": meta.get("openssl_version", "unknown"),
            },
            "listeners": {
                "complete": listeners_complete,
                "runtimeStatus": meta.get("runtime_status", "unknown"),
                "networkMode": meta.get("network_mode", "unknown"),
                "publishedPorts": meta.get("published_ports", "unknown"),
                "endpoints": [
                    {
                        "protocol": row[0],
                        "address": row[1],
                        "port": int(row[2]),
                        "state": row[3],
                        "source": row[4],
                    }
                    for row in listener_rows
                ],
            },
        },
        "findings": findings,
        "decision": "blocked-evidence-or-unknown" if blocking else "candidate-not-applicable",
        "blockingCves": blocking,
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if blocking else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    proc_parser = subparsers.add_parser("proc-net")
    proc_parser.add_argument("source")
    proc_parser.add_argument("output")
    report_parser = subparsers.add_parser("report")
    report_parser.add_argument("root")
    report_parser.add_argument("image_ref")
    report_parser.add_argument("platform")
    args = parser.parse_args()
    if args.command == "proc-net":
        return parse_proc_net(args.source, args.output)
    return build_report(args.root, args.image_ref, args.platform)


if __name__ == "__main__":
    raise SystemExit(main())
