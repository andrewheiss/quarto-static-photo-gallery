# /// script
# requires-python = ">=3.11"
# dependencies = ["Pillow", "piexif", "PyYAML"]
# ///
"""
Scan an image directory, generate thumbnails, extract EXIF metadata,
merge an optional album.yml metadata file, and print a JSON manifest to stdout.
"""

import argparse
import json
import sys
from datetime import date, datetime
from pathlib import Path

import piexif
import yaml
from PIL import Image, ImageOps

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff"}


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("album_dir", help="Path to image directory")
    p.add_argument("--thumb-height", type=int, default=300,
                   help="Target thumbnail height in pixels")
    p.add_argument("--thumb-max-width", type=int, default=1200,
                   help="Max thumbnail width in pixels")
    p.add_argument("--thumb-quality", type=int, default=90,
                   help="JPEG quality for thumbnails (1-95)")
    return p.parse_args()


def rational_to_float(rational):
    """Convert a piexif rational tuple (numerator, denominator) to float."""
    if isinstance(rational, (list, tuple)) and len(rational) == 2:
        num, den = rational
        if den == 0:
            return None
        return num / den
    return None


def format_aperture(fnumber_rational):
    val = rational_to_float(fnumber_rational)
    if val is None:
        return None
    return f"f/{val:.1f}".rstrip("0").rstrip(".")


def format_focal_length(fl_rational):
    val = rational_to_float(fl_rational)
    if val is None:
        return None
    return f"{int(round(val))}mm"


def format_shutter(exposure_rational):
    val = rational_to_float(exposure_rational)
    if val is None:
        return None
    if val >= 1:
        return f"{val:.1f}s"
    denom = round(1 / val)
    return f"1/{denom}s"


def format_date(date_bytes):
    """Parse EXIF date string 'YYYY:MM:DD HH:MM:SS' -> ISO 8601.

    Returns 'YYYY-MM-DDTHH:MM:SS' when time is present, 'YYYY-MM-DD' otherwise.
    """
    if not date_bytes:
        return None
    try:
        s = date_bytes.decode("ascii", errors="ignore").strip("\x00")
        if len(s) >= 19:
            date_part = s[:10].replace(":", "-")
            time_part = s[11:19]
            return f"{date_part}T{time_part}"
        if len(s) >= 10:
            return s[:10].replace(":", "-")
    except Exception:
        pass
    return None


def normalize_date_override(value) -> str:
    """Coerce a YAML date/datetime override to an ISO 8601 string."""
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%dT%H:%M:%S")
    if isinstance(value, date):
        return value.strftime("%Y-%m-%d")
    s = str(value).strip()
    # Normalize 'YYYY-MM-DD HH:MM:SS' (space separator) to ISO 8601
    if len(s) >= 19 and s[10] == " ":
        return s[:10] + "T" + s[11:19]
    return s


def extract_exif(image_path: Path) -> dict:
    exif = {}
    try:
        raw = piexif.load(str(image_path))
    except Exception:
        return exif

    ifd0 = raw.get("0th", {})
    exif_ifd = raw.get("Exif", {})

    make = ifd0.get(piexif.ImageIFD.Make, b"")
    model = ifd0.get(piexif.ImageIFD.Model, b"")
    try:
        make_s = make.decode("ascii", errors="ignore").strip("\x00").strip()
        model_s = model.decode("ascii", errors="ignore").strip("\x00").strip()
        if model_s:
            # Avoid duplicating make in model string
            camera = model_s if model_s.startswith(make_s) else f"{make_s} {model_s}".strip()
            exif["camera"] = camera
    except Exception:
        pass

    date_val = exif_ifd.get(piexif.ExifIFD.DateTimeOriginal) or ifd0.get(piexif.ImageIFD.DateTime)
    date_str = format_date(date_val)
    if date_str:
        exif["date"] = date_str

    fl = exif_ifd.get(piexif.ExifIFD.FocalLength)
    if fl:
        exif["focal_length"] = format_focal_length(fl)

    fn = exif_ifd.get(piexif.ExifIFD.FNumber)
    if fn:
        exif["aperture"] = format_aperture(fn)

    et = exif_ifd.get(piexif.ExifIFD.ExposureTime)
    if et:
        exif["shutter"] = format_shutter(et)

    iso = exif_ifd.get(piexif.ExifIFD.ISOSpeedRatings)
    if iso is not None:
        exif["iso"] = str(iso)

    return exif


