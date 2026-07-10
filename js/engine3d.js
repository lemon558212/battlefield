/* ============================================================
 * engine3d.js — 真 3D 場景層（THREE r147，權威：GDD/08）
 * 職責：WebGL 畫「世界」（地形/建物/樹/單位/光影）；HUD/特效仍由
 *   2D canvas 疊層（overlay()），投影沿用 Camera3D → 輸入零改動。
 * 座標映射：世界 (wx,wy,wz高) → THREE (wx, wz, wy)；面向 f → rotation.y=-f
 * 依賴：THREE(vendor)、Camera3D、Render3D(借 HUD 繪法)、Game(唯讀)。
 * THREE 未載入或 WebGL 失敗 → ok=false，game.js 自動 fallback 偽3D。
 * ============================================================ */
"use strict";

const Engine3D = {
  ok: false,
  _units: {},          // unit.id -> THREE.Group
  _mapRef: null,

  init(){
    if (typeof THREE === "undefined") return;
    try {
      const stage = document.getElementById("stage");
      const cv = document.createElement("canvas");
      cv.id = "game3d"; cv.width = 960; cv.height = 600;
      cv.style.cssText = "position:absolute;left:0;top:0;width:100%;height:100%;z-index:0;border:2px solid #3a4232;box-sizing:border-box;";
      stage.insertBefore(cv, stage.firstChild);
      const g2 = document.getElementById("game");
      g2.style.position = "relative"; g2.style.zIndex = "1";
      g2.style.background = "transparent"; g2.style.border = "2px solid transparent";

      this.renderer = new THREE.WebGLRenderer({ canvas: cv, antialias: true, preserveDrawingBuffer: true });
      this.renderer.setSize(960, 600, false);
      this.renderer.shadowMap.enabled = true;
      this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
      this.renderer.outputEncoding = THREE.sRGBEncoding;

      this.scene = new THREE.Scene();
      this.scene.background = new THREE.Color(0x8fb8dc);
      this.scene.fog = new THREE.Fog(0xd9e3ea, 750, 2400);

      this.camera = new THREE.PerspectiveCamera(65, 960 / 600, 2, 6000);

      const hemi = new THREE.HemisphereLight(0xd8ecff, 0x54604a, 0.55);
      this.scene.add(hemi);
      const sun = new THREE.DirectionalLight(0xfff1d6, 0.95);
      sun.position.set(760, 620, 80);
      sun.castShadow = true;
      sun.shadow.mapSize.set(1024, 1024);
      const sc = sun.shadow.camera;
      sc.left = -720; sc.right = 720; sc.top = 720; sc.bottom = -720; sc.far = 2400;
      sun.target.position.set(480, 0, 300);
      this.scene.add(sun); this.scene.add(sun.target);

      this.ok = true;
    } catch (e){ console.warn("Engine3D 初始化失敗，回退偽3D：", e); this.ok = false; }
  },

  /* ---------- 靜態地圖場景 ---------- */
  buildMap(G){
    const m = G.map;
    if (this.mapGroup) this.scene.remove(this.mapGroup);
    const grp = this.mapGroup = new THREE.Group();

    // 遠景大地（地圖外圍基色，接天際）
    const far = new THREE.Mesh(new THREE.PlaneGeometry(9000, 9000),
      new THREE.MeshLambertMaterial({ color: new THREE.Color(m.ground || "#7a8f5a").multiplyScalar(0.9) }));
    far.rotation.x = -Math.PI / 2; far.position.set(480, -0.25, 300); far.receiveShadow = true;
    grp.add(far);

    // 地形貼圖平面（buildTerrain 手繪圖直接當紋理：道路/水/工事全帶入）
    if (!G._bg || G._bgMap !== m) G.buildTerrain(m);
    const tex = new THREE.CanvasTexture(G._bg);
    tex.anisotropy = 4;
    const gnd = new THREE.Mesh(new THREE.PlaneGeometry(960, 600),
      new THREE.MeshLambertMaterial({ map: tex }));
    gnd.rotation.x = -Math.PI / 2; gnd.position.set(480, 0, 300); gnd.receiveShadow = true;
    grp.add(gnd);

    // 建築：擠出盒 + 屋頂
    const wallMat = new THREE.MeshLambertMaterial({ color: 0x6e6a63 });
    const roofMat = new THREE.MeshLambertMaterial({ color: 0x57534c });
    for (const s of (m.solids || [])){
      const b = new THREE.Mesh(new THREE.BoxGeometry(s.w, 42, s.h), wallMat);
      b.position.set(s.x + s.w / 2, 21, s.y + s.h / 2);
      b.castShadow = b.receiveShadow = true; grp.add(b);
      const r = new THREE.Mesh(new THREE.BoxGeometry(s.w + 4, 3, s.h + 4), roofMat);
      r.position.set(s.x + s.w / 2, 43.5, s.y + s.h / 2); r.castShadow = true; grp.add(r);
    }
    // 碉堡：低矮混凝土 + 射口帶
    const bunkMat = new THREE.MeshLambertMaterial({ color: 0x8d8a80 });
    const slitMat = new THREE.MeshLambertMaterial({ color: 0x23211d });
    for (const b of (m.bunkers || [])){
      const k = new THREE.Mesh(new THREE.BoxGeometry(b.w, 24, b.h), bunkMat);
      k.position.set(b.x + b.w / 2, 12, b.y + b.h / 2); k.castShadow = k.receiveShadow = true; grp.add(k);
      const s1 = new THREE.Mesh(new THREE.BoxGeometry(b.w + 0.6, 3.5, b.h + 0.6), slitMat);
      s1.position.set(b.x + b.w / 2, 14, b.y + b.h / 2); grp.add(s1);
    }
    // 樹：幹 + 疊層樹冠（r<18 枯樹只留枝幹）
    const trunkMat = new THREE.MeshLambertMaterial({ color: 0x4a3826 });
    const leafMat = new THREE.MeshLambertMaterial({ color: 0x3a6030 });
    const leafMat2 = new THREE.MeshLambertMaterial({ color: 0x4c7a3c });
    for (const t of (m.trees || [])){
      const dead = t.r < 18, hT = dead ? 26 : 34 + t.r * 0.5;
      const tr = new THREE.Mesh(new THREE.CylinderGeometry(Math.max(1.6, t.r * 0.14), Math.max(2.2, t.r * 0.2), hT, 6), trunkMat);
      tr.position.set(t.x, hT / 2, t.y); tr.castShadow = true; grp.add(tr);
      if (!dead){
        const c1 = new THREE.Mesh(new THREE.ConeGeometry(t.r * 0.95, t.r * 1.5, 7), leafMat);
        c1.position.set(t.x, hT * 0.72 + t.r * 0.5, t.y); c1.castShadow = true; grp.add(c1);
        const c2 = new THREE.Mesh(new THREE.ConeGeometry(t.r * 0.62, t.r * 1.1, 7), leafMat2);
        c2.position.set(t.x, hT * 0.72 + t.r * 1.15, t.y); c2.castShadow = true; grp.add(c2);
      }
    }
    // 主堡旗桿
    for (const b of (m.bases || [])){
      const col = b.side === G.playerSide ? 0x2e6fd8 : 0xc23b22;
      const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.9, 0.9, 46, 6), new THREE.MeshLambertMaterial({ color: 0xcfcfcf }));
      pole.position.set(b.x, 23, b.y); pole.castShadow = true; grp.add(pole);
      const flag = new THREE.Mesh(new THREE.BoxGeometry(16, 9, 0.6), new THREE.MeshLambertMaterial({ color: col, side: THREE.DoubleSide }));
      flag.position.set(b.x + 8, 40, b.y); flag.castShadow = true; grp.add(flag);
      const ring = new THREE.Mesh(new THREE.RingGeometry(12, 16, 24), new THREE.MeshBasicMaterial({ color: col, transparent: true, opacity: 0.55 }));
      ring.rotation.x = -Math.PI / 2; ring.position.set(b.x, 0.25, b.y); grp.add(ring);
    }
    this.scene.add(grp);
    // 舊單位快取全清（換圖重建）
    for (const id in this._units){ this.scene.remove(this._units[id]); }
    this._units = {};
  },

  /* ---------- 單位（幾何體組裝，P2 換 GLTF 模型） ---------- */
  _mkUnit(u, G){
    const g = new THREE.Group();
    const nat = NATIONS[u.nationId];
    const uniform = new THREE.Color(nat.uniformColor);
    const bodyMat = new THREE.MeshLambertMaterial({ color: uniform });
    const darkMat = new THREE.MeshLambertMaterial({ color: 0x23271f });
    const metalMat = new THREE.MeshLambertMaterial({ color: 0x6d726a });
    const steelMat = new THREE.MeshLambertMaterial({ color: 0x8a9099 });
    const add = (mesh, x, y, z) => { mesh.position.set(x, y, z); mesh.castShadow = true; g.add(mesh); return mesh; };

    if (u.cls === "tank"){
      add(new THREE.Mesh(new THREE.BoxGeometry(30, 8, 20), bodyMat), 0, 8, 0);            // 車體
      add(new THREE.Mesh(new THREE.BoxGeometry(32, 5, 4), darkMat), 0, 3, -11);            // 履帶
      add(new THREE.Mesh(new THREE.BoxGeometry(32, 5, 4), darkMat), 0, 3, 11);
      add(new THREE.Mesh(new THREE.BoxGeometry(13, 5.5, 12), metalMat), -1, 14.5, 0);      // 砲塔
      const bar = new THREE.Mesh(new THREE.CylinderGeometry(1.1, 1.1, 24, 8), metalMat);   // 砲管(+x)
      bar.rotation.z = -Math.PI / 2; add(bar, 12, 15, 0);
    } else if (u.domain === "sea"){
      const big = u.big, L = u.cls === "destroyer" ? 46 : u.cls === "lst" ? 40 : 26, W = big ? 13 : 8;
      if (u.cls === "submarine"){
        const hull = new THREE.Mesh(new THREE.CapsuleGeometry ? new THREE.CapsuleGeometry(4.5, 30, 4, 8) : new THREE.CylinderGeometry(4.5, 4.5, 34, 8), steelMat);
        hull.rotation.z = Math.PI / 2; add(hull, 0, 3, 0);
        add(new THREE.Mesh(new THREE.BoxGeometry(6, 7, 3.6), darkMat), 0, 9, 0);           // 帆罩
      } else {
        add(new THREE.Mesh(new THREE.BoxGeometry(L, 7, W), steelMat), 0, 3.5, 0);          // 船體
        add(new THREE.Mesh(new THREE.BoxGeometry(L * 0.3, 8, W * 0.66), darkMat), -L * 0.08, 11, 0); // 艦橋
        if (u.cls === "destroyer"){ const gun = new THREE.Mesh(new THREE.CylinderGeometry(0.9, 0.9, 14, 6), metalMat); gun.rotation.z = -Math.PI / 2; add(gun, L * 0.32, 9, 0); }
      }
    } else if (u.domain === "air"){
      if (u.cls === "gunship"){
        add(new THREE.Mesh(new THREE.BoxGeometry(16, 6, 6), darkMat), 0, 6, 0);
        add(new THREE.Mesh(new THREE.BoxGeometry(12, 1.4, 1.6), darkMat), -12, 8, 0);      // 尾樑
        const rot = new THREE.Mesh(new THREE.BoxGeometry(30, 0.5, 2), steelMat); add(rot, 0, 10.5, 0); this._rotor = rot;
      } else {
        const fus = new THREE.Mesh(new THREE.CylinderGeometry(2.6, 2, 22, 8), steelMat);
        fus.rotation.z = -Math.PI / 2; add(fus, 0, 6, 0);
        add(new THREE.Mesh(new THREE.BoxGeometry(8, 0.8, 26), bodyMat), -2, 6, 0);         // 主翼
        add(new THREE.Mesh(new THREE.BoxGeometry(4, 5, 1), bodyMat), -10, 8, 0);           // 垂尾
      }
    } else {
      // 士兵
      add(new THREE.Mesh(new THREE.BoxGeometry(3.6, 7, 4.6), darkMat), 0, 3.5, 0);         // 腿
      add(new THREE.Mesh(new THREE.CylinderGeometry(3.4, 3.9, 8, 8), bodyMat), 0, 11, 0);  // 軀幹
      add(new THREE.Mesh(new THREE.SphereGeometry(2.5, 8, 7), new THREE.MeshLambertMaterial({ color: 0xd9b48a })), 0, 17.5, 0);
      add(new THREE.Mesh(new THREE.SphereGeometry(2.9, 8, 6, 0, Math.PI * 2, 0, Math.PI * 0.55), darkMat), 0, 18.2, 0); // 頭盔
      const gunL = (u.cls === "sniper" || u.cls === "mg" || u.cls === "at") ? 12 : 9;
      add(new THREE.Mesh(new THREE.BoxGeometry(gunL, 1.2, 1.2), metalMat), gunL / 2 + 1, 12.5, 1.8); // 武器(+x)
      if (u.cls === "at" || u.cls === "sam"){ const tube = new THREE.Mesh(new THREE.CylinderGeometry(1.4, 1.4, 12, 7), darkMat); tube.rotation.z = -Math.PI / 2; add(tube, 2, 16.5, -1.5); }
    }
    // 敵我識別環
    const col = u.side === G.playerSide ? 0x5b9bff : 0xff6f5a;
    const ring = new THREE.Mesh(new THREE.RingGeometry(u.r + 1, u.r + 3, 20), new THREE.MeshBasicMaterial({ color: col, transparent: true, opacity: 0.85 }));
    ring.rotation.x = -Math.PI / 2; ring.position.y = 0.3; g.add(ring);
    return g;
  },

  syncUnits(G){
    const seen = {};
    for (const u of G.units){
      if (!u.alive) continue;
      const isP = u.side === G.playerSide;
      const vis = isP || G.enemyVisible(u);
      let g = this._units[u.id];
      if (!g){ g = this._units[u.id] = this._mkUnit(u, G); this.scene.add(g); }
      g.visible = vis;
      const alt = u.domain === "air" ? 52 : 0;
      g.position.set(u.x, alt, u.y);
      g.rotation.y = -u.facing;
      seen[u.id] = 1;
    }
    for (const id in this._units){
      if (!seen[id]){ this.scene.remove(this._units[id]); delete this._units[id]; }
    }
    if (this._rotor) this._rotor.rotation.y += 0.5; // 直升機旋翼
  },

  /* ---------- 每幀渲染（相機同步自 Camera3D） ---------- */
  render(G){
    if (!this.ok) return;
    if (this._mapRef !== G.map){ this.buildMap(G); this._mapRef = G.map; }
    this.syncUnits(G);
    const cam = Camera3D;
    this.camera.fov = 2 * Math.atan(300 / cam.focal) * 180 / Math.PI;
    this.camera.updateProjectionMatrix();
    this.camera.position.set(cam.cx, cam.ch, cam.cy);
    const cp = Math.cos(cam.pitch);
    this.camera.lookAt(cam.cx + Math.cos(cam.yaw) * cp, cam.ch - Math.sin(cam.pitch), cam.cy + Math.sin(cam.yaw) * cp);
    this.renderer.render(this.scene, this.camera);
  },

  /* ---------- 2D HUD 疊層（畫在透明的 #game 上，投影同 Camera3D） ---------- */
  overlay(ctx, G){
    const cam = Camera3D, m = G.map;
    if (G.state === "deploy" && m.deploy){ const z = m.deploy[G.playerSide]; if (z) Render3D._deployZone(ctx, cam, z); }
    if (cam.mode === "follow" && G.sel && G.sel.weapon) Render3D._rangeRing(ctx, cam, G.sel);
    for (const u of G.units){
      if (!u.alive) continue;
      const isP = u.side === G.playerSide;
      if (!isP && !G.enemyVisible(u)) continue;
      const alt = u.domain === "air" ? 52 : 0;
      const figH = u.cls === "tank" ? 18 : u.domain === "sea" ? 14 : u.domain === "air" ? 12 : 22;
      const top = cam.project(u.x, u.y, alt + figH + 4);
      if (!top) continue;
      const bw = Math.max(14, (u.cls === "tank" ? 30 : 20) * top.scale * 0.5), bx = top.sx - bw / 2, y0 = top.sy - 5;
      ctx.fillStyle = "#222"; ctx.fillRect(bx, y0, bw, 3);
      ctx.fillStyle = u.hp > u.maxhp * 0.3 ? "#4fd05e" : "#e04b3a";
      ctx.fillRect(bx, y0, bw * clamp(u.hp / u.maxhp, 0, 1), 3);
      if (G.sel === u){ ctx.strokeStyle = "#ffd83d"; ctx.lineWidth = 2; ctx.strokeRect(bx - 1, y0 - 1, bw + 2, 5); }
      if (G.aimTarget === u){ const mid = cam.project(u.x, u.y, alt + figH * 0.5);
        if (mid){ ctx.strokeStyle = "#ff5a4a"; ctx.lineWidth = 2; ctx.beginPath(); ctx.arc(mid.sx, mid.sy, Math.max(10, 16 * mid.scale), 0, 7); ctx.stroke(); } }
    }
    for (const f of G.fx) Render3D._fx(ctx, cam, f);
    if (cam.mode === "follow") Render3D._crosshair(ctx, cam.W, cam.H, cam.horizonY());
  }
};
