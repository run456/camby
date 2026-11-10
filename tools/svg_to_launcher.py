#!/usr/bin/env python3
# 将一份 SVG 源文件栅格化成 Android 启动图标所需的五档 mipmap PNG。
# 用法: python3 tools/svg_to_launcher.py <输入.svg> [--apply]
#   --apply  会直接覆盖 android/app/src/main/res/mipmap-*/ic_launcher.png
#   不带 --apply 仅打印将生成的尺寸，便于先确认。
import sys, os, subprocess, shutil

SIZES = {  # 密度: 像素
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

RES_DIR = "android/app/src/main/res"


def main():
    if len(sys.argv) < 2:
        print("用法: python3 tools/svg_to_launcher.py <输入.svg> [--apply]")
        sys.exit(1)
    src = sys.argv[1]
    if not os.path.isfile(src):
        print(f"找不到输入文件: {src}")
        sys.exit(1)
    apply = "--apply" in sys.argv

    # 在临时目录先生成正方形 PNG
    tmp = "/tmp/camby_launcher_gen"
    os.makedirs(tmp, exist_ok=True)
    generated = []
    for _, px in SIZES.items():
        out = os.path.join(tmp, f"icon_{px}.png")
        # cairosvg: --output-width/--output-height 指定最终输出像素尺寸
        subprocess.run(
            [sys.executable, "-m", "cairosvg", src, "--output", out,
             "--output-width", str(px), "--output-height", str(px)],
            check=True,
        )
        generated.append((px, out))

    if not apply:
        print("将生成以下图标 (未写入, 加 --apply 才覆盖):")
        for density, px in SIZES.items():
            print(f"  {density}/ic_launcher.png  -> {px}x{px}")
        return

    for (density, px), out in zip(SIZES.items(), [g[1] for g in generated]):
        dst = os.path.join(RES_DIR, density, "ic_launcher.png")
        shutil.copy(out, dst)
        print(f"已写入 {dst}")


if __name__ == "__main__":
    main()