def generate_thumbnail(src: Path, thumb_path: Path, max_width: int, max_height: int, quality: int):
    """Resize image to fit within max_width × max_height, preserving aspect ratio."""
    with Image.open(src) as img:
        img = ImageOps.exif_transpose(img)  # bake EXIF rotation into pixel data

        orig_w, orig_h = img.size
        scale = min(max_height / orig_h, max_width / orig_w, 1.0)

        thumb_w = max(1, int(orig_w * scale))
        thumb_h = max(1, int(orig_h * scale))

        thumb = img.resize((thumb_w, thumb_h), Image.LANCZOS)

        thumb_path.parent.mkdir(parents=True, exist_ok=True)
        thumb.save(str(thumb_path), "JPEG", quality=quality, optimize=True)

        return thumb_w, thumb_h


def main():
    args = parse_args()
    album_dir = Path(args.album_dir)

    if not album_dir.is_dir():
        print(json.dumps({"error": f"Directory not found: {album_dir}"}))
        sys.exit(1)

    # Load metadata YAML if present
    metadata_path = album_dir / "album.yml"
    metadata: dict = {}
    if metadata_path.exists():
        with open(metadata_path) as f:
            data = yaml.safe_load(f) or {}
            metadata = data.get("images", {})

    thumbs_dir = album_dir / "thumbs"
    thumbs_dir.mkdir(exist_ok=True)

    # Collect and sort image files
    image_files = sorted(
        p for p in album_dir.iterdir()
        if p.is_file() and p.suffix.lower() in IMAGE_EXTENSIONS
    )

    images = []
    for img_path in image_files:
        # Full-size dimensions
        with Image.open(img_path) as im:
            # Respect EXIF orientation for reported dimensions
            try:
                exif_bytes = im.info.get("exif", b"")
                if exif_bytes:
                    exif_data = piexif.load(exif_bytes)
                    orientation = exif_data.get("0th", {}).get(piexif.ImageIFD.Orientation, 1)
                else:
                    orientation = 1
            except Exception:
                orientation = 1

            orig_w, orig_h = im.size
            # If rotated 90/270°, swap reported dimensions
            if orientation in (5, 6, 7, 8):
                orig_w, orig_h = orig_h, orig_w

        thumb_path = thumbs_dir / (img_path.stem + ".jpg")

        # Generate thumbnail (skip if already up-to-date)
        if not thumb_path.exists() or thumb_path.stat().st_mtime < img_path.stat().st_mtime:
            thumb_w, thumb_h = generate_thumbnail(
                img_path, thumb_path,
                max_width=args.thumb_max_width,
                max_height=args.thumb_height,
                quality=args.thumb_quality,
            )
        else:
            with Image.open(thumb_path) as t:
                thumb_w, thumb_h = t.size

        exif = extract_exif(img_path)
        aspect = round(orig_w / orig_h, 4) if orig_h > 0 else 1.0

        # Merge external metadata (external YAML wins for title/description/date/alt)
        override = metadata.get(img_path.name, {})
        title = override.get("title") or img_path.name
        description = override.get("description", "")
        alt = override.get("alt", "")
        date_override = override.get("date")
        if date_override:
            exif["date"] = normalize_date_override(date_override)


        # Relative paths from album_dir's parent (i.e., from the .qmd file directory)
        rel_src = str(img_path)
        rel_thumb = str(thumb_path)

        images.append({
            "src": rel_src,
            "thumb": rel_thumb,
            "width": orig_w,
            "height": orig_h,
            "thumb_width": thumb_w,
            "thumb_height": thumb_h,
            "aspect_ratio": aspect,
            "title": title,
            "description": description,
            "alt": alt,
            "exif": exif,
        })

    manifest = {
        "album_dir": str(album_dir),
        "images": images,
    }
    print(json.dumps(manifest))


if __name__ == "__main__":
    main()
