#!/usr/bin/env python3
"""强制"中文文案必须有英文译文"：扫描各模块源码里的中文字符串字面量，
比对该模块 `Resources/en.lproj/Localizable.strings` 的 key 集合，缺一条就失败。

存在的理由（见 AGENTS.md「本地化」）：本地化断链**不会报任何错**——SwiftUI 的
`Text(LocalizedStringKey)` 与 `KitLocalization`/`AppLocalization` 查表落空时一律安全
回退成 key 本身，也就是中文原文。于是英文界面里零星混着中文，编译、测试、打包
全程绿灯。人工 review 记不住每条新文案，这里把它变成 CI 能强制执行的检查。

匹配规则与运行期一致：
- 源码里的 `\\(...)` 插值、译文表里的 `%@`/`%lld`/`%llu`/`%.1f` 等格式符都归一化成
  同一个占位符再比较——`Text("累计连接 \\(n) 次")` 生成的 key 就是 "累计连接 %lld 次"。
- 注释跳过：整行注释（`//` / `///` / `*`）与行尾注释都不参与查表。
- 真正不该进译文表的中文（如 `name.contains("键盘")` 这种匹配用字面量）写进
  `scripts/localization_allowlist.txt`，一行一条，`#` 开头为注释。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULES = ["CableKit", "CableScopeApp", "CableScopeWidget"]
PLACEHOLDER = "\x00"
CJK = re.compile(r"[一-鿿]")
FORMAT_SPECIFIER = re.compile(r"%(?:lld|llu|ld|lu|d|u|@|[0-9.]*f)")
STRINGS_ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=')


def string_literals(line):
    """逐字符扫描出这一行的字符串字面量，遇到字符串外的 `//` 即停。

    不能只用正则找 `"..."`：行尾注释里的中文（"不重复报"提升""）会被当成待翻译文案，
    而注释本就不参与查表。反过来也不能先按 `//` 截断整行——`"https://..."` 这种
    字面量里就带 `//`。只有按字符串状态扫描才两边都对。
    """
    literals, i, n = [], 0, len(line)
    while i < n:
        char = line[i]
        if char == "/" and i + 1 < n and line[i + 1] == "/":
            break
        if char != '"':
            i += 1
            continue
        i += 1
        start = i
        while i < n:
            if line[i] == "\\":
                i += 2
                continue
            if line[i] == '"':
                break
            i += 1
        if i >= n:  # 该行字符串未闭合（多行字符串等），放弃这一行
            break
        literals.append(line[start:i])
        i += 1
    return literals


def normalize_key(text):
    return FORMAT_SPECIFIER.sub(PLACEHOLDER, text)


def normalize_literal(text):
    """把 Swift 的 `\\(expr)` 插值换成占位符（表达式内部可含括号，按配对扫描）。"""
    out, i = [], 0
    while i < len(text):
        if text.startswith("\\(", i):
            depth, j = 0, i + 1
            while j < len(text):
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            out.append(PLACEHOLDER)
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return normalize_key("".join(out))


def load_allowlist():
    path = ROOT / "scripts" / "localization_allowlist.txt"
    if not path.exists():
        return set()
    return {
        normalize_key(line.strip())
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }


def load_translated_keys(module):
    path = ROOT / "Sources" / module / "Resources" / "en.lproj" / "Localizable.strings"
    if not path.exists():
        return None
    return {
        normalize_key(m.group(1))
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.startswith('"') and (m := STRINGS_ENTRY.match(line))
    }


def scan_module(module, allowlist):
    keys = load_translated_keys(module)
    if keys is None:
        return [(f"Sources/{module}", "缺少 Resources/en.lproj/Localizable.strings")]
    missing = []
    for path in sorted((ROOT / "Sources" / module).rglob("*.swift")):
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.lstrip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            for literal in string_literals(line):
                if not CJK.search(literal):
                    continue
                normalized = normalize_literal(literal)
                if normalized in keys or normalized in allowlist:
                    continue
                missing.append((f"{path.relative_to(ROOT)}:{lineno}",
                                normalized.replace(PLACEHOLDER, "%@")))
    return missing


def main():
    allowlist = load_allowlist()
    failed = False
    for module in MODULES:
        missing = scan_module(module, allowlist)
        if not missing:
            continue
        failed = True
        print(f"{module}：以下中文文案在 en.lproj/Localizable.strings 里没有对应译文")
        for where, text in missing:
            print(f"  {where}\n    {text}")
        print()
    if failed:
        print("补齐译文条目，或把确实不该翻译的字面量加进 scripts/localization_allowlist.txt。")
        return 1
    print("本地化检查通过：所有中文文案都有英文译文。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
