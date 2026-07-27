#!/usr/bin/env python
# glb2obj.py — 純 Python 把 .glb 的網格（bind pose）轉成 Mixamo 可上傳的 OBJ(+MTL+貼圖) zip。
# 不需要 Blender。用途：立繪轉 3D 的 tripo 模型 → 丟 Mixamo 自動綁骨 + 套專業動捕動畫。
# 用法：python tools/glb2obj.py <input.glb> <outdir> [basename]
import struct, json, sys, os, zipfile

CT = {5120: ('b', 1), 5121: ('B', 1), 5122: ('h', 2), 5123: ('H', 2), 5125: ('I', 4), 5126: ('f', 4)}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def load_glb(path):
    d = open(path, 'rb').read()
    magic, ver, total = struct.unpack('<4sII', d[:12])
    assert magic == b'glTF', 'not a glb'
    off, js, bin_ = 12, None, b''
    while off < total:
        clen, ctype = struct.unpack('<II', d[off:off + 8])
        data = d[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(data.decode('utf-8'))
        elif ctype == 0x004E4942:
            bin_ = data
        off += 8 + clen
    return js, bin_


def read_accessor(j, bin_, idx):
    """回傳 list[tuple]，已套用 byteStride。"""
    acc = j['accessors'][idx]
    n = NC[acc['type']]
    fmt, sz = CT[acc['componentType']]
    count = acc['count']
    bv = j['bufferViews'][acc['bufferView']]
    base = bv.get('byteOffset', 0) + acc.get('byteOffset', 0)
    stride = bv.get('byteStride') or (sz * n)
    out = []
    for i in range(count):
        o = base + i * stride
        out.append(struct.unpack_from('<' + fmt * n, bin_, o))
    return out


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    name = sys.argv[3] if len(sys.argv) > 3 else os.path.splitext(os.path.basename(src))[0]
    os.makedirs(outdir, exist_ok=True)
    j, bin_ = load_glb(src)

    prim = j['meshes'][0]['primitives'][0]
    pos = read_accessor(j, bin_, prim['attributes']['POSITION'])
    nor = read_accessor(j, bin_, prim['attributes']['NORMAL']) if 'NORMAL' in prim['attributes'] else []
    uv = read_accessor(j, bin_, prim['attributes']['TEXCOORD_0']) if 'TEXCOORD_0' in prim['attributes'] else []
    idx = [v[0] for v in read_accessor(j, bin_, prim['indices'])] if 'indices' in prim else list(range(len(pos)))

    # 貼圖：取 baseColor（找不到就取第一張），從 bufferView 抽出來寫檔
    tex_file = None
    try:
        mat = j['materials'][prim['material']]
        ti = mat['pbrMetallicRoughness']['baseColorTexture']['index']
        img_i = j['textures'][ti]['source']
    except Exception:
        img_i = 0 if j.get('images') else None
    if img_i is not None:
        img = j['images'][img_i]
        bv = j['bufferViews'][img['bufferView']]
        blob = bin_[bv.get('byteOffset', 0): bv.get('byteOffset', 0) + bv['byteLength']]
        ext = '.png' if img.get('mimeType') == 'image/png' else '.jpg'
        tex_file = name + '_diffuse' + ext
        open(os.path.join(outdir, tex_file), 'wb').write(blob)

    obj_file = name + '.obj'
    mtl_file = name + '.mtl'
    with open(os.path.join(outdir, obj_file), 'w') as f:
        f.write('# exported by glb2obj.py (bind pose)\n')
        f.write('mtllib %s\n' % mtl_file)
        f.write('o %s\n' % name)
        for v in pos:
            f.write('v %.6f %.6f %.6f\n' % (v[0], v[1], v[2]))
        for t in uv:
            f.write('vt %.6f %.6f\n' % (t[0], 1.0 - t[1]))   # glTF UV 原點在左上，OBJ 在左下
        for n_ in nor:
            f.write('vn %.6f %.6f %.6f\n' % (n_[0], n_[1], n_[2]))
        f.write('usemtl %s\n' % name)
        for i in range(0, len(idx) - 2, 3):
            a, b, c = idx[i] + 1, idx[i + 1] + 1, idx[i + 2] + 1
            if uv and nor:
                f.write('f %d/%d/%d %d/%d/%d %d/%d/%d\n' % (a, a, a, b, b, b, c, c, c))
            elif uv:
                f.write('f %d/%d %d/%d %d/%d\n' % (a, a, b, b, c, c))
            else:
                f.write('f %d %d %d\n' % (a, b, c))
    with open(os.path.join(outdir, mtl_file), 'w') as f:
        f.write('newmtl %s\nKa 1 1 1\nKd 1 1 1\nd 1\nillum 2\n' % name)
        if tex_file:
            f.write('map_Kd %s\n' % tex_file)

    zip_path = os.path.join(outdir, name + '_mixamo.zip')
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(outdir, obj_file), obj_file)
        z.write(os.path.join(outdir, mtl_file), mtl_file)
        if tex_file:
            z.write(os.path.join(outdir, tex_file), tex_file)
    print('verts=%d tris=%d uv=%d nor=%d tex=%s' % (len(pos), len(idx) // 3, len(uv), len(nor), tex_file))
    print('ZIP ->', zip_path, os.path.getsize(zip_path), 'bytes')


if __name__ == '__main__':
    main()
