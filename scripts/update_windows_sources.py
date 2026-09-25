#!/usr/bin/env python3
"""Generate cmake/distributions/windows.json.

Records every MSVC toolset (CRT headers + STL, per-architecture static
"Desktop" and dynamic "Store" CRT libraries) found in a pinned Visual Studio
installer manifest, and the Windows SDK versions published as NuGet packages
(Microsoft.Windows.SDK.CPP and the per-architecture packages). NuGet's
catalog provides SHA-512 package hashes, so no SDK is downloaded.

Usage:
  update_windows_sources.py --manifest-url URL --manifest-sha256 HEX \
      [--manifest-file FILE] [--default-msvc 14.50.35717] \
      [--default-sdk 10.0.26100.7705] [--all-sdk-versions]

By default only the newest patch of every SDK build (10.0.22621, 10.0.26100,
...) is listed; --all-sdk-versions lists every stable version.
The manifest URL and hash come from hermetic-llvm's MODULE.bazel.
"""
import argparse
import base64
import gzip
import hashlib
import io
import json
import os
import re
import sys
import urllib.request
import zipfile

ARCHES = {"x64": "x86_64", "arm64": "aarch64"}
SDK_PACKAGES = ["Microsoft.Windows.SDK.CPP"] + [f"Microsoft.Windows.SDK.CPP.{a}" for a in ARCHES]
NUGET = "https://api.nuget.org"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "hermetic-cpp-cmake", "Accept-Encoding": "gzip"})
    with urllib.request.urlopen(req) as r:
        data = r.read()
        if r.headers.get("Content-Encoding") == "gzip":
            data = gzip.decompress(data)
        return data


def version_key(v):
    return tuple(int(x) for x in v.split("."))


def msvc_toolsets(manifest):
    by_id = {}
    # Language resource packages share one id across languages; keep English.
    english = {}
    for p in manifest["packages"]:
        by_id.setdefault(p["id"].lower(), p)
        if p.get("language") == "en-US":
            english.setdefault(p["id"].lower(), p)

    def payload(package_id, table=None):
        p = (table or by_id)[package_id]
        pl = p["payloads"][0]
        return {"package": p["id"], "file": pl["fileName"], "url": pl["url"], "sha256": pl["sha256"].lower(), "size": pl["size"]}

    toolsets = {}
    for pid in sorted(by_id):
        if not (pid.startswith("microsoft.vc.") and pid.endswith(".crt.headers.base")):
            continue
        version = by_id[pid].get("version", "")
        if not re.match(r"^14\.\d+\.\d+$", version):
            continue
        family = pid[: -len("crt.headers.base")]
        # The toolset directory (Contents/VC/Tools/MSVC/<toolset>) is what
        # users see and what libraries are keyed by; it differs from the
        # package version, so read it from the (small) headers package.
        pl = by_id[pid]["payloads"][0]
        print(f"reading toolset directory of {by_id[pid]['id']}", file=sys.stderr)
        content = fetch(pl["url"])
        if hashlib.sha256(content).hexdigest() != pl["sha256"].lower():
            raise SystemExit(f"{pid}: checksum mismatch")
        dirs = {n.split("/")[4] for n in zipfile.ZipFile(io.BytesIO(content)).namelist() if n.startswith("Contents/VC/Tools/MSVC/")}
        if len(dirs) != 1:
            raise SystemExit(f"{pid}: expected one toolset directory, found {dirs}")
        toolset = dirs.pop()
        libs = {}
        for ms_arch, arch in ARCHES.items():
            desktop, store = f"{family}crt.{ms_arch}.desktop.base", f"{family}crt.{ms_arch}.store.base"
            if desktop in by_id and store in by_id:
                libs[arch] = [payload(desktop), payload(store)]
        if not libs:
            continue
        # The compilers (cl, c1, c2, link, lib and their DLLs) per host and
        # target architecture, with the English message resources cl.exe
        # needs next to it: for HERMETIC_COMPILER=msvc.
        tools = {}
        for host_ms_arch, host_arch in ARCHES.items():
            for ms_arch, arch in ARCHES.items():
                base = f"{family}tools.host{host_ms_arch}.target{ms_arch}.base"
                res = f"{family}tools.host{host_ms_arch}.target{ms_arch}.res.base"
                if base in by_id and res in english:
                    tools.setdefault(host_arch, {})[arch] = [payload(base), payload(res, english)]
        toolsets[toolset] = {
            "package_version": version,
            "compatibility_version": "19." + ".".join(toolset.split(".")[1:]),
            "headers": payload(pid),
            "libs": libs,
            "tools": tools,
        }
    return toolsets


