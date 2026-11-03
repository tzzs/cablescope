#!/usr/bin/env python3
"""Enforce line coverage for CableScope's deterministic business logic."""

import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEST_TARGETS = ("CableKitTests", "CableScopeCLITests", "CableScopeAppTests")
THRESHOLD = 80.0

# These files contain product rules, data transformations, or state decisions that
# are deterministic and meaningful to exercise in unit tests. UI composition and
# direct system-service orchestration are deliberately outside this denominator.
SCOPE = {
    "Sources/CableKit/Models",
    "Sources/CableKit/Rating",
    "Sources/CableKit/Diagnostics",
    "Sources/CableKit/Localization",
    "Sources/CableKit/Preferences",
    "Sources/CableKit/Throughput",
    "Sources/CableScopeApp/AppPreferences.swift",
    "Sources/CableScopeApp/MonitorViewModel.swift",
    "Sources/CableScopeApp/NotificationController.swift",
    "Sources/CableScopeApp/NotificationThrottle.swift",
    "Sources/CableScopeApp/PowerHistory.swift",
    "Sources/CableScopeApp/UpdateChecker.swift",
    "Sources/CableScopeApp/WidgetRefresher.swift",
    "Sources/CableScopeApp/Settings/AppLocalization.swift",
    "Sources/CableScopeApp/Settings/NotificationSettingsLink.swift",
    "Sources/CableScopeCLI/Args.swift",
    "Sources/CableScopeCLI/Formatting.swift",
    "Sources/CableScopeCLI/Localization.swift",
    "Sources/CableScopeCLI/PropertiesCommand.swift",
    "Sources/CableScopeCLI/RatingCommand.swift",
    "Sources/CableScopeCLI/SnapshotAndPretty.swift",
    "Sources/CableScopeCLI/ThroughputCommand.swift",
    "Sources/CableScopeCLI/WatchCommand.swift",
}


def in_scope(filename: str) -> bool:
    try:
        relative = pathlib.Path(filename).resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return False
    return any(relative == item or relative.startswith(item.rstrip("/") + "/") for item in SCOPE)


def find_profiles() -> list[pathlib.Path]:
    """Locate the profile data produced by `swift test --enable-code-coverage`.

    The path differs between SwiftPM build engines (classic writes
    `.build/<triple>/debug/codecov`, the native engine writes
    `.build/out/Products/Debug/codecov`), so discover instead of hardcoding.
    """
    build_dir = ROOT / ".build"
    if not build_dir.exists():
        return []
    return sorted(build_dir.rglob("default.profdata"), key=lambda path: path.stat().st_mtime, reverse=True)


def find_test_binaries() -> list[list[pathlib.Path]]:
    """Candidate sets of test binaries to feed to llvm-cov.

    The native engine produces one bundle per test target, the classic engine a
    single bundle that links all of them. Each candidate is tried in turn.
    """
    build_dir = ROOT / ".build"
    if not build_dir.exists():
        return []

    per_target = []
    for target in TEST_TARGETS:
        matches = [path for path in build_dir.rglob(f"{target}.xctest/Contents/MacOS/{target}")]
        if matches:
            per_target.append(sorted(matches, key=lambda path: path.stat().st_mtime, reverse=True)[0])

    package_bundle = [path for path in build_dir.rglob("CableScopePackageTests.xctest/Contents/MacOS/CableScopePackageTests")]

    candidates = []
    if per_target:
        candidates.append(per_target)
    if package_bundle:
        candidates.append(sorted(package_bundle, key=lambda path: path.stat().st_mtime, reverse=True)[:1])
    return candidates


def export_coverage(profile: pathlib.Path, binaries: list[pathlib.Path]):
    command = ["xcrun", "llvm-cov", "export", "--format=text", f"--instr-profile={profile}"]
    for binary in binaries[1:]:
        command.extend(["-object", str(binary)])
    command.append(str(binaries[0]))
    try:
        result = subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
        return json.loads(result.stdout)["data"][0]["files"]
    except (OSError, subprocess.CalledProcessError, KeyError, IndexError, json.JSONDecodeError):
        return None


def main() -> int:
    profiles = find_profiles()
    candidate_binaries = find_test_binaries()
    if not profiles or not candidate_binaries:
        print("覆盖率产物不存在；请先运行：swift test --enable-code-coverage", file=sys.stderr)
        return 2

    best = None
    for profile in profiles:
        for binaries in candidate_binaries:
            exported = export_coverage(profile, binaries)
            if exported is None:
                continue
            scoped = [file for file in exported if in_scope(file["filename"])]
            if not scoped:
                continue
            covered = sum(file["summary"]["lines"]["covered"] for file in scoped)
            if best is None or covered > best[0]:
                best = (covered, scoped)

    if best is None:
        print("覆盖率 scope 内没有找到源码文件", file=sys.stderr)
        return 2
    included = best[1]

    expected = set()
    for item in SCOPE:
        path = ROOT / item
        if path.is_file() and path.suffix == ".swift":
            expected.add(path.resolve())
        elif path.is_dir():
            expected.update(candidate.resolve() for candidate in path.rglob("*.swift"))
    observed = {pathlib.Path(file["filename"]).resolve() for file in included}
    missing = sorted(str(path.relative_to(ROOT)) for path in expected - observed)
    if missing:
        print("以下必要逻辑文件未进入覆盖率报告：", file=sys.stderr)
        for item in missing:
            print(f"  {item}", file=sys.stderr)
        return 2

    total = sum(file["summary"]["lines"]["count"] for file in included)
    covered = sum(file["summary"]["lines"]["covered"] for file in included)
    percent = covered / total * 100 if total else 100.0
    print(f"必要逻辑行覆盖率：{covered}/{total} = {percent:.2f}%（门槛 {THRESHOLD:.0f}%）")

    low_files = [file for file in included if file["summary"]["lines"]["percent"] < THRESHOLD]
    for file in sorted(low_files, key=lambda item: item["summary"]["lines"]["percent"]):
        relative = pathlib.Path(file["filename"]).resolve().relative_to(ROOT)
        print(f"  {relative}: {file['summary']['lines']['percent']:.2f}%")

    if percent < THRESHOLD:
        print("必要逻辑整体行覆盖率低于门槛", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
