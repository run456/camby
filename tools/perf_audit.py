#!/usr/bin/env python3
"""Camby 性能静态审计（每版固定跑，作为发布门禁第 4 步）。

沙箱/CI 里跑不了真机帧率，所以用**可静态判定的性能红线**做门禁：
新增代码踩到这些红线（滚动列表里做无边界模糊、列表项 setUp 重建、
图片解码宽不设上限、长列表 shrinkWrap、平板列数硬编码）直接判失败。

豁免原则（写在 ALLOW 里，逐条注明理由）：
  - 静态浮层（导航栏/底部弹窗/启动遮罩）里的模糊是「一次性合成」，
    不在滚动路径上，允许保留；
  - 整页背景模糊必须有 RepaintBoundary（已豁免文件的模糊层都带）。

输出：命中项（文件:行 + 原因）；退出码 0 = 通过，1 = 命中红线。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib")

# 豁免：文件 + 关键词 + 理由（评审通过、且不在滚动路径上）
ALLOW = {
    ("lib/main.dart", "blur"): "底部导航玻璃条：静态浮层，不随列表滚动重绘",
    ("lib/pages/detail_page.dart", "blur"): "整页背景模糊：已包 RepaintBoundary，只栅格化一次",
    ("lib/pages/home_page.dart", "blur"): "整页背景模糊：已包 RepaintBoundary",
    ("lib/pages/person_page.dart", "blur"): "整页背景模糊：已包 RepaintBoundary",
    ("lib/pages/search_page.dart", "blur"): "搜索栏玻璃态：静态浮层",
    ("lib/pages/tag_page.dart", "blur"): "顶栏玻璃态：静态浮层",
    ("lib/widgets/status_bar_blur.dart", "blur"): "状态栏模糊本体（自带 RepaintBoundary）",
    ("lib/widgets/glass_sheet.dart", "blur"): "GlassPanel 最外层已包 RepaintBoundary；弹层为居中浮层，模糊只合成一次，不在滚动路径上",
    ("lib/theme.dart", "blur"): "Glass 组件本体（调用方按需自包 RepaintBoundary）",
    ("lib/widgets/media_filter_sheet.dart", "blur"): "底部筛选弹窗：静态浮层，条目数有限",
    ("lib/widgets/media_filter_sheet.dart", "shrinkWrap"): "弹窗内短列表（筛选项 < 20），一次性构建可接受",
    ("lib/widgets/strm_boot_overlay.dart", "blur"): "启动遮罩：一次性合成",
}


def dart_files():
    for base, _, files in os.walk(LIB):
        for f in files:
            if f.endswith(".dart"):
                yield os.path.join(base, f)


def allowed(rel, kind):
    return (rel, kind) in ALLOW


def audit():
    hits = []
    for path in dart_files():
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        src = open(path, encoding="utf-8").read()
        lines = src.split("\n")

        for i, line in enumerate(lines, 1):
            # 红线 1：模糊/滤镜外层必须有 RepaintBoundary（否则每帧重采样）
            if re.search(r"BackdropFilter|ImageFiltered", line):
                if allowed(rel, "blur"):
                    continue
                ctx = "\n".join(lines[max(0, i - 12): i])
                if "RepaintBoundary" not in ctx:
                    hits.append((rel, i, "模糊/滤镜外层未见 RepaintBoundary（每帧重采样）"))

            # 红线 2：CachedImage 必须给 memWidth（限制解码尺寸，防大图爆内存）
            if "CachedImage(" in line and "memWidth" not in line:
                blk = "\n".join(lines[i - 1: i + 8])
                if "memWidth" not in blk:
                    hits.append((rel, i, "CachedImage 未指定 memWidth（解码尺寸不受控）"))

            # 红线 3：列表 itemBuilder 内不得 setState（滚动期整页重建）
            if re.search(r"itemBuilder:\s*\(", line):
                blk = "\n".join(lines[i - 1: i + 25])
                if re.search(r"setState\(", blk):
                    hits.append((rel, i, "列表 itemBuilder 内出现 setState（滚动期整页重建）"))

            # 红线 4：长列表不得 shrinkWrap（一次性构建全部子项）
            if "shrinkWrap: true" in line:
                if allowed(rel, "shrinkWrap"):
                    continue
                blk = "\n".join(lines[max(0, i - 8): i + 4])
                if "GridView" in blk or "ListView" in blk:
                    hits.append((rel, i, "shrinkWrap 滚动容器（长列表一次性构建）"))

            # 红线 5：网格列数必须走断点（上下文 14 行内需出现断点判断）
            if re.search(r"crossAxisCount:\s*\d+", line):
                ctx = "\n".join(lines[max(0, i - 14): i + 2])
                if not re.search(r"isTablet|\bwide\b|tablet", ctx):
                    hits.append((rel, i, "网格列数硬编码（平板会被拉成超大卡片）"))

    return hits


def main():
    hits = audit()
    print("=== 性能静态审计（lib/）===")
    if not hits:
        print("  ✓ 未命中任何性能红线")
        print("  红线：模糊层需 RepaintBoundary / 图片必带 memWidth / "
              "itemBuilder 内禁 setState / 禁 shrinkWrap 长列表 / 网格列数走断点")
        return 0
    print(f"  ✗ 命中 {len(hits)} 项：")
    for rel, line, why in hits:
        print(f"    - {rel}:{line}  {why}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
