"""Split the Gridfinity cutlery set into parts that fit a 140 x 140 mm bed
(FlashForge Finder 2). Run generate_gridfinity.py first.

Long bins are cut into sections of at most 3 grid units (125.5 mm). Each cut
removes 0.5 mm at a grid line, so every section keeps the normal Gridfinity
0.25 mm clearance and locks into the baseplate on its own. Laid end to end on
the baseplate they form one continuous channel (only the end sections have
a wall). The baseplate is split into six 3 x 2 pieces, and the drawer
spacers are plain strips cut to fit the bed.
"""
import os
import manifold3d as m
import numpy as np
import trimesh

GRU = 42
OUT = "finder2_140mm"
BED = 140
DRAWER_L, DRAWER_W = 400, 200
GRID_L, GRID_W = 9, 4
BASE_H = 4.75
TOL = 0.5

# bin name -> section lengths in units, front (scoop end) first
SPLITS = {
    "kitchen_knives_1x9": [3, 3, 3],
    "dinner_knife_1x6": [3, 3],
    "fork_1x5": [3, 2],
    "spoon_1x5": [3, 2],
    "small_fork_1x4": [2, 2],
    "small_spoon_1x4": [2, 2],
    "misc_corkscrew_1x3": [3],
}


def load(path):
    t = trimesh.load(path)
    mesh = m.Mesh(np.asarray(t.vertices, np.float32), np.asarray(t.faces, np.uint32))
    mesh.merge()
    return m.Manifold(mesh)


def save(solid, name):
    out = solid.to_mesh()
    t = trimesh.Trimesh(out.vert_properties[:, :3], out.tri_verts)
    assert t.is_watertight, name
    size = t.bounds[1] - t.bounds[0]
    fits_straight = size[0] <= BED and size[1] <= BED
    fits_diag = (min(size[:2]) + max(size[:2])) / np.sqrt(2) <= BED
    assert fits_straight or fits_diag, (name, size)
    t.apply_translation(-t.bounds[0])
    t.export(os.path.join(OUT, f"{name}.stl"))
    print(f"{name:40s}", np.round(size, 1), "" if fits_straight else "(place diagonally)")


def scoop_at_low_y(solid, half):
    """The scoop adds material at one end; find which one."""
    lo = solid ^ m.Manifold.cube((100, 20, 100), center=True).translate((0, -half + 10, 50))
    hi = solid ^ m.Manifold.cube((100, 20, 100), center=True).translate((0, half - 10, 50))
    return lo.volume() > hi.volume()


def split_bin(name, sections):
    solid = load(f"{name}.stl")
    units = sum(sections)
    half = units * GRU / 2
    if not scoop_at_low_y(solid, half):
        solid = solid.rotate((0, 0, 180))       # put the front (scoop) at low y
    if len(sections) == 1:
        save(solid, f"{name}_whole")
        return
    start = 0
    for i, n in enumerate(sections):
        y0 = -half + start * GRU + (TOL / 2 if i else 0)
        y1 = -half + (start + n) * GRU - (TOL / 2 if i < len(sections) - 1 else 0)
        if i == 0:
            y0 -= 1
        if i == len(sections) - 1:
            y1 += 1
        keep = m.Manifold.cube((100, y1 - y0, 200)).translate((-50, y0, -50))
        part = "front" if i == 0 else "back" if i == len(sections) - 1 else "middle"
        save(solid ^ keep, f"{name}_part{i + 1}_{part}_{n}u")
        start += n


def spacers():
    side_th = (DRAWER_W - GRID_W * GRU) / 2 - TOL     # 15.5 along the long sides
    end_th = (DRAWER_L - GRID_L * GRU) / 2 - TOL      # 10.5 at front and back
    side_len = (DRAWER_L - 1) / 3                     # 3 pieces per side
    end_len = (GRID_W * GRU - TOL) / 2                # 2 pieces per end, between the side strips
    save(m.Manifold.cube((side_th, side_len, BASE_H)), "spacer_long_side_print_6x")
    save(m.Manifold.cube((end_th, end_len, BASE_H)), "spacer_short_end_print_4x")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, sections in SPLITS.items():
        assert sum(sections) == int(name.split("x")[-1])
        split_bin(name, sections)

    import cqgridfinity as gf
    tmp = os.path.join(OUT, "_tmp.stl")
    gf.GridfinityBaseplate(3, 2).save_stl_file(filename=tmp)
    save(load(tmp), "baseplate_3x2_print_6x")
    os.remove(tmp)
    spacers()
