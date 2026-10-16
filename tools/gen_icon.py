"""ChunkSpoke 图标生成（概念「积木成言」）。
背景：#0F1424 -> #F5A623 135° 对角渐变。
前景：三块堆叠的积木气泡（上下深蓝、中间品牌橙且微抬 5°）+ 右下两道渐变声波弧。
输出：Android 自适应图标各密度 PNG（背景/前景/完整/圆角）+ 矢量 XML 源 + 交付截图。
"""
import os
from PIL import Image, ImageDraw

RES = r'd:\写作工具\知识管理\01-Projects-项目\求职与作品集\03-作品集\chunkspoke\chunkspoke-flutter\android\app\src\main\res'
DELIV = r'C:\Users\Admin\Desktop\chunkspoke-icons'

NAVY = (15, 20, 36)       # 0F1424
ORANGE = (245, 166, 35)   # F5A623
BLUE = (39, 64, 107)      # 深蓝积木


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def bg_gradient(size):
    w = h = size
    img = Image.new('RGBA', (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = lerp(NAVY, ORANGE, (x + y) / (w + h)) + (255,)
    return img


def _scale(shapes, s):
    return [(v * s if i % 2 == 0 else v * s) for i, v in enumerate(shapes)]


def make_foreground(size):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = size / 512.0
    S = lambda v: int(round(v * s))

    bx0, bx1 = S(120), S(360)
    blocks = [(120, 196, BLUE), (280, 356, BLUE)]  # top, bottom (middle rotated)

    # 投影（整体偏移，8% 黑）
    sh = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    for (y0, y1) in [(120, 196), (280, 356)]:
        sd.rounded_rectangle([bx0 + S(4), S(y0) + S(6), bx1 + S(4), S(y1) + S(6)],
                             radius=S(18), fill=(0, 0, 0, 42))
    # 中间橙块旋转 5°
    mb = Image.new('RGBA', (bx1 - bx0 + 40, S(96) + 40), (0, 0, 0, 0))
    md = ImageDraw.Draw(mb)
    md.rounded_rectangle([20, 20, (bx1 - bx0) + 20, S(96) + 20], radius=S(18),
                         fill=ORANGE, outline=(255, 255, 255, 90), width=max(1, S(1)))
    mb = mb.rotate(5, expand=True, resample=Image.BICUBIC)
    sh.paste(Image.new('RGBA', mb.size, (0, 0, 0, 0)), (bx0 - 20 + S(4), S(200) - 20 + S(6)))
    img.paste(mb, (bx0 - 20, S(200) - 20), mb)

    # 上/下深蓝块
    for (y0, y1, c) in blocks:
        d.rounded_rectangle([bx0, S(y0), bx1, S(y1)], radius=S(18),
                            fill=c, outline=(255, 255, 255, 60), width=max(1, S(1)))

    # 气泡尾巴（左下）
    tail = [(S(175), S(356)), (S(205), S(356)), (S(160), S(392))]
    sd.polygon([(t[0] + S(4), t[1] + S(6)) for t in tail], fill=(0, 0, 0, 42))
    d.polygon(tail, fill=BLUE, outline=(255, 255, 255, 60))

    img = Image.alpha_composite(sh, img)

    # 右下两道声波弧（橙，粗->细）
    for (w, r) in [(S(12), S(16)), (S(7), S(28))]:
        cx, cy = S(372), S(326)
        d.arc([cx - r, cy - r, cx + r, cy + r], start=295, end=65, fill=ORANGE, width=w)
    return img


def make_full(size):
    bg = bg_gradient(size)
    fg = make_foreground(512).resize((size, size), Image.LANCZOS)
    return Image.alpha_composite(bg, fg).convert('RGBA')


def make_round(size):
    img = make_full(size).convert('RGBA')
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, size - 1, size - 1], fill=255)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def main():
    os.makedirs(DELIV, exist_ok=True)
    dens = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
    for folder, px in dens.items():
        fdir = os.path.join(RES, 'mipmap-' + folder)
        os.makedirs(fdir, exist_ok=True)
        bg = bg_gradient(px)
        fg = make_foreground(512).resize((px, px), Image.LANCZOS)
        full = Image.alpha_composite(bg, fg).convert('RGBA')
        rnd = make_round(px)
        full.save(os.path.join(fdir, 'ic_launcher.png'))
        rnd.save(os.path.join(fdir, 'ic_launcher_round.png'))
        bg.save(os.path.join(fdir, 'ic_launcher_background.png'))
        fg.save(os.path.join(fdir, 'ic_launcher_foreground.png'))
        print('wrote', folder, px)

    # 交付截图
    make_full(48).save(os.path.join(DELIV, 'icon_48.png'))
    make_full(96).save(os.path.join(DELIV, 'icon_96.png'))
    make_full(192).save(os.path.join(DELIV, 'icon_192.png'))
    make_full(512).save(os.path.join(DELIV, 'store_512.png'))
    # 桌面效果图（暗色壁纸）
    wall = Image.new('RGBA', (900, 600), (18, 20, 28, 255))
    icon = make_full(220)
    wall.paste(icon, (340, 190), icon)
    wall.convert('RGB').save(os.path.join(DELIV, 'desktop_effect.png'))
    print('deliverables ->', DELIV)


if __name__ == '__main__':
    main()
