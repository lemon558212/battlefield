#!/usr/bin/env python
# retarget.py — 把「來源 glb」的動畫重定向到「目標 glb」的骨架上（純 Python，不需 Blender）。
#
# 為什麼不能直接搬旋轉值：動畫存的是「骨頭區域座標」的旋轉，而兩副骨架的靜止姿勢(rest pose)
# 基準不同，直接複製會扭曲。正確做法是把每根骨的旋轉增量換算到模型空間再換算回目標骨的區域座標：
#   Δs      = Ls_rest^-1 * Ls(t)                 (來源的區域增量)
#   Δ_model = Gs * Δs * Gs^-1                    (轉到模型空間；Gs=來源該骨的靜止全域旋轉)
#   Δt      = Gt^-1 * Δ_model * Gt               (轉進目標骨的區域座標)
#   Lt(t)   = Lt_rest * Δt                       (寫回目標)
#
# 用法：python tools/retarget.py <source.glb> <target.glb> <out.glb>
import struct, json, sys, os, math

CT = {5120: ('b', 1), 5121: ('B', 1), 5122: ('h', 2), 5123: ('H', 2), 5125: ('I', 4), 5126: ('f', 4)}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}

# 目標(tripo) ← 來源(Quaternius) 骨名對應
BONE_MAP = {
    'Hip': 'Hips', 'Waist': 'Abdomen', 'Spine01': 'Torso', 'Spine02': 'Chest',
    'NeckTwist01': 'Neck', 'Head': 'Head',
    'L_Clavicle': 'Shoulder.L', 'L_Upperarm': 'UpperArm.L', 'L_Forearm': 'LowerArm.L', 'L_Hand': 'Wrist.L',
    'R_Clavicle': 'Shoulder.R', 'R_Upperarm': 'UpperArm.R', 'R_Forearm': 'LowerArm.R', 'R_Hand': 'Wrist.R',
    'L_Thigh': 'UpperLeg.L', 'L_Calf': 'LowerLeg.L', 'L_Foot': 'Foot.L', 'L_ToeBase': 'PT.L',
    'R_Thigh': 'UpperLeg.R', 'R_Calf': 'LowerLeg.R', 'R_Foot': 'Foot.R', 'R_ToeBase': 'PT.R',
}
# 要搬的動畫（來源名 → 輸出名；輸出名對齊 Unit.gd 的 Q_MAP）
WANT = {
    'CharacterArmature|Idle_Gun': 'Idle_Gun',
    'CharacterArmature|Idle_Gun_Pointing': 'Idle_Gun_Pointing',
    'CharacterArmature|Gun_Shoot': 'Gun_Shoot',
    'CharacterArmature|Walk': 'Walk',
    'CharacterArmature|Run': 'Run',
    'CharacterArmature|Run_Shoot': 'Run_Shoot',
    'CharacterArmature|HitRecieve': 'HitRecieve',
    'CharacterArmature|Death': 'Death',
}


# ---------- 四元數 ----------
def qmul(a, b):
    ax, ay, az, aw = a; bx, by, bz, bw = b
    return (aw*bx + ax*bw + ay*bz - az*by,
            aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw,
            aw*bw - ax*bx - ay*by - az*bz)


def qconj(q):
    return (-q[0], -q[1], -q[2], q[3])


def qnorm(q):
    n = math.sqrt(sum(c*c for c in q)) or 1.0
    return tuple(c/n for c in q)


def mat_to_quat(m):
    # m = column-major 16 (glTF)
    m00, m01, m02 = m[0], m[4], m[8]
    m10, m11, m12 = m[1], m[5], m[9]
    m20, m21, m22 = m[2], m[6], m[10]
    tr = m00 + m11 + m22
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        w = 0.25 * s; x = (m21 - m12) / s; y = (m02 - m20) / s; z = (m10 - m01) / s
    elif m00 > m11 and m00 > m22:
        s = math.sqrt(1.0 + m00 - m11 - m22) * 2
        w = (m21 - m12) / s; x = 0.25 * s; y = (m01 + m10) / s; z = (m02 + m20) / s
    elif m11 > m22:
        s = math.sqrt(1.0 + m11 - m00 - m22) * 2
        w = (m02 - m20) / s; x = (m01 + m10) / s; y = 0.25 * s; z = (m12 + m21) / s
    else:
        s = math.sqrt(1.0 + m22 - m00 - m11) * 2
        w = (m10 - m01) / s; x = (m02 + m20) / s; y = (m12 + m21) / s; z = 0.25 * s
    return qnorm((x, y, z, w))


# ---------- glb ----------
def load_glb(path):
    d = open(path, 'rb').read()
    magic, ver, total = struct.unpack('<4sII', d[:12])
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


def save_glb(path, js, bin_):
    jb = json.dumps(js, separators=(',', ':')).encode('utf-8')
    jb += b' ' * ((4 - len(jb) % 4) % 4)
    bb = bin_ + b'\x00' * ((4 - len(bin_) % 4) % 4)
    total = 12 + 8 + len(jb) + 8 + len(bb)
    with open(path, 'wb') as f:
        f.write(struct.pack('<4sII', b'glTF', 2, total))
        f.write(struct.pack('<II', len(jb), 0x4E4F534A)); f.write(jb)
        f.write(struct.pack('<II', len(bb), 0x004E4942)); f.write(bb)


