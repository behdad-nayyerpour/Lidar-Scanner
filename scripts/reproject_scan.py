#!/usr/bin/env python3
"""Check a real LiDAR export and write the downsized regression fixture.

`view` is column-major world-to-camera for the landscape photo:
+x right, +y up, -z forward, image v down. `transform` is camera-to-world.
JPEG EXIF orientation is 1. Depth PNGs are millimeters, row 0 at v = 0.
"""

import json
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/realscan")
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else "/tmp/renders")
FIXTURE = Path(sys.argv[3] if len(sys.argv) > 3 else "/workspace/LidarScannerTests/Fixtures/RealScan")


def mat(values):
    return np.array(values, np.float64).reshape(4, 4, order="F")


def frames():
    data = json.loads((ROOT / "manifest.json").read_text())["frames"]
    for frame in data:
        frame["V"] = mat(frame["view"])
        frame["C"] = np.linalg.inv(frame["V"])
        frame["T"] = mat(frame["transform"])
    return data


def depth_of(index):
    return np.array(Image.open(ROOT / "depth" / f"{index:06d}.png")).astype(np.float32) / 1000.0


def color_of(index, edge=640):
    image = Image.open(ROOT / "color" / f"{index:06d}.jpg").convert("RGB")
    scale = min(1.0, edge / max(image.size))
    if scale < 1:
        image = image.resize((int(round(image.width * scale)), int(round(image.height * scale))), Image.BILINEAR)
    return np.asarray(image)


def unproject(depth, frame, flip_v=False):
    h, w = depth.shape
    fx = frame["fx"] * w / frame["width"]
    fy = frame["fy"] * h / frame["height"]
    cx = frame["cx"] * w / frame["width"]
    cy = frame["cy"] * h / frame["height"]
    ys, xs = np.mgrid[0:h, 0:w]
    v = (h - 1 - ys) + 0.5 if flip_v else ys + 0.5
    u = xs + 0.5
    z = depth
    x = (u - cx) / fx * z
    y = -(v - cy) / fy * z
    cam = np.stack([x, y, -z, np.ones_like(z)], 0).reshape(4, -1)
    world = (frame["C"] @ cam)[:3].reshape(3, h, w)
    return world, z > 0.2


def project(world, frame, width, height):
    pts = np.concatenate([world, np.ones((1,) + world.shape[1:])], 0).reshape(4, -1)
    cam = frame["V"] @ pts
    depth = -cam[2]
    fx = frame["fx"] * width / frame["width"]
    fy = frame["fy"] * height / frame["height"]
    cx = frame["cx"] * width / frame["width"]
    cy = frame["cy"] * height / frame["height"]
    good = depth > 0.15
    u = np.zeros_like(depth)
    v = np.zeros_like(depth)
    u[good] = fx * (cam[0, good] / depth[good]) + cx
    v[good] = fy * (-cam[1, good] / depth[good]) + cy
    return u.reshape(world.shape[1:]), v.reshape(world.shape[1:]), depth.reshape(world.shape[1:])


def score(src, dst, flip_v=False):
    all_frames = frames()
    a, b = all_frames[src - 1], all_frames[dst - 1]
    depth = depth_of(src)
    world, valid = unproject(depth, a, flip_v=flip_v)
    color_a = color_of(src)
    color_b = color_of(dst)
    step = 4
    sel = valid[::step, ::step]
    ys, xs = np.mgrid[0:depth.shape[0]:step, 0:depth.shape[1]:step]
    ua = (xs + 0.5) * color_a.shape[1] / depth.shape[1]
    va = (ys + 0.5) * color_a.shape[0] / depth.shape[0]
    u, v, dep = project(world, b, color_b.shape[1], color_b.shape[0])
    u, v, dep = u[::step, ::step], v[::step, ::step], dep[::step, ::step]
    inside = sel & (u >= 1) & (v >= 1) & (u < color_b.shape[1] - 1) & (v < color_b.shape[0] - 1)

    def samp(image, uu, vv):
        return image[np.clip(vv.astype(int), 0, image.shape[0] - 1), np.clip(uu.astype(int), 0, image.shape[1] - 1)]

    depth_b = depth_of(dst)
    dj = samp(depth_b, u * depth_b.shape[1] / color_b.shape[1], v * depth_b.shape[0] / color_b.shape[0])
    d_err = np.abs(dj - dep)[inside]
    c_err = np.linalg.norm(samp(color_a, ua, va).astype(np.float32) - samp(color_b, u, v).astype(np.float32), axis=-1)[inside]
    return float(np.median(d_err)), float(np.median(c_err)), int(inside.sum())


