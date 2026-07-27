# -*- coding: utf-8 -*-
"""立繪離線烘焙：assets/portraits-full/*.jpg → assets/portraits-cut/*.png
兩階段去背（與 2026-07-21 定版一致）：①四角洪水清底 ②透明區向內吃灰白潑墨(176/20)。
新增/重生立繪後執行：python tools/bake-portraits.py"""
import os
from PIL import Image
from collections import deque
src_dir="assets/portraits-full"; out_dir="assets/portraits-cut"
os.makedirs(out_dir, exist_ok=True)
def matte(path,out):
    im=Image.open(path).convert("RGBA"); w,h=im.size; px=im.load()
    corners=[px[0,0],px[w-1,0],px[0,h-1],px[w-1,h-1]]
    near=lambda p: any(abs(p[0]-c[0])+abs(p[1]-c[1])+abs(p[2]-c[2])<110 for c in corners)
    seen=bytearray(w*h); q=deque()
    for x in range(w): q.append((x,0)); q.append((x,h-1))
    for y in range(h): q.append((0,y)); q.append((w-1,y))
    while q:
        x,y=q.pop(); i=y*w+x
        if seen[i]: continue
        seen[i]=1; p=px[x,y]
        if p[3]==0 or not near(p): continue
        px[x,y]=(p[0],p[1],p[2],0)
        if x>0:q.append((x-1,y))
        if x<w-1:q.append((x+1,y))
        if y>0:q.append((x,y-1))
        if y<h-1:q.append((x,y+1))
    greyish=lambda p: max(p[:3])>176 and (max(p[:3])-min(p[:3]))<20
    seen2=bytearray(w*h); q2=deque()
    for y in range(h):
        for x in range(w):
            if px[x,y][3]==0:
                for nx,ny in ((x-1,y),(x+1,y),(x,y-1),(x,y+1)):
                    if 0<=nx<w and 0<=ny<h: q2.append((nx,ny))
    while q2:
        x,y=q2.pop(); i=y*w+x
        if seen2[i]: continue
        seen2[i]=1; p=px[x,y]
        if p[3]==0 or not greyish(p): continue
        px[x,y]=(p[0],p[1],p[2],0)
        for nx,ny in ((x-1,y),(x+1,y),(x,y-1),(x,y+1)):
            if 0<=nx<w and 0<=ny<h: q2.append((nx,ny))
    im.save(out, optimize=True)
files=[f for f in os.listdir(src_dir) if f.lower().endswith(".jpg")]
for f in files: matte(os.path.join(src_dir,f), os.path.join(out_dir,f[:-4]+".png"))
print("baked",len(files))