def sdk_versions(all_versions, always):
    index = json.loads(fetch(f"{NUGET}/v3-flatcontainer/microsoft.windows.sdk.cpp/index.json"))["versions"]
    stable = [v for v in index if re.match(r"^\d+\.\d+\.\d+\.\d+$", v)]
    if not all_versions:
        newest = {}
        for v in stable:
            build = ".".join(v.split(".")[:3])
            if build not in newest or version_key(v) > version_key(newest[build]):
                newest[build] = v
        stable = sorted(set(newest.values()) | ({always} & set(stable)), key=version_key)
    result = {}
    for v in stable:
        packages = {}
        for name in SDK_PACKAGES:
            pid = name.lower()
            reg = json.loads(fetch(f"{NUGET}/v3/registration5-gz-semver2/{pid}/{v.lower()}.json"))
            leaf = json.loads(fetch(reg["catalogEntry"]))
            if leaf.get("packageHashAlgorithm") != "SHA512":
                raise SystemExit(f"{name} {v}: unexpected hash algorithm {leaf.get('packageHashAlgorithm')}")
            packages[name] = {
                "url": f"{NUGET}/v3-flatcontainer/{pid}/{v.lower()}/{pid}.{v.lower()}.nupkg",
                "hash": "SHA512=" + base64.b64decode(leaf["packageHash"]).hex(),
                "size": leaf["packageSize"],
            }
        result[v] = {"packages": packages}
        print(f"sdk {v}", file=sys.stderr)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest-url", required=True)
    ap.add_argument("--manifest-sha256", required=True)
    ap.add_argument("--manifest-file")
    ap.add_argument("--default-msvc", default="14.50.35717")
    ap.add_argument("--default-sdk", default="10.0.26100.7705")
    ap.add_argument("--all-sdk-versions", action="store_true")
    args = ap.parse_args()

    data = open(args.manifest_file, "rb").read() if args.manifest_file else fetch(args.manifest_url)
    digest = hashlib.sha256(data).hexdigest()
    if digest != args.manifest_sha256.lower():
        raise SystemExit(f"manifest sha256 {digest} != {args.manifest_sha256}")
    toolsets = msvc_toolsets(json.loads(data))
    if args.default_msvc not in toolsets:
        raise SystemExit(f"default toolset {args.default_msvc} not in manifest: {sorted(toolsets)}")
    sdks = sdk_versions(args.all_sdk_versions, args.default_sdk)
    if args.default_sdk not in sdks:
        raise SystemExit(f"default SDK {args.default_sdk} not found: {sorted(sdks)}")

    out = os.path.join(os.path.dirname(__file__), "..", "cmake", "distributions", "windows.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({
            "_meta": {"description": "MSVC toolsets (Visual Studio installer manifest) and Windows SDK versions (NuGet), generated by scripts/update_windows_sources.py"},
            "msvc": {"default": args.default_msvc, "manifest": {"url": args.manifest_url, "sha256": args.manifest_sha256.lower()},
                     "versions": {v: toolsets[v] for v in sorted(toolsets, key=version_key)}},
            "windows_sdk": {"default": args.default_sdk, "versions": sdks},
        }, f, indent=2)
        f.write("\n")
    print(f"wrote {out}: {len(toolsets)} toolsets, {len(sdks)} SDK versions")


if __name__ == "__main__":
    main()
