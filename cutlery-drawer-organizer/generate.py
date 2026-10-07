"""Generate STL bins for a 40 x 20 cm cutlery drawer.

Layout (top view, drawer front at the bottom):

    +---------------------------+  ^
    |  small fork | small spoon |  | 160 mm
    +--------+--------+---------+  -
    |  fork  |  knife |  spoon  |  | 238 mm
    +--------+--------+---------+  v
          198 mm wide total

Print big_bin x3 and small_bin x2.
"""
import manifold3d as m
import trimesh
import numpy as np

DRAWER_L, DRAWER_W = 400, 200
CLEARANCE = 2      # total slack so the bins drop in easily
HEIGHT = 50        # bin height; lower this if your drawer is shallow
WALL = 1.6         # 4 perimeters with a 0.4 mm nozzle
FLOOR = 1.2
RADIUS = 6         # outer vertical corner radius
BIG_LEN = 238      # fits dinner knives up to ~23 cm

W = DRAWER_W - CLEARANCE           # 198
L = DRAWER_L - CLEARANCE           # 398
BIG = (W / 3, BIG_LEN)             # 66 x 238
SMALL = (W / 2, L - BIG_LEN)       # 99 x 160


def rounded_box(x, y, z, r):
    pts = [(r, r), (x - r, r), (r, y - r), (x - r, y - r)]
    cyls = [m.Manifold.cylinder(z, r, circular_segments=64).translate((px, py, 0))
            for px, py in pts]
    return m.Manifold.batch_hull(cyls)


def bin_(x, y):
    outer = rounded_box(x, y, HEIGHT, RADIUS)
    inner = rounded_box(x - 2 * WALL, y - 2 * WALL, HEIGHT, RADIUS - WALL)
    return outer - inner.translate((WALL, WALL, FLOOR))


def save(solid, path):
    mesh = solid.to_mesh()
    tm = trimesh.Trimesh(np.array(mesh.vert_properties)[:, :3], np.array(mesh.tri_verts))
    assert tm.is_watertight
    tm.export(path)
    print(path, tm.bounds[1] - tm.bounds[0])


if __name__ == "__main__":
    save(bin_(*BIG), "big_bin_fork_knife_spoon.stl")
    save(bin_(*SMALL), "small_bin_fork_spoon.stl")
    # Whole set as laid out in the drawer, for previewing only (too big to print in one go)
    layout = m.Manifold.compose(
        [bin_(*BIG).translate((i * BIG[0], 0, 0)) for i in range(3)]
        + [bin_(*SMALL).translate((i * SMALL[0], BIG[1], 0)) for i in range(2)])
    save(layout, "preview_full_layout.stl")