def acc_read(js, bin_, idx):
    acc = js['accessors'][idx]
    n = NC[acc['type']]; fmt, sz = CT[acc['componentType']]
    bv = js['bufferViews'][acc['bufferView']]
    base = bv.get('byteOffset', 0) + acc.get('byteOffset', 0)
    stride = bv.get('byteStride') or (sz * n)
    return [struct.unpack_from('<' + fmt * n, bin_, base + i * stride) for i in range(acc['count'])]


def node_local(js, ni):
    nd = js['nodes'][ni]
    if 'matrix' in nd:
        m = nd['matrix']
        return (m[12], m[13], m[14]), mat_to_quat(m)
    t = tuple(nd.get('translation', (0, 0, 0)))
    r = tuple(nd.get('rotation', (0, 0, 0, 1)))
    return t, qnorm(r)


def build_parents(js):
    par = {}
    for i, nd in enumerate(js['nodes']):
        for c in nd.get('children', []):
            par[c] = i
    return par


def global_rot(js, par, ni):
    q = (0, 0, 0, 1)
    chain = []
    cur = ni
    while cur is not None:
        chain.append(cur)
        cur = par.get(cur)
    for n in reversed(chain):
        q = qmul(q, node_local(js, n)[1])
    return qnorm(q)


def main():
    src_p, tgt_p, out_p = sys.argv[1], sys.argv[2], sys.argv[3]
    sj, sb = load_glb(src_p)
    tj, tb = load_glb(tgt_p)
    spar, tpar = build_parents(sj), build_parents(tj)
    sname = {nd.get('name'): i for i, nd in enumerate(sj['nodes'])}
    tname = {nd.get('name'): i for i, nd in enumerate(tj['nodes'])}

    pairs = []   # (tgt_node, src_node, Lt_rest, Gs, Gt)
    for tn, sn in BONE_MAP.items():
        if tn not in tname or sn not in sname:
            print('  skip (missing):', tn, '<-', sn); continue
        ti, si = tname[tn], sname[sn]
        pairs.append((tn, ti, si, node_local(tj, ti)[1], global_rot(sj, spar, si), global_rot(tj, tpar, ti)))
    print('mapped bones:', len(pairs))

    new_bin = bytearray(tb)
    new_anims = []

    def add_accessor(vals, ncomp, atype, minmax=False):
        """vals: list of tuples(float). 回傳 accessor index"""
        while len(new_bin) % 4:
            new_bin.append(0)
        off = len(new_bin)
        for v in vals:
            new_bin.extend(struct.pack('<' + 'f' * ncomp, *v))
        bv = {'buffer': 0, 'byteOffset': off, 'byteLength': len(vals) * 4 * ncomp}
        tj['bufferViews'].append(bv)
        acc = {'bufferView': len(tj['bufferViews']) - 1, 'componentType': 5126,
               'count': len(vals), 'type': atype}
        if minmax:
            acc['min'] = [min(v[i] for v in vals) for i in range(ncomp)]
            acc['max'] = [max(v[i] for v in vals) for i in range(ncomp)]
        tj['accessors'].append(acc)
        return len(tj['accessors']) - 1

    for anim in sj.get('animations', []):
        nm = anim.get('name', '')
        if nm not in WANT:
            continue
        out_name = WANT[nm]
        samplers, channels = [], []
        # 來源 channel 索引：node -> path -> sampler
        by_node = {}
        for ch in anim['channels']:
            by_node.setdefault(ch['target']['node'], {})[ch['target']['path']] = ch['sampler']

        for tn, ti, si, Lt_rest, Gs, Gt in pairs:
            smap = by_node.get(si)
            if not smap or 'rotation' not in smap:
                continue
            sp = anim['samplers'][smap['rotation']]
            times = [t[0] for t in acc_read(sj, sb, sp['input'])]
            quats = acc_read(sj, sb, sp['output'])
            if sp.get('interpolation') == 'CUBICSPLINE':
                quats = quats[1::3]          # 只取中間的實際值，降為 LINEAR
            Ls_rest = node_local(sj, si)[1]
            out_q = []
            for q in quats:
                Ls = qnorm(tuple(q))
                d_s = qmul(qconj(Ls_rest), Ls)              # 來源區域增量
                d_model = qmul(qmul(Gs, d_s), qconj(Gs))    # → 模型空間
                d_t = qmul(qmul(qconj(Gt), d_model), Gt)    # → 目標區域
                out_q.append(qnorm(qmul(Lt_rest, d_t)))     # 寫回目標
            ai = add_accessor([(t,) for t in times], 1, 'SCALAR', minmax=True)
            ao = add_accessor(out_q, 4, 'VEC4')
            samplers.append({'input': ai, 'output': ao, 'interpolation': 'LINEAR'})
            channels.append({'sampler': len(samplers) - 1, 'target': {'node': ti, 'path': 'rotation'}})

        if channels:
            new_anims.append({'name': out_name, 'samplers': samplers, 'channels': channels})
            print('  retargeted: %-22s channels=%d' % (out_name, len(channels)))

    if not new_anims:
        print('!! no animations retargeted'); sys.exit(1)
    tj['animations'] = new_anims
    tj['buffers'][0]['byteLength'] = len(new_bin)
    save_glb(out_p, tj, bytes(new_bin))
    print('OUT ->', out_p, os.path.getsize(out_p), 'bytes; anims =', [a['name'] for a in new_anims])


if __name__ == '__main__':
    main()
