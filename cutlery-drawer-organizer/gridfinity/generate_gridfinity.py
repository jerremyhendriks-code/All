"""Gridfinity version of the 40 x 20 cm cutlery drawer organizer.

Grid: 9 x 4 Gridfinity units (378 x 168 mm). Drawer spacers fill the
remaining 11 mm front/back and 16 mm left/right.

Layout (top view, drawer front at the bottom):

    +------+------+------+------+
    |      | misc |small |small |
    |kitch.| 1x3  | fork | spoon|
    |knives+------+ 1x4  | 1x4  |
    | 1x9  |knife +------+------+
    |      | 1x6  | fork |spoon |
    |      |      | 1x5  | 1x5  |
    +------+------+------+------+

Bins are lipless (cutlery doesn't stack) and have a scoop on the inside
front edge so cutlery is easy to pick up.
"""
import cqgridfinity as gf
import manifold3d as m
import numpy as np
import trimesh

DRAWER_L, DRAWER_W = 400, 200   # front-to-back, left-to-right (mm)
HEIGHT_U = 6                     # 6 x 7 mm = 42 mm bin height, ~47 mm with baseplate

BINS = {
    "kitchen_knives_1x9": 9,
    "dinner_knife_1x6": 6,
    "fork_1x5": 5,
    "spoon_1x5": 5,
    "small_fork_1x4": 4,
    "small_spoon_1x4": 4,
    "misc_corkscrew_1x3": 3,
}


def save(obj, name):
    path = f"{name}.stl"
    obj.save_stl_file(filename=path)
    # OpenCascade's tessellation can leave a few unstitched edges; merge them
    # so slicers get a clean, watertight mesh
    t = trimesh.load(path)
    mesh = m.Mesh(np.asarray(t.vertices, np.float32), np.asarray(t.faces, np.uint32))
    mesh.merge()
    out = m.Manifold(mesh).to_mesh()
    t = trimesh.Trimesh(out.vert_properties[:, :3], out.tri_verts)
    assert t.is_watertight, path
    t.export(path)
    print(f"{path:36s}", np.round(t.bounds[1] - t.bounds[0], 1))


if __name__ == "__main__":
    for name, units in BINS.items():
        save(gf.GridfinityBox(1, units, HEIGHT_U, no_lip=True, scoops=True), name)

    # 9 x 4 baseplate split so each piece fits a 220 x 220 mm bed
    save(gf.GridfinityBaseplate(5, 4), "baseplate_5x4")
    save(gf.GridfinityBaseplate(4, 4), "baseplate_4x4")

    # Spacers that centre the 9 x 4 grid in the drawer. cqgridfinity's x axis is
    # our 400 mm front-to-back direction, so its "length filler" runs along the
    # long left/right sides and its "width filler" sits at the front and back.
    sp = gf.GridfinityDrawerSpacer(DRAWER_L, DRAWER_W, show_arrows=False)
    sp.render()
    save(sp, "spacer_corner_print_4x")
    sp.render_length_filler()
    save(sp, "spacer_long_side_print_2x")
    sp.render_width_filler()
    save(sp, "spacer_short_end_print_2x")
