"""Generate STL bins for a 40 x 20 cm cutlery drawer.

Layout (top view, drawer front at the bottom):

    +---------+-----------------------+  ^
    |         | small fork|small spoon|  | 160 mm
    | kitchen +-------+-----+---------+  -
    | knives  | fork  |knife|  spoon  |  | 238 mm
    +---------+-------+-----+---------+  v
       68 mm          130 mm

The 398 mm kitchen-knife bin is too long for a home printer, so it is printed
as two halves. The front half has a tongue that slides into the back half;
a drop of glue there is optional.
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

KITCHEN_W = 68                     # kitchen knives and bigger tools
FORK_W, KNIFE_W, SPOON_W = 44, 36, 50

TONGUE_LEN = 15    # how far the tongue reaches into the back half
TONGUE_T = 1.2     # tongue wall/floor thickness
GAP = 0.2          # sliding fit clearance per side

W = DRAWER_W - CLEARANCE           # 198
L = DRAWER_L - CLEARANCE           # 398
CUTLERY_W = W - KITCHEN_W          # 130
SMALL_W = CUTLERY_W / 2            # 65
SMALL_LEN = L - BIG_LEN            # 160
HALF_LEN = L / 2                   # 199
assert FORK_W + KNIFE_W + SPOON_W == CUTLERY_W


def box(x, y, z, at=(0, 0, 0)):
    return m.Manifold.cube((x, y, z)).translate(at)


def rounded_box(x, y, z, r, open_end=False):
    """Box with rounded vertical corners; with open_end the y=max corners stay square."""
    pts = [(r, r), (x - r, r)]
    parts = [m.Manifold.cylinder(z, r, circular_segments=64).translate((px, py, 0))
             for px, py in pts]
    if open_end:
        parts.append(box(x, 0.01, z, (0, y - 0.01, 0)))
    else:
        parts += [m.Manifold.cylinder(z, r, circular_segments=64).translate((px, y - r, 0))
                  for px in (r, x - r)]
    return m.Manifold.batch_hull(parts)


def bin_(x, y):
    outer = rounded_box(x, y, HEIGHT, RADIUS)
    inner = rounded_box(x - 2 * WALL, y - 2 * WALL, HEIGHT, RADIUS - WALL)
    return outer - inner.translate((WALL, WALL, FLOOR))


def open_bin(x, y):
    """Bin whose y=max end is open."""
    outer = rounded_box(x, y, HEIGHT, RADIUS, open_end=True)
    inner = rounded_box(x - 2 * WALL, y, HEIGHT, RADIUS - WALL, open_end=True)
    return outer - inner.translate((WALL, WALL, FLOOR))


def u_channel(width, length, height, t, at):
    return box(width, length, height, at) - box(width - 2 * t, length, height, (at[0] + t, at[1], at[2] + t))


def kitchen_front():
    x, y = KITCHEN_W, HALF_LEN
    inner_w = x - 2 * WALL
    tongue_w = inner_w - 2 * GAP
    tongue_h = HEIGHT * 0.6
    # tongue sits GAP above the back half's floor and GAP inside its walls
    tongue = u_channel(tongue_w, 10 + TONGUE_LEN, tongue_h, TONGUE_T,
                       (WALL + GAP, y - 10, FLOOR + GAP))
    # collar fills the GAP inside the front half so the tongue is fused to it
    collar = u_channel(inner_w, 10, tongue_h + GAP, TONGUE_T + GAP, (WALL, y - 10, FLOOR - 0.01))
    return open_bin(x, y) + tongue + collar


def kitchen_back():
    # same open bin, mirrored so the open end faces the front half
    return open_bin(KITCHEN_W, HALF_LEN).mirror((0, 1, 0)).translate((0, HALF_LEN, 0))


def save(solid, path):
    mesh = solid.to_mesh()
    tm = trimesh.Trimesh(np.array(mesh.vert_properties)[:, :3], np.array(mesh.tri_verts))
    assert tm.is_watertight, path
    tm.export(path)
    print(path, np.round(tm.bounds[1] - tm.bounds[0], 1))


if __name__ == "__main__":
    save(kitchen_front(), "kitchen_knives_front_half.stl")
    save(kitchen_back(), "kitchen_knives_back_half.stl")
    save(bin_(FORK_W, BIG_LEN), "fork_bin.stl")
    save(bin_(KNIFE_W, BIG_LEN), "knife_bin.stl")
    save(bin_(SPOON_W, BIG_LEN), "spoon_bin.stl")
    save(bin_(SMALL_W, SMALL_LEN), "small_bin_fork_spoon.stl")
    # Whole set as laid out in the drawer, for previewing only (too big to print in one go)
    x = KITCHEN_W
    layout = [kitchen_front(), kitchen_back().translate((0, HALF_LEN, 0))]
    for w in (FORK_W, KNIFE_W, SPOON_W):
        layout.append(bin_(w, BIG_LEN).translate((x, 0, 0)))
        x += w
    layout += [bin_(SMALL_W, SMALL_LEN).translate((KITCHEN_W + i * SMALL_W, BIG_LEN, 0)) for i in range(2)]
    save(m.Manifold.compose(layout), "preview_full_layout.stl")
