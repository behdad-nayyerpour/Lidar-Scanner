#!/usr/bin/env python3
"""Fuse a LiDAR export the same way the app does and render the desk.

Voxel size is the depth footprint at the measured range (about 2 mm at 0.4 m).
Truncation is 2.5 voxels. Samples in front of a nearer surface do not erase it.
"""

import json
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(sys.argv[1])
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else "/opt/cursor/artifacts")
TABLES = Path(__file__).resolve().parents[1] / "LidarScanner" / "Fusion" / "MarchingCubesTables.swift"

CORNERS = np.array([
    [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
    [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
], np.int32)
EDGES = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]


def mat(values):
    return np.array(values, np.float64).reshape(4, 4, order="F")


def load_frames(root):
    frames = json.loads((root / "manifest.json").read_text())["frames"]
    for frame in frames:
        frame["V"] = mat(frame["view"])
        frame["C"] = np.linalg.inv(frame["V"])
    return frames


def confidence_levels(conf):
    # Export PNGs store low/medium/high as 40/160/255. Raw bins store 0/1/2.
    if conf.size == 0 or float(np.max(conf)) <= 2:
        return conf
    levels = np.zeros(conf.shape, np.float32)
    levels[conf >= 200] = 2
    levels[(conf >= 100) & (conf < 200)] = 1
    return levels


def load_depth(root, index):
    png = root / "depth" / f"{index:06d}.png"
    binary = root / "depth" / f"{index:06d}.bin"
    if png.exists():
        depth = np.array(Image.open(png)).astype(np.float32)
        if depth.ndim == 3:
            depth = depth[:, :, 0]
        depth = depth / 1000.0
    else:
        data = binary.read_bytes()
        width, height = struct.unpack_from("<HH", data, 6)
        count = width * height
        values = np.frombuffer(data, dtype="<f4", count=count, offset=10).astype(np.float32)
        depth = values.reshape(height, width).copy()
    conf_path = root / "confidence" / f"{index:06d}.png"
    if conf_path.exists():
        conf = np.array(Image.open(conf_path))
        if conf.ndim == 3:
            conf = conf[:, :, 0]
        conf = conf.astype(np.float32)
    elif binary.exists():
        data = binary.read_bytes()
        width, height = depth.shape[1], depth.shape[0]
        offset = 10 + width * height * 4
        if len(data) >= offset + width * height:
            conf = np.frombuffer(data, dtype=np.uint8, count=width * height, offset=offset).reshape(height, width).astype(np.float32)
        else:
            conf = np.full(depth.shape, 2, np.float32)
    else:
        conf = np.full(depth.shape, 2, np.float32)
    return depth, confidence_levels(conf)


def bilateral(depth):
    padded = np.pad(depth, 1, mode="edge")
    acc = np.zeros_like(depth)
    weight = np.zeros_like(depth)
    for oy in range(-1, 2):
        for ox in range(-1, 2):
            sample = padded[1 + oy:1 + oy + depth.shape[0], 1 + ox:1 + ox + depth.shape[1]]
            spatial = np.exp(-0.5 * (ox * ox + oy * oy))
            valid = (sample > 0.05) & (depth > 0.05)
            ww = spatial * np.exp(-((sample - depth) ** 2) / 0.0016) * valid
            acc += sample * ww
            weight += ww
    return np.where(weight > 0, acc / np.maximum(weight, 1e-6), depth)


def voxel_size(frames, root):
    samples = []
    footprints = []
    stride = max(1, len(frames) // 12)
    for frame in frames[::stride]:
        depth, _ = load_depth(root, frame["index"])
        valid = depth[(depth > 0.2) & (depth < 5)]
        if valid.size:
            samples.append(valid[:: max(1, valid.size // 400)])
        if frame["depthWidth"] > 1 and frame["fx"] > 1 and frame["width"] > 1:
            fx = frame["fx"] * frame["depthWidth"] / frame["width"]
            if fx > 1:
                footprints.append(fx)
    stacked = np.concatenate(samples) if samples else np.array([0.6])
    distance = float(np.percentile(stacked, 25))
    distance = min(3.0, max(0.25, distance))
    footprint = distance / float(np.median(footprints)) * 1000 if footprints else 10
    millimeters = min(15, max(1.5, min(10, footprint)))
    return millimeters / 1000.0, distance, footprint


def pack_keys(world, voxel):
    idx = np.floor(world / voxel).astype(np.int64)
    return (idx[:, 0] + 1_000_000) + (idx[:, 1] + 1_000_000) * 2_000_003 + (idx[:, 2] + 1_000_000) * 4_000_012_000_009


def unpack_keys(keys, voxel):
    z = keys // 4_000_012_000_009
    rem = keys % 4_000_012_000_009
    y = rem // 2_000_003
    x = rem % 2_000_003
    return (np.stack([x, y, z], 1).astype(np.float64) - 1_000_000) * voxel


def accumulate(keys, sdf, weight):
    order = np.argsort(keys, kind="mergesort")
    keys = keys[order]
    sdf = sdf[order]
    weight = weight[order]
    if keys.size == 0:
        return keys, sdf, weight
    change = np.flatnonzero(np.diff(keys)) + 1
    starts = np.r_[0, change]
    sw = np.add.reduceat(sdf * weight, starts)
    ww = np.add.reduceat(weight, starts)
    ww = np.minimum(ww, 48)
    return keys[starts], sw / np.maximum(ww, 1e-6), ww


def merge(keys, sdf, weight, new_keys, new_sdf, new_weight, protect):
    if new_keys.size == 0:
        return keys, sdf, weight
    if keys.size == 0:
        return new_keys, new_sdf, new_weight
    if protect:
        pos = np.searchsorted(keys, new_keys)
        pos = np.clip(pos, 0, keys.size - 1)
        hit = keys[pos] == new_keys
        blocked = hit & (weight[pos] > 1) & (sdf[pos] < 0.5)
        new_keys = new_keys[~blocked]
        new_sdf = new_sdf[~blocked]
        new_weight = new_weight[~blocked]
        if new_keys.size == 0:
            return keys, sdf, weight
    return accumulate(
        np.concatenate([keys, new_keys]),
        np.concatenate([sdf, new_sdf]),
        np.concatenate([weight, new_weight]),
    )


def integrate(frames, root, voxel):
    trunc = voxel * 2.5
    behind = max(1, int(np.ceil(trunc / voxel)))
    ahead = behind * 4
    offsets = np.arange(-ahead, behind + 1, dtype=np.float64) * voxel
    keys = np.zeros(0, np.int64)
    sdf = np.zeros(0, np.float32)
    weight = np.zeros(0, np.float32)
    for frame in frames:
        depth, conf = load_depth(root, frame["index"])
        depth = bilateral(depth)
        height, width = depth.shape
        fx = frame["fx"] * width / frame["width"]
        fy = frame["fy"] * height / frame["height"]
        cx = frame["cx"] * width / frame["width"]
        cy = frame["cy"] * height / frame["height"]
        ys, xs = np.mgrid[0:height, 0:width]
        u = xs + 0.5
        v = ys + 0.5
        z = depth
        valid = (z >= 0.3) & (z <= 3) & (conf >= 1)
        slope_x = np.zeros_like(z)
        slope_y = np.zeros_like(z)
        slope_x[:, 1:-1] = np.abs(z[:, 2:] - z[:, :-2]) * 0.5 * fx / np.maximum(z[:, 1:-1], 0.05)
        slope_y[1:-1, :] = np.abs(z[2:, :] - z[:-2, :]) * 0.5 * fy / np.maximum(z[1:-1, :], 0.05)
        grazing = np.maximum(slope_x, slope_y)
        conf_scale = np.where(conf >= 2, 1.0, 0.3).astype(np.float32)
        sample_weight = np.minimum(8, conf_scale * 2 / np.maximum(z * z, 0.04)).astype(np.float32)
        sample_weight = np.where(grazing > 3.5, sample_weight * 0.25, sample_weight).astype(np.float32)
        x = (u - cx) / fx * z
        y = -(v - cy) / fy * z
        point = np.stack([x, y, -z], 0)
        rng = np.maximum(np.linalg.norm(point, axis=0), 1e-4)
        unit = point / rng
        flat_valid = valid.reshape(-1)
        unit_f = unit.reshape(3, -1)[:, flat_valid]
        z_f = z.reshape(-1)[flat_valid]
        w_f = sample_weight.reshape(-1)[flat_valid]
        point_f = point.reshape(3, -1)[:, flat_valid]
        camera = frame["C"]
        surface_keys = []
        surface_sdf = []
        surface_w = []
        free_keys = []
        free_sdf = []
        free_w = []
        for offset in offsets:
            sample = point_f + unit_f * offset
            sample_depth = -sample[2]
            signed = z_f - sample_depth
            band = (signed >= -trunc) & (signed <= trunc)
            free = signed > trunc
            hom = np.concatenate([sample, np.ones((1, sample.shape[1]))], 0)
            world = (camera @ hom)[:3].T
            if np.any(band):
                surface_keys.append(pack_keys(world[band], voxel))
                surface_sdf.append((signed[band] / trunc).astype(np.float32))
                surface_w.append(w_f[band])
            if np.any(free):
                free_keys.append(pack_keys(world[free], voxel))
                free_sdf.append(np.ones(int(np.count_nonzero(free)), np.float32))
                free_w.append(w_f[free] * 0.5)
        if surface_keys:
            sk, ss, sw = accumulate(np.concatenate(surface_keys), np.concatenate(surface_sdf), np.concatenate(surface_w))
            keys, sdf, weight = merge(keys, sdf, weight, sk, ss, sw, protect=False)
        if free_keys:
            fk, fs, fw = accumulate(np.concatenate(free_keys), np.concatenate(free_sdf), np.concatenate(free_w))
            keys, sdf, weight = merge(keys, sdf, weight, fk, fs, fw, protect=True)
        print(f"frame {frame['index']} voxels {keys.size}", flush=True)
    keep = weight >= 0.15
    return keys[keep], sdf[keep], weight[keep]


def load_tables():
    text = TABLES.read_text()
    edge_blob = text.split("edgeTable:", 1)[1].split("= [", 1)[1].split("]", 1)[0]
    edge = [int(token, 16) for token in edge_blob.replace(",", " ").split() if token.startswith("0x")]
    tri_blob = text.split("triTable:", 1)[1].split("= [", 1)[1]
    rows = []
    for line in tri_blob.splitlines():
        stripped = line.strip().rstrip(",")
        if stripped == "]":
            break
        if not (stripped.startswith("[") and stripped.endswith("]")):
            continue
        body = stripped[1:-1]
        rows.append([int(part) for part in body.split(",") if part.strip()])
    if len(edge) != 256 or len(rows) != 256:
        raise SystemExit(f"bad marching cubes tables edge={len(edge)} tri={len(rows)}")
    return edge, rows


def mesh_crop(keys, sdf, weight, voxel, lo, hi):
    edge_table, tri_table = load_tables()
    corners = (unpack_keys(keys, voxel) / voxel).round().astype(np.int32)
    origin = np.floor(lo / voxel).astype(np.int32) - 2
    size = np.ceil((hi - lo) / voxel).astype(np.int32) + 4
    if np.any(size > 500) or np.prod(size.astype(np.int64)) > 40_000_000:
        raise SystemExit(f"crop too large {size.tolist()} lo {lo.tolist()} hi {hi.tolist()}")
    grid = np.ones(size.tolist(), np.float32)
    wgrid = np.zeros(size.tolist(), np.float32)
    local = corners - origin
    inside = np.all((local >= 0) & (local < size), 1)
    local = local[inside]
    grid[local[:, 0], local[:, 1], local[:, 2]] = sdf[inside]
    wgrid[local[:, 0], local[:, 1], local[:, 2]] = weight[inside]
    known = wgrid >= 0.15
    neg = (grid < 0) & known
    mixed = np.zeros(np.array(size) - 1, bool)
    saw_front = np.zeros_like(mixed)
    saw_inside = np.zeros_like(mixed)
    for corner in CORNERS:
        sl = tuple(slice(int(corner[axis]), int(corner[axis]) + mixed.shape[axis]) for axis in range(3))
        known_c = known[sl]
        neg_c = neg[sl]
        saw_inside |= neg_c
        saw_front |= known_c & ~neg_c
        mixed |= neg_c
    mixed &= saw_front & saw_inside
    xs, ys, zs = np.nonzero(mixed)
    positions = []
    indices = []
    for x, y, z in zip(xs.tolist(), ys.tolist(), zs.tolist()):
        values = []
        cube = 0
        for bit, corner in enumerate(CORNERS):
            gx, gy, gz = x + int(corner[0]), y + int(corner[1]), z + int(corner[2])
            if wgrid[gx, gy, gz] < 0.15:
                values.append(1.0)
            else:
                values.append(float(grid[gx, gy, gz]))
                if values[-1] < 0:
                    cube |= 1 << bit
        if cube == 0 or cube == 255:
            continue
        mask = edge_table[cube]
        edge_vertex = [-1] * 12
        for edge in range(12):
            if mask & (1 << edge) == 0:
                continue
            a, b = EDGES[edge]
            va, vb = values[a], values[b]
            t = 0.5 if abs(va - vb) < 1e-6 else max(0.0, min(1.0, va / (va - vb)))
            pa = CORNERS[a].astype(np.float64)
            pb = CORNERS[b].astype(np.float64)
            position = (np.array([x, y, z], np.float64) + pa + t * (pb - pa) + origin) * voxel
            edge_vertex[edge] = len(positions)
            positions.append(position)
        row = tri_table[cube]
        for cursor in range(0, len(row) - 2, 3):
            e0, e1, e2 = row[cursor:cursor + 3]
            if min(e0, e1, e2) < 0 or max(e0, e1, e2) > 11:
                continue
            i0, i1, i2 = edge_vertex[e0], edge_vertex[e1], edge_vertex[e2]
            if min(i0, i1, i2) < 0:
                continue
            indices.append((i0, i1, i2))
    if not positions:
        raise SystemExit("marching cubes produced an empty mesh")
    return np.array(positions, np.float64), np.array(indices, np.int32)


def subject_center(frames, root):
    """World point in front of the nearer cameras, which are the ones over the desk."""
    ranked = []
    for frame in frames:
        depth, _ = load_depth(root, frame["index"])
        valid = depth[(depth > 0.2) & (depth < 3)]
        if valid.size == 0:
            continue
        ranked.append((float(np.median(valid)), frame, depth))
    ranked.sort(key=lambda item: item[0])
    points = []
    for _, frame, depth in ranked[: max(1, len(ranked) // 2)]:
        height, width = depth.shape
        fx = frame["fx"] * width / frame["width"]
        fy = frame["fy"] * height / frame["height"]
        cx = frame["cx"] * width / frame["width"]
        cy = frame["cy"] * height / frame["height"]
        ys, xs = np.mgrid[height // 5: 4 * height // 5: 4, width // 5: 4 * width // 5: 4]
        z = depth[ys, xs]
        keep = (z > 0.2) & (z < 1.2)
        if not np.any(keep):
            continue
        u = xs[keep] + 0.5
        v = ys[keep] + 0.5
        z = z[keep]
        cam = np.stack([(u - cx) / fx * z, -(v - cy) / fy * z, -z, np.ones_like(z)])
        world = (frame["C"] @ cam)[:3]
        points.append(np.median(world, axis=1))
    if not points:
        return np.zeros(3)
    return np.median(np.stack(points), axis=0)


def desk_and_keyboard(keys, sdf, voxel, center, frames, root):
    points = unpack_keys(keys[np.abs(sdf) < 0.35], voxel)
    local = points[np.max(np.abs(points - center), axis=1) < 0.7]
    if local.shape[0] < 50:
        local = points
    hist, edges = np.histogram(local[:, 1], bins=60)
    desk_y = float((edges[np.argmax(hist)] + edges[np.argmax(hist) + 1]) * 0.5)
    lo = np.array([center[0] - 0.55, desk_y - 0.08, center[2] - 0.45])
    hi = np.array([center[0] + 0.55, desk_y + 0.18, center[2] + 0.45])
    key_lo, key_hi = keyboard_from_color(frames, root, desk_y, center)
    return desk_y, lo, hi, key_lo, key_hi


def keyboard_from_color(frames, root, desk_y, center):
    """Dark, flat patch a centimeter above the desk. That is the keyboard, not the monitor."""
    clouds = []
    for frame in frames:
        path = root / "color" / f"{frame['index']:06d}.jpg"
        if not path.exists():
            continue
        depth, _ = load_depth(root, frame["index"])
        photo = np.asarray(Image.open(path).convert("RGB").resize((depth.shape[1], depth.shape[0]), Image.BILINEAR))
        dark = photo.mean(2) < 70
        height, width = depth.shape
        fx = frame["fx"] * width / frame["width"]
        fy = frame["fy"] * height / frame["height"]
        cx = frame["cx"] * width / frame["width"]
        cy = frame["cy"] * height / frame["height"]
        ys, xs = np.nonzero(dark)
        if ys.size == 0:
            continue
        step = max(1, ys.size // 8000)
        ys, xs = ys[::step], xs[::step]
        z = depth[ys, xs]
        keep = (z > 0.25) & (z < 1.2)
        if not np.any(keep):
            continue
        u = xs[keep] + 0.5
        v = ys[keep] + 0.5
        z = z[keep]
        cam = np.stack([(u - cx) / fx * z, -(v - cy) / fy * z, -z, np.ones_like(z)])
        world = (frame["C"] @ cam)[:3].T
        flat = np.abs(world[:, 1] - (desk_y + 0.012)) < 0.01
        flat &= np.linalg.norm(world[:, [0, 2]] - center[[0, 2]], axis=1) < 0.7
        if np.any(flat):
            clouds.append(world[flat])
    if not clouds:
        return center + np.array([-0.15, 0.004, -0.08]), center + np.array([0.15, 0.025, 0.08])
    band = np.concatenate(clouds)
    scale = 0.01
    origin = band[:, [0, 2]].min(0)
    ix = np.floor((band[:, 0] - origin[0]) / scale).astype(np.int32)
    iz = np.floor((band[:, 2] - origin[1]) / scale).astype(np.int32)
    cells = sorted(set(zip(ix.tolist(), iz.tolist())))
    cell_set = set(cells)
    seen = set()
    best = []
    for seed in cells:
        if seed in seen:
            continue
        stack = [seed]
        seen.add(seed)
        group = []
        while stack:
            cell = stack.pop()
            group.append(cell)
            x, z = cell
            for nxt in ((x + 1, z), (x - 1, z), (x, z + 1), (x, z - 1)):
                if nxt in cell_set and nxt not in seen:
                    seen.add(nxt)
                    stack.append(nxt)
        if len(group) > len(best):
            best = group
    chosen = set(best)
    keep = np.array([(int(x), int(z)) in chosen for x, z in zip(ix, iz)])
    chosen_points = band[keep] if np.any(keep) else band
    lo = np.quantile(chosen_points, 0.05, axis=0)
    hi = np.quantile(chosen_points, 0.95, axis=0)
    lo[1] = desk_y + 0.004
    hi[1] = desk_y + 0.028
    return lo, hi


def keyboard_slab(points, desk_y):
    """Largest flat rectangle sitting a centimeter or two above the desk."""
    band = points[(points[:, 1] > desk_y + 0.006) & (points[:, 1] < desk_y + 0.024)]
    if band.shape[0] < 30:
        return np.array([-0.2, desk_y, -0.1]), np.array([0.2, desk_y + 0.03, 0.1])
    scale = 0.012
    origin = band[:, [0, 2]].min(0)
    ix = np.floor((band[:, 0] - origin[0]) / scale).astype(np.int32)
    iz = np.floor((band[:, 2] - origin[1]) / scale).astype(np.int32)
    cells = {}
    for x, z, y in zip(ix.tolist(), iz.tolist(), band[:, 1].tolist()):
        cells.setdefault((x, z), []).append(y)
    raised = []
    for cell, heights in cells.items():
        heights.sort()
        if heights[len(heights) // 2] - desk_y < 0.008:
            continue
        if any(b - a > 0.008 for a, b in zip(heights, heights[1:])):
            continue
        raised.append(cell)
    raised_set = set(raised)
    seen = set()
    components = []
    for seed in raised:
        if seed in seen:
            continue
        stack = [seed]
        seen.add(seed)
        group = []
        while stack:
            cell = stack.pop()
            group.append(cell)
            x, z = cell
            for nxt in ((x + 1, z), (x - 1, z), (x, z + 1), (x, z - 1)):
                if nxt in raised_set and nxt not in seen:
                    seen.add(nxt)
                    stack.append(nxt)
        components.append(group)
    if not components:
        lo = np.quantile(band, 0.1, axis=0)
        hi = np.quantile(band, 0.9, axis=0)
        lo[1], hi[1] = desk_y + 0.004, desk_y + 0.03
        return lo, hi
    components.sort(key=len, reverse=True)
    chosen = components[0]
    for group in components:
        xs = [cell[0] for cell in group]
        zs = [cell[1] for cell in group]
        width = (max(xs) - min(xs) + 1) * scale
        depth = (max(zs) - min(zs) + 1) * scale
        area = len(group) * scale * scale
        aspect = max(width, depth) / max(min(width, depth), 1e-3)
        if 0.02 < area < 0.2 and 1.4 < aspect < 5:
            chosen = group
            break
    chosen_set = set(chosen)
    keep = [(ix[i], iz[i]) in chosen_set for i in range(ix.shape[0])]
    chosen_points = band[np.array(keep)]
    if chosen_points.shape[0] < 10:
        chosen_points = band
    lo = np.quantile(chosen_points, 0.04, axis=0)
    hi = np.quantile(chosen_points, 0.96, axis=0)
    lo[1] = desk_y + 0.004
    hi[1] = max(hi[1] + 0.004, desk_y + 0.02)
    return lo, hi


def shade_texture(positions, triangles, frames, root):
    colors = np.full((positions.shape[0], 3), 180, np.uint8)
    best = np.full(positions.shape[0], -1e9)
    photos = []
    for frame in frames:
        path = root / "color" / f"{frame['index']:06d}.jpg"
        if not path.exists():
            photos.append(None)
            continue
        image = Image.open(path).convert("RGB")
        image.thumbnail((960, 960))
        photos.append(np.asarray(image))
    for frame, photo in zip(frames, photos):
        if photo is None:
            continue
        hom = np.concatenate([positions.T, np.ones((1, positions.shape[0]))], 0)
        cam = frame["V"] @ hom
        depth = -cam[2]
        height, width = photo.shape[:2]
        fx = frame["fx"] * width / frame["width"]
        fy = frame["fy"] * height / frame["height"]
        cx = frame["cx"] * width / frame["width"]
        cy = frame["cy"] * height / frame["height"]
        good = depth > 0.15
        u = np.zeros_like(depth)
        v = np.zeros_like(depth)
        u[good] = fx * (cam[0, good] / depth[good]) + cx
        v[good] = fy * (-cam[1, good] / depth[good]) + cy
        inside = good & (u >= 0) & (v >= 0) & (u < width - 1) & (v < height - 1)
        score = np.full(depth.shape, -1e9, np.float64)
        score[inside] = 1.0 / np.maximum(depth[inside], 0.2)
        take = score > best
        if not np.any(take):
            continue
        ui = u[take].astype(np.int32)
        vi = v[take].astype(np.int32)
        colors[take] = photo[vi, ui]
        best[take] = score[take]
    face = colors[triangles].mean(axis=1)
    return face.astype(np.uint8)


def render(positions, triangles, face_color, eye, target, path, size=900):
    forward = target - eye
    forward = forward / np.linalg.norm(forward)
    up = np.array([0.0, 1.0, 0.0])
    right = np.cross(forward, up)
    right = right / max(np.linalg.norm(right), 1e-8)
    up = np.cross(right, forward)
    relative = positions - eye
    cam = np.stack([relative @ right, relative @ up, relative @ forward], 1)
    order = np.argsort(cam[triangles].mean(axis=1)[:, 2])[::-1]
    image = Image.new("RGB", (size, size), (244, 244, 244))
    draw = ImageDraw.Draw(image)
    focal = size * 0.9
    for index in order:
        pts = cam[triangles[index]]
        if np.any(pts[:, 2] < 0.05):
            continue
        px = focal * pts[:, 0] / pts[:, 2] + size / 2
        py = size / 2 - focal * pts[:, 1] / pts[:, 2]
        if px.max() < 0 or py.max() < 0 or px.min() >= size or py.min() >= size:
            continue
        polygon = [float(value) for pair in zip(px, py) for value in pair]
        draw.polygon(polygon, fill=tuple(int(channel) for channel in face_color[index]))
    OUT.mkdir(parents=True, exist_ok=True)
    image.save(path)
    print("wrote", path, flush=True)


def layer_map(positions, lo, hi, voxel, path):
    """Top-down view. Red cells have two surfaces more than 3 voxels apart."""
    inside = np.all((positions[:, [0, 2]] >= lo[[0, 2]]) & (positions[:, [0, 2]] <= hi[[0, 2]]), 1)
    pts = positions[inside]
    if pts.shape[0] < 10:
        return 0, 0
    scale = 0.004
    ix = np.floor((pts[:, 0] - lo[0]) / scale).astype(np.int32)
    iz = np.floor((pts[:, 2] - lo[2]) / scale).astype(np.int32)
    nx = int((hi[0] - lo[0]) / scale) + 1
    nz = int((hi[2] - lo[2]) / scale) + 1
    valid = (ix >= 0) & (iz >= 0) & (ix < nx) & (iz < nz)
    ix, iz, ys = ix[valid], iz[valid], pts[valid, 1]
    order = np.lexsort((ys, iz, ix))
    ix, iz, ys = ix[order], iz[order], ys[order]
    cell = ix + iz * nx
    change = np.flatnonzero(np.diff(cell)) + 1
    starts = np.r_[0, change]
    ends = np.r_[change, cell.size]
    image = np.full((nz, nx, 3), 244, np.uint8)
    split = 0
    occupied = 0
    for start, end in zip(starts.tolist(), ends.tolist()):
        occupied += 1
        column = ys[start:end]
        gaps = np.diff(column) > voxel * 3
        layers = 1 + int(np.count_nonzero(gaps))
        x = int(ix[start])
        z = int(iz[start])
        tone = int(np.clip((column.mean() - lo[1]) / max(hi[1] - lo[1], 1e-4) * 255, 0, 255))
        if layers > 1:
            split += 1
            image[z, x] = (220, 40, 40)
        else:
            image[z, x] = (tone, tone, tone)
    Image.fromarray(image).resize((nx * 2, nz * 2), Image.NEAREST).save(path)
    print(f"layer map {path} cells {occupied} split {split}", flush=True)
    return occupied, split


def analyze(positions, triangles, key_lo, key_hi, voxel):
    inside = np.all((positions >= key_lo) & (positions <= key_hi), 1)
    heights = np.sort(positions[inside, 1])
    layers = 1
    if heights.size:
        for gap in np.diff(heights):
            if gap > voxel * 3:
                layers += 1
    longest = 0.0
    edges = positions[triangles[:, 1]] - positions[triangles[:, 0]]
    longest = max(longest, float(np.linalg.norm(edges, axis=1).max()) if len(edges) else 0)
    edges = positions[triangles[:, 2]] - positions[triangles[:, 1]]
    longest = max(longest, float(np.linalg.norm(edges, axis=1).max()) if len(edges) else 0)
    edges = positions[triangles[:, 0]] - positions[triangles[:, 2]]
    longest = max(longest, float(np.linalg.norm(edges, axis=1).max()) if len(edges) else 0)
    return {
        "keyboardVertices": int(heights.size),
        "layers": int(layers),
        "heightMin": float(heights[0]) if heights.size else 0,
        "heightMax": float(heights[-1]) if heights.size else 0,
        "longestEdge": longest,
        "edgeLimit": voxel * 6,
        "keyLo": key_lo.tolist(),
        "keyHi": key_hi.tolist(),
        "voxel": voxel,
    }


def main():
    frames = load_frames(ROOT)
    voxel, distance, footprint = voxel_size(frames, ROOT)
    print(f"frames {len(frames)} voxel {voxel*1000:.2f} mm range {distance:.3f} m footprint {footprint:.2f} mm", flush=True)
    keys, sdf, weight = integrate(frames, ROOT, voxel)
    center_guess = subject_center(frames, ROOT)
    desk_y, lo, hi, key_lo, key_hi = desk_and_keyboard(keys, sdf, voxel, center_guess, frames, ROOT)
    print(f"desk y {desk_y:.3f} crop {lo.tolist()} {hi.tolist()}", flush=True)
    print(f"keyboard {key_lo.tolist()} {key_hi.tolist()}", flush=True)
    positions, triangles = mesh_crop(keys, sdf, weight, voxel, lo, hi)
    print(f"mesh vertices {positions.shape[0]} triangles {triangles.shape[0]}", flush=True)
    stats = analyze(positions, triangles, key_lo, key_hi, voxel)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "desk-stats.json").write_text(json.dumps(stats, indent=2))
    print(json.dumps(stats, indent=2), flush=True)
    occupied, split = layer_map(positions, lo, hi, voxel, OUT / "desk-layers.png")
    stats["layerCells"] = occupied
    stats["splitCells"] = split
    (OUT / "desk-stats.json").write_text(json.dumps(stats, indent=2))
    center = (lo + hi) * 0.5
    center[1] = desk_y
    key_center = (key_lo + key_hi) * 0.5
    textured = shade_texture(positions, triangles, frames, ROOT)
    gray = np.full_like(textured, 170)
    normals = np.cross(positions[triangles[:, 1]] - positions[triangles[:, 0]], positions[triangles[:, 2]] - positions[triangles[:, 0]])
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-8)
    light = np.array([0.2, 0.8, 0.3])
    light /= np.linalg.norm(light)
    shade = np.clip(0.35 + 0.65 * np.abs(normals @ light), 0, 1)
    gray = (gray.astype(np.float32) * shade[:, None]).astype(np.uint8)
    views = {
        "desk-left": center + np.array([-0.15, 0.55, 0.42]),
        "desk-front": center + np.array([0.05, 0.48, 0.5]),
        "desk-right": center + np.array([0.28, 0.52, 0.28]),
    }
    for name, eye in views.items():
        render(positions, triangles, gray, eye, center, OUT / f"untextured-{name}.png")
        render(positions, triangles, textured, eye, center, OUT / f"textured-{name}.png")
    eye = key_center + np.array([0.0, 0.16, max(float(key_hi[2] - key_lo[2]) * 0.9, 0.12)])
    render(positions, triangles, gray, eye, key_center, OUT / "untextured-keyboard.png", size=1000)
    render(positions, triangles, textured, eye, key_center, OUT / "textured-keyboard.png", size=1000)


if __name__ == "__main__":
    main()
