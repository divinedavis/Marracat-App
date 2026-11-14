#!/usr/bin/env python3
"""Cut the "how to use Marracat" TikTok (1080x1920, ~40 s) from a simulator
recording of TikTokTourUITests (owner, 2026-10-04).

    ~/.venvs/marracat-ml/bin/python app-store/tiktok/make_tiktok.py RAW.mp4 OUT.mp4

The phone sits under a caption band; captions are drawn with Pillow (this
ffmpeg has no drawtext). Silent audio track: add a sound in TikTok.
Segment times are seconds into RAW, from the tour's "TOUR <step>" marks.
"""
import subprocess, sys, tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

W, H, BAND, PHONE_H = 1080, 1920, 300, 1620
FONT = "/System/Library/Fonts/HelveticaNeue.ttc"
ICON = Path(__file__).resolve().parents[2] / "web/public/apple-touch-icon.png"

# (start, end, speed, caption) — speed > 1 fast-forwards typing.
SEGMENTS = [
    (10.6, 14.8, 1.0, "1,100+ independent brands.\nOne app."),
    (17.0, 19.2, 1.0, "Shop by style"),
    (22.8, 24.5, 1.0, "Shop by style"),
    (32.0, 49.0, 4.5, "Describe what you want…"),
    (53.0, 58.5, 1.0, "…it finds it by meaning,\nright on your iPhone"),
    (60.6, 64.0, 1.0, "Add from any brand"),
    (68.0, 70.5, 1.0, "One cart for every brand"),
    (72.5, 89.0, 4.5, "Enter your details once"),
    (89.3, 93.9, 1.0, "Your address fills itself in"),
    (96.8, 99.6, 1.0, "Every brand's shipping and total,\none screen"),
]
END_CARD_S = 2.8


def font(size, bold=True):
    return ImageFont.truetype(FONT, size, index=1 if bold else 0)


def caption_png(text, path):
    img = Image.new("RGBA", (W, BAND), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    f = font(62)
    lines = text.split("\n")
    heights = [d.textbbox((0, 0), l, font=f)[3] for l in lines]
    y = (BAND - sum(heights) - 14 * (len(lines) - 1)) // 2 + 10
    for l, h in zip(lines, heights):
        w = d.textlength(l, font=f)
        d.text(((W - w) / 2, y), l, font=f, fill="white")
        y += h + 14
    img.save(path)


def end_card(path):
    img = Image.new("RGB", (W, H), "black")
    d = ImageDraw.Draw(img)
    icon = Image.open(ICON).convert("RGBA").resize((300, 300), Image.LANCZOS)
    img.paste(icon, ((W - 300) // 2, 640), icon)
    for text, size, y, bold, color in [("Marracat", 96, 1010, True, "white"),
                                       ("Your next favorite. All in one place.", 46, 1140, False, "#cfcfcf"),
                                       ("On the App Store", 54, 1290, True, "white")]:
        f = font(size, bold)
        w = d.textlength(text, font=f)
        d.text(((W - w) / 2, y), text, font=f, fill=color)
    img.save(path)


def run(*args):
    subprocess.run(args, check=True)


def main(raw, out):
    tmp = Path(tempfile.mkdtemp())
    run("ffmpeg", "-v", "error", "-y", "-i", raw, "-vf", "fps=30", "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", str(tmp / "cfr.mp4"))
    clips = []
    for i, (a, b, speed, text) in enumerate(SEGMENTS):
        caption_png(text, tmp / f"cap{i}.png")
        clip = tmp / f"seg{i}.mp4"
        run("ffmpeg", "-v", "error", "-y", "-i", str(tmp / "cfr.mp4"), "-loop", "1", "-i", str(tmp / f"cap{i}.png"),
            "-filter_complex",
            f"[0:v]trim={a}:{b},setpts=(PTS-STARTPTS)/{speed},scale=-2:{PHONE_H}[p];"
            f"color=black:s={W}x{H}:r=30[bg];[bg][p]overlay=(W-w)/2:{BAND}:shortest=1[v1];"
            f"[v1][1:v]overlay=0:0:shortest=1,format=yuv420p[v]",
            "-map", "[v]", "-r", "30", "-c:v", "libx264", "-crf", "16", "-an", str(clip))
        clips.append(clip)
    end_card(tmp / "end.png")
    run("ffmpeg", "-v", "error", "-y", "-loop", "1", "-i", str(tmp / "end.png"), "-t", str(END_CARD_S),
        "-vf", "format=yuv420p,fade=t=in:st=0:d=0.4", "-r", "30", "-c:v", "libx264", "-crf", "16", str(tmp / "end.mp4"))
    clips.append(tmp / "end.mp4")
    (tmp / "list.txt").write_text("".join(f"file '{c}'\n" for c in clips))
    run("ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(tmp / "list.txt"),
        "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100", "-shortest",
        "-c:v", "libx264", "-profile:v", "high", "-crf", "18", "-pix_fmt", "yuv420p", "-r", "30",
        "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", out)
    print("wrote", out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
