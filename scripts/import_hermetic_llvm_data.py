#!/usr/bin/env python3
"""Import the runtime source tables of hermeticbuild/hermetic-llvm.

Usage: import_hermetic_llvm_data.py <path to a hermetic-llvm checkout>

Writes cmake/distributions/runtime_sources.json (glibc sources per version,
libc -> kernel header versions, musl, the "extras" tool prebuilts), and copies
the compiler index, glibc/kernel header indexes, LLVM source table and the
glibc abilists blob.
"""
import base64
import json
import os
import re
import shutil
import sys


def dict_literal(text, name):
    """Extract a Starlark dict of string keys to string values or lists."""
    m = re.search(r"^%s\s*=\s*\{(.*?)^\}" % re.escape(name), text, re.S | re.M)
    if not m:
        raise SystemExit(f"{name} not found")
    body = m.group(1)
    result = {}
    for k, v in re.findall(r'"([^"]+)"\s*:\s*("[^"]*"|\[[^\]]*\])', body):
        if v.startswith("["):
            result[k] = re.findall(r'"([^"]+)"', v)
        else:
            result[k] = v.strip('"')
    return result


def main():
    src = sys.argv[1]
    repo = os.path.join(os.path.dirname(__file__), "..")
    dist = os.path.join(repo, "cmake", "distributions")

    glibc_bzl = open(os.path.join(src, "runtimes/glibc/extension/glibc.bzl"), encoding="utf-8").read()
    commits = dict_literal(glibc_bzl, "GLIBC_RELEASE_COMMITS")
    urls = dict_literal(glibc_bzl, "GLIBC_RELEASE_URLS")
    prefixes = dict_literal(glibc_bzl, "GLIBC_RELEASE_STRIP_PREFIXES")
    integrity = dict_literal(glibc_bzl, "GLIBC_RELEASE_INTEGRITY")
    kernel_bzl = open(os.path.join(src, "kernel/extension/libc_kernel_versions.bzl"), encoding="utf-8").read()
    libc_kernel = dict_literal(kernel_bzl, "LIBC_KERNEL_VERSIONS")
    versions_bzl = open(os.path.join(src, "constraints/libc/libc_versions.bzl"), encoding="utf-8").read()
    glibc_versions = re.findall(r'^\s*"(\d+\.\d+)",', versions_bzl.split("GLIBC_VERSIONS")[1].split("]")[0], re.M)
    default_libc = re.search(r'DEFAULT_LIBC\s*=\s*"([^"]+)"', versions_bzl).group(1)

    glibc = {}
    for v in glibc_versions:
        if v in urls:
            entry = {"urls": urls[v], "strip_components": 1}
        else:
            entry = {"urls": [f"https://github.com/bminor/glibc/archive/{commits[v]}.tar.gz"], "strip_components": 1}
        entry["sha256"] = integrity[v]
        entry["kernel"] = libc_kernel[f"gnu.{v}"]
        glibc[v] = entry

    musl_bzl = open(os.path.join(src, "runtimes/musl/extension/musl.bzl"), encoding="utf-8").read()
    musl_url = re.search(r'urls\s*=\s*\["([^"]+)"\]', musl_bzl).group(1)
    musl_integrity = re.search(r'integrity\s*=\s*"sha256-([^"]+)"', musl_bzl).group(1)
    musl_version = re.search(r"musl-(\d+\.\d+\.\d+)", musl_url).group(1)
    musl = {
        "version": musl_version,
        "urls": [musl_url],
        "sha256": base64.b64decode(musl_integrity).hex(),
        "strip_components": 1,
        "kernel": libc_kernel["musl"],
    }

    module = open(os.path.join(src, "MODULE.bazel"), encoding="utf-8").read()
    extras_version = re.search(r'TOOLCHAIN_EXTRAS_VERSION\s*=\s*"([^"]+)"', module).group(1)
    extras_sha = dict_literal(module, "TOOLCHAIN_EXTRAS_SHA256")
    extras = {"version": extras_version, "hosts": {}}
    for host, sha in extras_sha.items():
        extras["hosts"][host] = {
            "url": f"https://github.com/hermeticbuild/hermetic-llvm/releases/download/prebuilts-extras-{extras_version}/toolchain-extra-prebuilts-{extras_version}-{host}.tar.zst",
            "sha256": sha,
        }

    result = {
        "_meta": {"description": "Runtime build inputs imported from hermeticbuild/hermetic-llvm by scripts/import_hermetic_llvm_data.py"},
        "default_libc": default_libc,
        "glibc": glibc,
        "musl": musl,
        "extras": extras,
    }
    # Entries of our own (mingw: MinGW-w64, which hermetic-llvm does not
    # build) stay as they are.
    runtime_sources = os.path.join(dist, "runtime_sources.json")
    if os.path.exists(runtime_sources):
        with open(runtime_sources, encoding="utf-8") as f:
            for key, value in json.load(f).items():
                result.setdefault(key, value)
    with open(runtime_sources, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
        f.write("\n")

    shutil.copy(os.path.join(src, "extensions/llvm_toolchain_minimal_index.json"), os.path.join(dist, "hermeticbuild.json"))
    shutil.copy(os.path.join(src, "runtimes/glibc/extension/glibc_headers_index.json"), os.path.join(dist, "glibc_headers.json"))
    shutil.copy(os.path.join(src, "kernel/extension/kernel_headers_index.json"), os.path.join(dist, "kernel_headers.json"))
    shutil.copy(os.path.join(src, "llvm_versions.json"), os.path.join(dist, "llvm_sources.json"))
    shutil.copy(os.path.join(src, "runtimes/glibc/abilists"), os.path.join(repo, "runtimes/glibc/abilists"))
    print("imported: %d glibc versions, musl %s, extras %s" % (len(glibc), musl_version, extras_version))


if __name__ == "__main__":
    main()
