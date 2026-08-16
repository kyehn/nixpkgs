#!/usr/bin/env python3
"""Prepare macOS plugin sources for a nixpkgs buildFlutterApplication build.

`flutter pub get` writes .dart_tool/package_config.json; each entry points at
a pub package in the nix store. This script finds the plugins among them that
declare a macOS pluginClass in their pubspec, resolves their native sources
from macos/darwin/Package.swift (SwiftPM) or *.podspec (CocoaPods), copies
them into a scratch dir and prints one TSV line per plugin for the build:

    <name>\t<pluginClass>\t<swift|objc>\t<sourceFiles>\t<publicHeaderDir>\t<frameworks>

Source preparation that is awkward in shell happens here instead: Pigeon
messages.g.swift files are renamed and their shared helper symbols prefixed
per plugin so several Pigeon plugins can compile into one Swift module, and
the duplicate NSRect extension is dropped from window_manager.

Plugins needing third-party pods or SwiftPM packages cannot be built without
CocoaPods and are skipped with a warning on stderr; missing sources are a
hard error.
"""

import glob
import json
import os
import re
import shutil
import sys

# Podspec platform prefixes that select a macOS-specific value
# (s.osx.source_files = ...). Unprefixed values are shared; iOS-only ones
# (s.ios.*) are ignored.
_MACOS_PLATFORMS = {"", "osx", "macos"}
_IGNORED_PLATFORMS = {"ios", "tvos", "watchos", "visionos"}
_APPLE_PODS = {"Flutter", "FlutterMacOS"}


def strip_ruby(text: str) -> str:
    """Drop comments and heredoc bodies so attribute regexes stay simple."""
    text = re.sub(r"<<-?(\w+).*?^\s*\1\s*$", "", text, flags=re.S | re.M)
    return re.sub(r"#.*$", "", text, flags=re.M)


def podspec_attr(text: str, attr: str):
    """Last `s[.<platform>.]<attr> = ...` assignment that applies to macOS."""
    pattern = re.compile(
        r"s\.(?:(?P<platform>[a-z_]+)\.)?%s\s*=\s*(?P<value>[^\n]+)" % attr
    )
    found = None
    for m in pattern.finditer(text):
        platform = m.group("platform") or ""
        if platform in _IGNORED_PLATFORMS:
            continue
        if platform not in _MACOS_PLATFORMS:
            continue
        found = m.group("value").strip()
    return found


def podspec_string(value: str):
    m = re.fullmatch(r"['\"](.*)['\"]", value, re.S)
    return m.group(1) if m else None


def podspec_string_list(value: str):
    m = re.fullmatch(r"\[(.*)\]", value, re.S)
    if m:
        return re.findall(r"['\"]([^'\"]*)['\"]", m.group(1))
    s = podspec_string(value)
    return [s] if s is not None else None


def expand_brace(pattern: str):
    m = re.search(r"\{([^}]*)\}", pattern)
    if not m:
        return [pattern]
    out = []
    for alt in m.group(1).split(","):
        out.extend(expand_brace(pattern[: m.start()] + alt + pattern[m.end():]))
    return out


def glob_files(root: str, pattern: str):
    """Expand a CocoaPods glob. Braces by hand: glob.glob mishandles `**`
    combined with {a,b} groups."""
    results = []
    for pat in expand_brace(pattern):
        results.extend(glob.glob(pat, root_dir=root, recursive=True))
    return sorted(os.path.join(root, p) for p in results)


