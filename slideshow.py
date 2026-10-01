#!/usr/bin/env python3
"""圖片幻燈片播放器

用法:
    python3 slideshow.py [資料夾路徑] [-i 秒數] [-r] [-s] [-f]

不給資料夾路徑時會跳出視窗讓你選擇。

快捷鍵:
    空白鍵      暫停 / 繼續
    → / ↓      下一張
    ← / ↑      上一張
    + / -      加快 / 放慢播放速度
    F          切換全螢幕
    S          切換隨機順序
    Esc / Q    離開
"""
import argparse
import random
import sys
import tkinter as tk
from pathlib import Path
from tkinter import filedialog

from PIL import Image, ImageOps, ImageTk

EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tif", ".tiff"}


def find_images(folder: Path, recursive: bool) -> list[Path]:
    pattern = folder.rglob("*") if recursive else folder.glob("*")
    return sorted(
        (p for p in pattern if p.is_file() and p.suffix.lower() in EXTENSIONS),
        key=lambda p: str(p).lower(),
    )


class Slideshow:
    def __init__(self, root: tk.Tk, images: list[Path], interval: float, shuffle: bool):
        self.root = root
        self.original = images
        self.images = images[:]
        self.interval_ms = int(interval * 1000)
        self.shuffle = shuffle
        self.index = 0
        self.paused = False
        self.timer = None
        self.photo = None

        if shuffle:
            random.shuffle(self.images)

        root.configure(bg="black")
        self.label = tk.Label(root, bg="black")
        self.label.pack(fill=tk.BOTH, expand=True)
        self.status = tk.Label(root, bg="black", fg="#aaa", font=("Helvetica", 12), anchor="w")
        self.status.place(relx=0, rely=1, anchor="sw", x=10, y=-8)

        root.bind("<space>", lambda e: self.toggle_pause())
        root.bind("<Right>", lambda e: self.step(1))
        root.bind("<Down>", lambda e: self.step(1))
        root.bind("<Left>", lambda e: self.step(-1))
        root.bind("<Up>", lambda e: self.step(-1))
        root.bind("<plus>", lambda e: self.change_speed(-500))
        root.bind("<equal>", lambda e: self.change_speed(-500))
        root.bind("<minus>", lambda e: self.change_speed(500))
        root.bind("<f>", lambda e: self.toggle_fullscreen())
        root.bind("<s>", lambda e: self.toggle_shuffle())
        root.bind("<Escape>", lambda e: self.escape())
        root.bind("<q>", lambda e: root.destroy())
        root.bind("<Configure>", lambda e: self.show() if e.widget is root else None)

        self.show()
        self.schedule()

    # ---- 顯示 ----
    def show(self):
        path = self.images[self.index]
        w = max(self.label.winfo_width(), 100)
        h = max(self.label.winfo_height(), 100)
        try:
            with Image.open(path) as img:
                img = ImageOps.exif_transpose(img)  # 依照相機方向旋轉
                img.thumbnail((w, h), Image.LANCZOS)
                self.photo = ImageTk.PhotoImage(img)
            self.label.configure(image=self.photo, text="")
        except Exception as exc:
            self.label.configure(image="", text=f"無法開啟 {path.name}\n{exc}", fg="white")
        self.update_status()

    def update_status(self):
        path = self.images[self.index]
        flags = []
        if self.paused:
            flags.append("⏸ 暫停")
        if self.shuffle:
            flags.append("🔀 隨機")
        flags.append(f"{self.interval_ms / 1000:.1f}s")
        self.status.configure(
            text=f"{self.index + 1}/{len(self.images)}  {path.name}   " + "  ".join(flags)
        )
        self.root.title(f"幻燈片 - {path.name}")

    # ---- 控制 ----
    def schedule(self):
        if self.timer:
            self.root.after_cancel(self.timer)
            self.timer = None
        if not self.paused:
            self.timer = self.root.after(self.interval_ms, self.advance)

    def advance(self):
        self.step(1)

    def step(self, delta: int):
        self.index = (self.index + delta) % len(self.images)
        self.show()
        self.schedule()

    def toggle_pause(self):
        self.paused = not self.paused
        self.update_status()
        self.schedule()

    def change_speed(self, delta_ms: int):
        self.interval_ms = max(500, min(60000, self.interval_ms + delta_ms))
        self.update_status()
        self.schedule()

    def toggle_shuffle(self):
        current = self.images[self.index]
        self.shuffle = not self.shuffle
        self.images = self.original[:]
        if self.shuffle:
            random.shuffle(self.images)
        self.index = self.images.index(current)
        self.update_status()

    def toggle_fullscreen(self):
        self.root.attributes("-fullscreen", not self.root.attributes("-fullscreen"))

    def escape(self):
        if self.root.attributes("-fullscreen"):
            self.root.attributes("-fullscreen", False)
        else:
            self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description="資料夾圖片幻燈片播放器")
    parser.add_argument("folder", nargs="?", help="圖片資料夾(省略則跳出選擇視窗)")
    parser.add_argument("-i", "--interval", type=float, default=3.0, help="每張秒數(預設 3)")
    parser.add_argument("-r", "--recursive", action="store_true", help="包含子資料夾")
    parser.add_argument("-s", "--shuffle", action="store_true", help="隨機順序")
    parser.add_argument("-f", "--fullscreen", action="store_true", help="全螢幕開始")
    args = parser.parse_args()

    root = tk.Tk()
    root.geometry("1024x720")

    folder = args.folder
    if not folder:
        root.withdraw()
        folder = filedialog.askdirectory(title="選擇圖片資料夾")
        if not folder:
            sys.exit(0)
        root.deiconify()

    folder = Path(folder).expanduser()
    if not folder.is_dir():
        sys.exit(f"找不到資料夾: {folder}")

    images = find_images(folder, args.recursive)
    if not images and not args.recursive:
        images = find_images(folder, recursive=True)  # 只有子資料夾有圖時自動往下找
    if not images:
        sys.exit(f"資料夾裡沒有圖片: {folder}")

    print(f"找到 {len(images)} 張圖片")
    if args.fullscreen:
        root.attributes("-fullscreen", True)
    root.update()
    Slideshow(root, images, args.interval, args.shuffle)
    root.mainloop()


if __name__ == "__main__":
    main()
