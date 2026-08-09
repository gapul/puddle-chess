"""Turn Khronos' "A Beautiful Game" chess set into a USDZ that ChessScene can use.

The source is a whole board with all 32 pieces already placed, one material per piece and
colour, and 4K textures — 43 MB. This keeps one mesh per piece kind per colour plus the
board, parks each piece at the origin with its base at y = 0, bakes every transform into the
mesh data (a parent transform is lost when a consumer looks a mesh up by name), and shrinks
the textures to something an app bundle can carry.

Source: A Beautiful Game, CC BY 4.0.
  (c) 2020 ASWF, MaterialX Project — original model
  (c) 2022 Ed Mackey — conversion to glTF
"""
import bpy, os, math, mathutils

# Output name -> source object(s). The pawn is modelled as a body plus the ball on top.
PIECES = {
    "Pawn_White": ["Pawn_Body_W1", "Pawn_Top_W1"],
    "Pawn_Black": ["Pawn_Body_B1", "Pawn_Top_B1"],
    "Rook_White": ["Castle_W1"],
    "Rook_Black": ["Castle_B1"],
    "Knight_White": ["Knight_W1"],
    "Knight_Black": ["Knight_B1"],
    "Bishop_White": ["Bishop_W1"],
    "Bishop_Black": ["Bishop_B1"],
    "Queen_White": ["Queen_W"],
    "Queen_Black": ["Queen_B"],
    "King_White": ["King_W"],
    "King_Black": ["King_B"],
}
BOARD = "Chessboard"

# Blender is Z-up, SceneKit is Y-up.
Z_UP_TO_Y_UP = mathutils.Matrix.Rotation(math.radians(-90), 4, "X")
# In the source, white sits at +Y and its pieces look down the board at -Y. That lands on +Z
# once the axes are converted, but the scene puts white at +Z — so without this the knights
# face their own side.
FACE_DOWN_BOARD = mathutils.Matrix.Rotation(math.radians(180), 4, "Y")
MAX_TEXTURE = 512
PIECE_VERTICES = 4000
# The board is not decimated. Its inlay is cut into the mesh, and collapsing it punches holes
# through the frame that the backdrop shows through — which reads as the board changing colour
# with the appearance.
BOARD_VERTICES = 200_000
# The pieces sit on a 62.5 mm grid in the source. Normalising here means the scene can work
# in squares and never scale anything.
MODEL_SQUARE = 0.0625
TO_SQUARES = mathutils.Matrix.Scale(1 / MODEL_SQUARE, 4)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.abspath("ABeautifulGame.glb"))
bpy.context.view_layer.update()


def bake(obj):
    """Freeze the object's world transform into its vertices and stand it up in Y-up."""
    obj.data.transform(obj.matrix_world)
    obj.matrix_world = mathutils.Matrix.Identity(4)
    obj.parent = None
    obj.data.transform(TO_SQUARES @ FACE_DOWN_BOARD @ Z_UP_TO_Y_UP)


def decimate(obj, target):
    """Collapse the mesh down to roughly `target` vertices.

    The source is film-quality: 42k vertices for a turned bishop, 115k for a flat board. At
    wallpaper size that is invisible detail on 32 instances. Applied through the depsgraph
    rather than `modifier_apply`, which is a no-op in background mode.
    """
    current = len(obj.data.vertices)
    if current <= target:
        return

    modifier = obj.modifiers.new("Decimate", "DECIMATE")
    modifier.ratio = target / current
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = bpy.data.meshes.new_from_object(evaluated)
    obj.modifiers.clear()
    old = obj.data
    obj.data = mesh
    bpy.data.meshes.remove(old)
    mesh.name = obj.name


def bounds(obj):
    """Measured from the vertices: `bound_box` is cached and goes stale the moment the mesh
    data is transformed, which silently ruins every offset computed from it."""
    co = [v.co for v in obj.data.vertices]
    return (
        (min(v.x for v in co), max(v.x for v in co)),
        (min(v.y for v in co), max(v.y for v in co)),
        (min(v.z for v in co), max(v.z for v in co)),
    )


keep = []

for name, sources in PIECES.items():
    parts = [bpy.data.objects[s] for s in sources if s in bpy.data.objects]
    if not parts:
        print("MISSING", name, sources)
        continue

    for part in parts:
        bake(part)

    if len(parts) > 1:
        bpy.ops.object.select_all(action="DESELECT")
        for part in parts:
            part.select_set(True)
        bpy.context.view_layer.objects.active = parts[0]
        bpy.ops.object.join()

    piece = parts[0]
    # Centre on the origin in X/Z and rest the base on y = 0, so the scene positions a piece
    # by moving its node to a square and nothing else.
    (x0, x1), (y0, _), (z0, z1) = bounds(piece)
    piece.data.transform(mathutils.Matrix.Translation((-(x0 + x1) / 2, -y0, -(z0 + z1) / 2)))
    piece.name = name
    piece.data.name = name
    keep.append(piece)

board = bpy.data.objects[BOARD]
bake(board)
(x0, x1), (y0, y1), (z0, z1) = bounds(board)
# The board's top face becomes y = 0: the squares are the plane the pieces stand on.
board.data.transform(mathutils.Matrix.Translation((-(x0 + x1) / 2, -y1, -(z0 + z1) / 2)))
board.name = "Board"
board.data.name = "Board"
keep.append(board)

for obj in list(bpy.data.objects):
    if obj not in keep:
        bpy.data.objects.remove(obj, do_unlink=True)

# 2K PNG textures are most of the 43 MB and none of the difference at wallpaper distance.
# They have to be written back out as files: the exporter copies an image's source data, so
# resizing the in-memory buffer alone changes nothing.
texture_dir = os.path.abspath("textures")
os.makedirs(texture_dir, exist_ok=True)

for index, image in enumerate(bpy.data.images):
    # `has_data` is False until something touches the buffer — `scale()` is what loads it.
    if max(image.size) > MAX_TEXTURE:
        scale = MAX_TEXTURE / max(image.size)
        image.scale(max(1, int(image.size[0] * scale)), max(1, int(image.size[1] * scale)))

    image.file_format = "JPEG"
    image.filepath_raw = os.path.join(texture_dir, f"tex{index}.jpg")
    image.save()
    image.unpack(method="REMOVE") if image.packed_file else None

for obj in bpy.data.objects:
    decimate(obj, BOARD_VERTICES if obj.name == "Board" else PIECE_VERTICES)

bpy.context.view_layer.update()
for obj in bpy.data.objects:
    (x0, x1), (y0, y1), (z0, z1) = bounds(obj)
    print(f"OBJ {obj.name} width={x1 - x0:.3f} height={y1 - y0:.3f} depth={z1 - z0:.3f} base_y={y0:.3f} verts={len(obj.data.vertices)}")

bpy.ops.wm.usd_export(filepath=os.path.abspath("chess-khronos.usdz"), export_materials=True)