def podspec_frameworks(podspec_dir: str, podspec_text: str):
    """Frameworks the ObjC sources import; ObjC has no autolinking so the
    build must pass them explicitly."""
    frameworks = set()
    pattern = re.compile(r"s\.(?:(?:[a-z_]+)\.)?source_files\s*=\s*['\"]([^'\"]+)['\"]")
    for m in pattern.finditer(strip_ruby(podspec_text)):
        for f in glob_files(podspec_dir, m.group(1)):
            if not f.endswith((".m", ".h")):
                continue
            try:
                body = open(f, encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            frameworks.update(re.findall(r"#import\s*<([A-Za-z0-9_]+)/", body))
    return sorted(frameworks)


def plugin_class(pubspec_path: str):
    """macos pluginClass from the plugin's own pubspec."""
    try:
        body = open(pubspec_path, encoding="utf-8").read()
    except OSError:
        return None
    m = re.search(r"macos:\n(\s+)(?:dartPluginClass:\s*\S+\n\s+)?pluginClass:\s*(\S+)", body)
    return m.group(2) if m else None


def swiftpm_sources(pkg_dir: str, package_swift: str, name: str):
    """SwiftPM plugin: the Sources/**/*.swift files, or None (with a warning)
    when the package needs third-party SwiftPM dependencies."""
    text = open(package_swift, encoding="utf-8").read()
    # Protect string literals so stripping // comments does not eat https://.
    protected = {}

    def _protect(m):
        token = f"\x00{len(protected)}\x00"
        protected[token] = m.group(0)
        return token

    text = re.sub(r'"(?:[^"\\]|\\.)*"', _protect, text)
    text = re.sub(r"//.*$", "", text, flags=re.M)
    for token, literal in protected.items():
        text = text.replace(token, literal)
    third = []
    # .package(...) may span lines and nest one level of parens.
    for dep in re.findall(r"\.package\((?:[^()]|\([^()]*\))*\)", text):
        if "FlutterFramework" in dep:
            continue
        m = re.search(r'(?:url|path)\s*:\s*"([^"]+)"', dep)
        if not m:
            continue
        location = m.group(1)
        if location.startswith("http") or not location.startswith(("../", "./")):
            third.append(location)
    if third:
        warn(f"skip {name}: needs third-party SwiftPM package(s) {', '.join(third)}")
        return None
    sources = []
    base = os.path.join(pkg_dir, "Sources")
    if os.path.isdir(base):
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in ("Tests", ".build")]
            for fn in sorted(filenames):
                if fn.endswith(".swift"):
                    sources.append(os.path.join(dirpath, fn))
    if not sources:
        warn(f"skip {name}: Package.swift has no Sources directory")
    return sources


def pigeon_rename(dest: str, plugin_name: str):
    """messages.g.swift files define the same helper symbols (PigeonError,
    MessagesPigeonCodec, ...) in every plugin. Rename the files and prefix
    those symbols per plugin so all plugins can share one Swift module."""
    for msg in glob.glob(os.path.join(dest, "**", "messages.g.swift"), recursive=True):
        rel = os.path.relpath(msg, dest)
        renamed = os.path.join(dest, f"{plugin_name}_{rel.replace('/', '_')}")
        os.rename(msg, renamed)
        text = open(renamed, encoding="utf-8").read()
        for sym in ("PigeonError", "MessagesPigeonCodec",
                    "deepEqualsmessages", "deepHashmessages"):
            text = text.replace(sym, f"{plugin_name}{sym}")
        open(renamed, "w", encoding="utf-8").write(text)