def depth_mesh(depth, frame, step=2):
    h, w = depth.shape
    ys, xs = np.mgrid[0:h:step, 0:w:step]
    z = depth[ys, xs]
    fx = frame["fx"] * w / frame["width"]
    fy = frame["fy"] * h / frame["height"]
    cx = frame["cx"] * w / frame["width"]
    cy = frame["cy"] * h / frame["height"]
    x = ((xs + 0.5) - cx) / fx * z
    y = -((ys + 0.5) - cy) / fy * z
    cam = np.stack([x, y, -z, np.ones_like(z)], -1)
    world = (cam.reshape(-1, 4) @ frame["C"].T)[:, :3].reshape(z.shape + (3,))
    gh, gw = z.shape
    positions, pixels, indices = [], [], []
    vid = -np.ones((gh, gw), np.int32)

    def add(r, c):
        if vid[r, c] >= 0:
            return int(vid[r, c])
        if not (0.2 < z[r, c] < 8):
            return -1
        vid[r, c] = len(positions)
        positions.append(world[r, c])
        pixels.append(((xs[r, c] + 0.5) * frame["width"] / w, (ys[r, c] + 0.5) * frame["height"] / h))
        return int(vid[r, c])

    for r in range(gh - 1):
        for c in range(gw - 1):
            zs = [z[r, c], z[r, c + 1], z[r + 1, c], z[r + 1, c + 1]]
            if min(zs) < 0.2 or max(zs) - min(zs) > 0.12:
                continue
            corners = [add(r, c), add(r, c + 1), add(r + 1, c + 1), add(r + 1, c)]
            if min(corners) < 0:
                continue
            indices += [corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]]
    return np.array(positions, np.float32), np.array(pixels, np.float32), np.array(indices, np.int32)


def render(positions, pixels, indices, image, frame, width, height):
    canvas = np.zeros((height, width, 3), np.uint8)
    zbuf = np.full((height, width), np.inf, np.float32)
    pts = np.concatenate([positions, np.ones((len(positions), 1), np.float32)], 1)
    cam = pts @ frame["V"].T
    depth = -cam[:, 2]
    fx = frame["fx"] * width / frame["width"]
    fy = frame["fy"] * height / frame["height"]
    cx = frame["cx"] * width / frame["width"]
    cy = frame["cy"] * height / frame["height"]
    u = fx * (cam[:, 0] / np.maximum(depth, 1e-4)) + cx
    v = fy * (-cam[:, 1] / np.maximum(depth, 1e-4)) + cy
    sx = image.shape[1] / frame["width"]
    sy = image.shape[0] / frame["height"]
    for t in range(0, len(indices), 3):
        ids = indices[t:t + 3]
        if np.any(depth[ids] < 0.15):
            continue
        tri = np.stack([u[ids], v[ids]], 1)
        z = depth[ids]
        src = pixels[ids]
        minx = max(0, int(np.floor(tri[:, 0].min())))
        maxx = min(width - 1, int(np.ceil(tri[:, 0].max())))
        miny = max(0, int(np.floor(tri[:, 1].min())))
        maxy = min(height - 1, int(np.ceil(tri[:, 1].max())))
        if minx > maxx or miny > maxy or maxx - minx > 500 or maxy - miny > 500:
            continue
        for y in range(miny, maxy + 1):
            for x in range(minx, maxx + 1):
                p = np.array([x + 0.5, y + 0.5])
                w0 = (p[0] - tri[1, 0]) * (tri[2, 1] - tri[1, 1]) - (p[1] - tri[1, 1]) * (tri[2, 0] - tri[1, 0])
                w1 = (p[0] - tri[2, 0]) * (tri[0, 1] - tri[2, 1]) - (p[1] - tri[2, 1]) * (tri[0, 0] - tri[2, 0])
                w2 = (p[0] - tri[0, 0]) * (tri[1, 1] - tri[0, 1]) - (p[1] - tri[0, 1]) * (tri[1, 0] - tri[0, 0])
                if not ((w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0)):
                    continue
                area = w0 + w1 + w2
                if abs(area) < 1e-6:
                    continue
                b0, b1, b2 = w0 / area, w1 / area, w2 / area
                inv = b0 / z[0] + b1 / z[1] + b2 / z[2]
                if inv <= 1e-8:
                    continue
                zz = 1 / inv
                if zz >= zbuf[y, x]:
                    continue
                c0, c1, c2 = (b0 / z[0]) / inv, (b1 / z[1]) / inv, (b2 / z[2]) / inv
                su = (c0 * src[0, 0] + c1 * src[1, 0] + c2 * src[2, 0]) * sx
                sv = (c0 * src[0, 1] + c1 * src[1, 1] + c2 * src[2, 1]) * sy
                xi = int(np.clip(round(su), 0, image.shape[1] - 1))
                yi = int(np.clip(round(sv), 0, image.shape[0] - 1))
                zbuf[y, x] = zz
                canvas[y, x] = image[yi, xi]
    return canvas