def drop_nsrect_extension(path: str):
    """window_manager and screen_retriever both define `extension NSRect {
    var topLeft }`; drop it from window_manager so the module compiles."""
    src = open(path, encoding="utf-8").read()
    start = src.find("extension NSRect {")
    if start == -1:
        return
    depth = 0
    end = start
    for i in range(start, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    open(path, "w", encoding="utf-8").write(src[:start] + src[end:])


def warn(msg: str):
    sys.stderr.write(f"macos-plugin-collect: {msg}\n")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: macos-plugin-collect.py <package_config.json> <outdir>")
    config_path, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)

    config = json.load(open(config_path, encoding="utf-8"))
    packages = {}
    for p in config["packages"]:
        if p["rootUri"].startswith("file://"):
            packages[p["name"]] = p["rootUri"].removeprefix("file://")

    plugins = {
        name: plugin_class(os.path.join(root, "pubspec.yaml"))
        for name, root in packages.items()
    }
    plugins = {k: v for k, v in plugins.items() if v is not None}
    if not plugins:
        warn(f"no macOS plugins found in {config_path}")

    for name, cls in sorted(plugins.items()):
        root = packages[name]

        # Flutter is migrating macOS plugins from CocoaPods to SwiftPM; prefer
        # Package.swift when present, fall back to the podspec.
        swift_package = None
        podspec = None
        for sub in (os.path.join(root, "macos"), os.path.join(root, "darwin")):
            spm = os.path.join(sub, "Package.swift")
            if os.path.isfile(spm):
                swift_package = spm
                pkg_dir = sub
                break
            candidate = os.path.join(sub, f"{name}.podspec")
            if os.path.isfile(candidate):
                podspec = candidate
                pkg_dir = sub
                break
        if swift_package is not None:
            sources = swiftpm_sources(pkg_dir, swift_package, name)
            if not sources:
                continue
            src_type, public_dir, frameworks = "swift", "-", "-"
        elif podspec is not None:
            text = strip_ruby(open(podspec, encoding="utf-8").read())
            deps_value = podspec_attr(text, "dependency")
            deps = podspec_string_list(deps_value) if deps_value is not None else []
            third = [d for d in deps if d not in _APPLE_PODS]
            if third:
                warn(f"skip {name}: needs third-party pod(s) {', '.join(third)}")
                continue
            plat = re.match(r":([a-z_]+)", podspec_attr(text, "platform") or "")
            if plat and plat.group(1) != "osx":
                continue  # iOS-only plugin
            pattern = podspec_string(podspec_attr(text, "source_files"))
            if pattern is None:
                raise SystemExit(f"{name}: unsupported source_files in {podspec}")
            sources = glob_files(pkg_dir, pattern)
            swift_files = [f for f in sources if f.endswith(".swift")]
            objc_files = [f for f in sources if f.endswith(".m")]
            if not swift_files and not objc_files:
                raise SystemExit(f"{name}: {pattern!r} matched no compilable sources")
            src_type = "swift" if swift_files else "objc"
            public_dir = "-"
            public_value = podspec_attr(text, "public_header_files")
            if public_value is not None:
                headers = glob_files(pkg_dir, podspec_string(public_value))
                dirs = sorted({os.path.dirname(h) for h in headers})
                if dirs:
                    public_dir = os.path.relpath(dirs[0], root)
            frameworks_value = podspec_attr(text, "frameworks")
            frameworks = podspec_string_list(frameworks_value) if frameworks_value is not None else []
            if src_type == "objc":
                frameworks = sorted(set(frameworks) | set(podspec_frameworks(pkg_dir, text)))
            frameworks = " ".join(frameworks) or "-"
        else:
            warn(f"skip {name}: no macos/darwin Package.swift or podspec")
            continue

        # Copy sources into the scratch dir, keeping their relative layout so
        # swiftc sees distinct paths and ObjC imports resolve.
        dest = os.path.join(outdir, name)
        for sf in sources:
            rel = os.path.relpath(sf, root)
            target = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(sf, target)
            # Store paths are read-only; the copies must be writable for
            # the renaming and rewriting below.
            os.chmod(target, 0o644)
        pigeon_rename(dest, name)
        if name == "window_manager":
            wm = glob.glob(os.path.join(dest, "**", "WindowManager.swift"), recursive=True)
            if wm:
                drop_nsrect_extension(wm[0])

        rel_sources = [os.path.relpath(s, dest) for s in sources]
        print("\t".join([
            name, cls, src_type,
            " ".join(rel_sources),
            public_dir, frameworks,
        ]))


if __name__ == "__main__":
    main()