def side_by_side(photo, rendered, name):
    h = 360
    left = np.array(Image.fromarray(photo).resize((int(photo.shape[1] * h / photo.shape[0]), h)))
    right = np.array(Image.fromarray(rendered).resize((int(rendered.shape[1] * h / rendered.shape[0]), h)))
    if left.shape[1] != right.shape[1]:
        right = np.array(Image.fromarray(right).resize((left.shape[1], h)))
    both = np.concatenate([left, np.zeros((h, 8, 3), np.uint8), right], 1)
    Image.fromarray(both).save(OUT / name)
    mask = right.sum(-1) > 0
    err = np.abs(left[mask].astype(np.int16) - right[mask].astype(np.int16)).mean() if mask.any() else 999
    return float(err)


def write_fixture(all_frames):
    picks = [1, 8, 16, 23]
    FIXTURE.mkdir(parents=True, exist_ok=True)
    (FIXTURE / "color").mkdir(exist_ok=True)
    (FIXTURE / "depth").mkdir(exist_ok=True)
    stored = []
    for index in picks:
        frame = dict(all_frames[index - 1])
        image = Image.open(ROOT / "color" / f"{index:06d}.jpg").convert("RGB")
        image.thumbnail((480, 480))
        image.save(FIXTURE / "color" / f"{index:06d}.jpg", quality=70)
        scale_x = image.width / frame["width"]
        scale_y = image.height / frame["height"]
        depth = depth_of(index)
        # keep full depth; intrinsics below are for the resized color
        blob = bytearray(b"LDPH")
        blob += struct.pack("<HHH", 1, depth.shape[1], depth.shape[0])
        blob += depth.astype("<f4").tobytes()
        blob += bytes([2]) * depth.size
        (FIXTURE / "depth" / f"{index:06d}.bin").write_bytes(blob)
        frame["width"] = image.width
        frame["height"] = image.height
        frame["fx"] *= scale_x
        frame["fy"] *= scale_y
        frame["cx"] *= scale_x
        frame["cy"] *= scale_y
        frame.pop("V", None)
        frame.pop("C", None)
        frame.pop("T", None)
        stored.append(frame)
    (FIXTURE / "manifest.json").write_text(json.dumps({"frames": stored}))
    print("fixture bytes", sum(p.stat().st_size for p in FIXTURE.rglob("*") if p.is_file()))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    all_frames = frames()
    image = Image.open(ROOT / "color/000001.jpg")
    print("exif orientation", image.getexif().get(274))
    rel = all_frames[0]["T"][:3, :3].T @ all_frames[0]["C"][:3, :3]
    print("transform vs inv(view) max abs", np.max(np.abs(rel - np.eye(3))))
    print("positions match", np.linalg.norm(all_frames[0]["C"][:3, 3] - all_frames[0]["camera"]))
    for flip in (False, True):
        d, c, n = score(1, 8, flip_v=flip)
        print(f"frame1->8 flip_v={flip} depth_med={d:.4f} color_med={c:.1f} n={n}")
    for index in (1, 16):
        frame = all_frames[index - 1]
        positions, pixels, indices = depth_mesh(depth_of(index), frame)
        rendered = render(positions, pixels, indices, color_of(index), frame, 480, 360)
        photo = np.array(Image.fromarray(color_of(index)).resize((480, 360)))
        err = side_by_side(photo, rendered, f"frame-{index:02d}-photo-vs-render.png")
        print(f"render frame {index} mean abs {err:.2f} tris {len(indices)//3}")
    write_fixture(all_frames)


if __name__ == "__main__":
    main()
