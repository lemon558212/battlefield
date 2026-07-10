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
      this.renderer.toneMapping = THREE.ACESFilmicToneMapping;   // 電影級色調映射
      this.renderer.toneMappingExposure = 1.12;

      this.scene = new THREE.Scene();
      this.scene.background = new THREE.Color(0x8fb8dc);
      this.scene.fog = new THREE.Fog(0xd9e3ea, 750, 2400);

      this.camera = new THREE.PerspectiveCamera(65, 960 / 600, 2, 6000);

      const hemi = new THREE.HemisphereLight(0xd8ecff, 0x54604a, 0.55);
      this.scene.add(hemi);
      const sun = new THREE.DirectionalLight(0xfff1d6, 0.95);
      sun.castShadow = true;
      sun.shadow.mapSize.set(1024, 1024);
      this._sun = sun;
      this.scene.add(sun); this.scene.add(sun.target);

      this.ok = true;
      this.loadModels();
    } catch (e){ console.warn("Engine3D 初始化失敗，回退偽3D：", e); this.ok = false; }
  },

  /* ---------- GLB 模型（CC0，assets/models/）：非同步載入，完成後重建單位 ----------
   * 自動：量包圍盒→縮放到遊戲尺寸→貼地→軸向(長邊=車頭方向)；rotY 為「模型頭朝向修正」。
   * 含 SkinnedMesh 的模型無法簡單 clone → 跳過（維持幾何體），避免共享骨架災難。 */
  _models: {},
  loadModels(){
    if (typeof THREE.GLTFLoader === "undefined") return;
    const loader = new THREE.GLTFLoader();
    const defs = {
      tank:      { url: "assets/models/tank.glb",      len: 34, rotY: Math.PI },     // 頂點分析：砲管原朝 -x
      soldier:   { url: "assets/models/soldier.glb",   h: 19,  rotY: Math.PI / 2 },  // 人物慣例面朝 +z → 轉到 +x
      destroyer: { url: "assets/models/destroyer.glb", len: 46, rotY: Math.PI },     // 頂點分析：艦首朝 -x
      lst:       { url: "assets/models/destroyer.glb", len: 38, rotY: Math.PI },     // 登陸艦暫共用艦體(較短)
      submarine: { url: "assets/models/submarine.glb", len: 34, rotY: Math.PI },     // 帆罩前置 → 首朝 -x
      fighter:   { url: "assets/models/fighter.glb",   len: 24, rotY: 0 },
      attacker:  { url: "assets/models/attacker.glb",  len: 26, rotY: 0 },
      gunship:   { url: "assets/models/gunship.glb",   len: 18, rotY: 0 }
    };
    for (const key in defs){
      const d = defs[key];
      loader.load(d.url, g => {
        const s = g.scene;
        s.traverse(o => { if (o.isMesh){ o.castShadow = true; } });
        const box = new THREE.Box3().setFromObject(s), sz = box.getSize(new THREE.Vector3());
        if (d.len && sz.z > sz.x) s.rotation.y = Math.PI / 2;          // 長邊轉到 +x（車頭軸）
        const box1 = new THREE.Box3().setFromObject(s), sz1 = box1.getSize(new THREE.Vector3());
        const k = d.len ? d.len / Math.max(sz1.x, 0.001) : d.h / Math.max(sz1.y, 0.001);
        s.scale.setScalar(k);
        const box2 = new THREE.Box3().setFromObject(s);
        s.position.y -= box2.min.y;                                     // 貼地
        s.position.x -= (box2.min.x + box2.max.x) / 2;                  // 置中
        s.position.z -= (box2.min.z + box2.max.z) / 2;
        this._models[key] = { scene: s, rotY: d.rotY, anims: g.animations || [] };
        for (const id in this._units){ this.scene.remove(this._units[id]); } // 重建套用模型
        this._units = {};
      }, undefined, () => {});
    }
  },
  /* 複製模型（骨架安全 clone）＋國家染色＋動畫 mixer（idle/walk） */
  _mixers: {},
  _cloneModel(key, u){
    const m = this._models[key];
    if (!m) return null;
    const c = (typeof THREE.SkeletonUtils !== "undefined") ? THREE.SkeletonUtils.clone(m.scene) : m.scene.clone(true);
    const tint = new THREE.Color(NATIONS[u.nationId].uniformColor);
    c.traverse(o => {
      if (o.isMesh){ o.material = o.material.clone(); if (o.material.color) o.material.color.lerp(tint, 0.3); o.castShadow = true; o.frustumCulled = false; }
    });
    if (m.anims.length){
      const mixer = new THREE.AnimationMixer(c);
      const pick = re => m.anims.find(a => re.test(a.name));
      const idle = pick(/idle/i) || m.anims[0];
      const walk = pick(/walk|run|move/i);
      const actions = { idle: mixer.clipAction(idle), walk: walk ? mixer.clipAction(walk) : null };
      actions.idle.play();
      this._mixers[u.id] = { mixer, actions, cur: "idle" };
    }
    const wrap = new THREE.Group();
    c.rotation.y += m.rotY;
    wrap.add(c);
    return wrap;
  },

  /* ---------- 地形高度場（純視覺，遊戲邏輯仍是 2D 平面） ----------
   * 山丘隆起 + 壕溝/彈坑/散兵坑真凹陷。單位/樹/建物 y 皆取此。 */
  heightAt(x, y){
    const m = this._mapRef;
    if (!m) return 0;
    let h = 0;
    for (const H of (m.hills || [])){
      const d2 = ((x - H.x) ** 2 + (y - H.y) ** 2) / (H.r * H.r);
      if (d2 < 1) h += H.h * Math.pow(1 - d2, 1.5);
    }
    for (const t of (m.trenches || [])){
      const dx = Math.max(t.x - x, x - (t.x + t.w), 0), dy = Math.max(t.y - y, y - (t.y + t.h), 0);
      const d = Math.hypot(dx, dy);
      if (d < 5) h -= 6 * (1 - d / 5);
    }
    for (const c of (m.craters || [])){
      const d = Math.hypot(x - c.x, y - c.y);
      if (d < c.r) h -= 4.5 * (1 - (d / c.r) ** 2);
    }
    for (const f of (m.foxholes || [])){
      const d = Math.hypot(x - f.x, y - f.y);
      if (d < f.r) h -= 3.5 * (1 - (d / f.r) ** 2);
    }
    return h;
  },

  /* ---------- 靜態地圖場景 ---------- */
  buildMap(G){
    const m = G.map, mw = m.w || 960, mh = m.h || 600;
    this._mapRef = m;                                    // heightAt 於本函式內即需引用
    const S = Math.max(mw / 960, mh / 600);              // 地圖倍率：光影/霧距離等比
    if (this.mapGroup) this.scene.remove(this.mapGroup);
    const grp = this.mapGroup = new THREE.Group();

    // 太陽/陰影/霧依地圖大小取範圍
    const sun = this._sun;
    sun.position.set(mw * 0.79, 620 * S, mh * 0.13);
    const sc = sun.shadow.camera, ext = Math.max(mw, mh) * 0.78;
    sc.left = -ext; sc.right = ext; sc.top = ext; sc.bottom = -ext; sc.far = 3200 * S;
    sc.updateProjectionMatrix();
    sun.target.position.set(mw / 2, 0, mh / 2);
    this.scene.fog.near = 750 * S; this.scene.fog.far = 2400 * S;
    this.camera.far = 6000 * S;

    // 遠景大地（地圖外圍基色，接天際）
    const far = new THREE.Mesh(new THREE.PlaneGeometry(9000 * S, 9000 * S),
      new THREE.MeshLambertMaterial({ color: new THREE.Color(m.ground || "#7a8f5a").multiplyScalar(0.9) }));
    far.rotation.x = -Math.PI / 2; far.position.set(mw / 2, -0.25, mh / 2); far.receiveShadow = true;
    grp.add(far);

    // 天空穹頂：垂直漸層（頂湛藍→地平線暖白），不受霧影響
    if (!this._skyTex){
      const sc2 = document.createElement("canvas"); sc2.width = 1; sc2.height = 256;
      const g2 = sc2.getContext("2d"), gr = g2.createLinearGradient(0, 0, 0, 256);
      gr.addColorStop(0, "#4f8ac9"); gr.addColorStop(0.55, "#9ec6e6"); gr.addColorStop(0.78, "#e8ddc2"); gr.addColorStop(1, "#efe6cf");
      g2.fillStyle = gr; g2.fillRect(0, 0, 1, 256);
      this._skyTex = new THREE.CanvasTexture(sc2);
    }
    const sky = new THREE.Mesh(new THREE.SphereGeometry(4200 * S, 24, 12, 0, Math.PI * 2, 0, Math.PI * 0.55),
      new THREE.MeshBasicMaterial({ map: this._skyTex, side: THREE.BackSide, fog: false }));
    sky.position.set(mw / 2, -40, mh / 2);
    grp.add(sky);

    // 地形貼圖平面（buildTerrain 手繪圖直接當紋理）＋高度場頂點位移（山丘/壕溝/彈坑真起伏）
    if (!G._bg || G._bgMap !== m) G.buildTerrain(m);
    const tex = new THREE.CanvasTexture(G._bg);
    tex.anisotropy = 4;
    const segX = Math.min(200, Math.round(mw / 10)), segY = Math.min(140, Math.round(mh / 10));
    const geo = new THREE.PlaneGeometry(mw, mh, segX, segY);
    geo.rotateX(-Math.PI / 2);                 // 幾何本身轉平（頂點 y=高度、x/z=世界）
    geo.translate(mw / 2, 0, mh / 2);
    const pos = geo.attributes.position;
    for (let i = 0; i < pos.count; i++){
      pos.setY(i, this.heightAt(pos.getX(i), pos.getZ(i)));
    }
    geo.computeVertexNormals();
    const gnd = new THREE.Mesh(geo, new THREE.MeshLambertMaterial({ map: tex }));
    gnd.receiveShadow = true;
    grp.add(gnd);

    // 建築：擠出盒 + 屋頂
    const wallMat = new THREE.MeshLambertMaterial({ color: 0x6e6a63 });
    const roofMat = new THREE.MeshLambertMaterial({ color: 0x57534c });
    for (const s of (m.solids || [])){
      const hg = this.heightAt(s.x + s.w / 2, s.y + s.h / 2);
      const b = new THREE.Mesh(new THREE.BoxGeometry(s.w, 42, s.h), wallMat);
      b.position.set(s.x + s.w / 2, 21 + hg, s.y + s.h / 2);
      b.castShadow = b.receiveShadow = true; grp.add(b);
      const r = new THREE.Mesh(new THREE.BoxGeometry(s.w + 4, 3, s.h + 4), roofMat);
      r.position.set(s.x + s.w / 2, 43.5 + hg, s.y + s.h / 2); r.castShadow = true; grp.add(r);
    }
    // 碉堡：低矮混凝土 + 射口帶
    const bunkMat = new THREE.MeshLambertMaterial({ color: 0x8d8a80 });
    const slitMat = new THREE.MeshLambertMaterial({ color: 0x23211d });
    for (const b of (m.bunkers || [])){
      const hg = this.heightAt(b.x + b.w / 2, b.y + b.h / 2);
      const k = new THREE.Mesh(new THREE.BoxGeometry(b.w, 24, b.h), bunkMat);
      k.position.set(b.x + b.w / 2, 12 + hg, b.y + b.h / 2); k.castShadow = k.receiveShadow = true; grp.add(k);
      const s1 = new THREE.Mesh(new THREE.BoxGeometry(b.w + 0.6, 3.5, b.h + 0.6), slitMat);
      s1.position.set(b.x + b.w / 2, 14 + hg, b.y + b.h / 2); grp.add(s1);
    }
    // 樹：幹 + 疊層樹冠（r<18 枯樹只留枝幹）
    const trunkMat = new THREE.MeshLambertMaterial({ color: 0x4a3826 });
    const leafMat = new THREE.MeshLambertMaterial({ color: 0x3a6030 });
    const leafMat2 = new THREE.MeshLambertMaterial({ color: 0x4c7a3c });
    for (const t of (m.trees || [])){
      const dead = t.r < 18, hT = dead ? 26 : 34 + t.r * 0.5, hg = this.heightAt(t.x, t.y);
      const tr = new THREE.Mesh(new THREE.CylinderGeometry(Math.max(1.6, t.r * 0.14), Math.max(2.2, t.r * 0.2), hT, 6), trunkMat);
      tr.position.set(t.x, hT / 2 + hg, t.y); tr.castShadow = true; grp.add(tr);
      if (!dead){
        const c1 = new THREE.Mesh(new THREE.ConeGeometry(t.r * 0.95, t.r * 1.5, 7), leafMat);
        c1.position.set(t.x, hT * 0.72 + t.r * 0.5 + hg, t.y); c1.castShadow = true; grp.add(c1);
        const c2 = new THREE.Mesh(new THREE.ConeGeometry(t.r * 0.62, t.r * 1.1, 7), leafMat2);
        c2.position.set(t.x, hT * 0.72 + t.r * 1.15 + hg, t.y); c2.castShadow = true; grp.add(c2);
      }
    }
    // 主堡旗桿
    for (const b of (m.bases || [])){
      const col = b.side === G.playerSide ? 0x2e6fd8 : 0xc23b22, hg = this.heightAt(b.x, b.y);
      const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.9, 0.9, 46, 6), new THREE.MeshLambertMaterial({ color: 0xcfcfcf }));
      pole.position.set(b.x, 23 + hg, b.y); pole.castShadow = true; grp.add(pole);
      const flag = new THREE.Mesh(new THREE.BoxGeometry(16, 9, 0.6), new THREE.MeshLambertMaterial({ color: col, side: THREE.DoubleSide }));
      flag.position.set(b.x + 8, 40 + hg, b.y); flag.castShadow = true; grp.add(flag);
      const ring = new THREE.Mesh(new THREE.RingGeometry(12, 16, 24), new THREE.MeshBasicMaterial({ color: col, transparent: true, opacity: 0.55 }));
      ring.rotation.x = -Math.PI / 2; ring.position.set(b.x, 0.25 + hg, b.y); grp.add(ring);
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

    // 模型優先（士兵共用 soldier；各載具依 cls；缺檔/載入中回退下方幾何體）
    const modelKey = (u.domain === "land" && u.cls !== "tank") ? "soldier" : u.cls;
    const mdl0 = this._cloneModel(modelKey, u);
    if (mdl0){ g.add(mdl0); this._addRing(g, u, G); return g; }

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
      // 士兵（幾何體 fallback）
      add(new THREE.Mesh(new THREE.BoxGeometry(3.6, 7, 4.6), darkMat), 0, 3.5, 0);         // 腿
      add(new THREE.Mesh(new THREE.CylinderGeometry(3.4, 3.9, 8, 8), bodyMat), 0, 11, 0);  // 軀幹
      add(new THREE.Mesh(new THREE.SphereGeometry(2.5, 8, 7), new THREE.MeshLambertMaterial({ color: 0xd9b48a })), 0, 17.5, 0);
      add(new THREE.Mesh(new THREE.SphereGeometry(2.9, 8, 6, 0, Math.PI * 2, 0, Math.PI * 0.55), darkMat), 0, 18.2, 0); // 頭盔
      const gunL = (u.cls === "sniper" || u.cls === "mg" || u.cls === "at") ? 12 : 9;
      add(new THREE.Mesh(new THREE.BoxGeometry(gunL, 1.2, 1.2), metalMat), gunL / 2 + 1, 12.5, 1.8); // 武器(+x)
      if (u.cls === "at" || u.cls === "sam"){ const tube = new THREE.Mesh(new THREE.CylinderGeometry(1.4, 1.4, 12, 7), darkMat); tube.rotation.z = -Math.PI / 2; add(tube, 2, 16.5, -1.5); }
    }
    this._addRing(g, u, G);
    return g;
  },
  _addRing(g, u, G){
    const col = u.side === G.playerSide ? 0x5b9bff : 0xff6f5a;
    const ring = new THREE.Mesh(new THREE.RingGeometry(u.r + 1, u.r + 3, 20), new THREE.MeshBasicMaterial({ color: col, transparent: true, opacity: 0.85 }));
    ring.rotation.x = -Math.PI / 2; ring.position.y = 0.3; g.add(ring);
    g.userData.ring = ring;
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
      const alt = u.domain === "air" ? 52 : (u.domain === "sea" ? 0 : this.heightAt(u.x, u.y));
      const moved = Math.hypot(g.position.x - u.x, g.position.z - u.y) > 0.4;
      g.position.set(u.x, alt, u.y);
      g.rotation.y = -u.facing;
      // 選中單位：識別環轉金色脈動
      const ring = g.userData.ring;
      if (ring){
        if (G.sel === u){
          ring.material.color.setHex(0xffd83d);
          const p = 1 + 0.18 * Math.sin(performance.now() / 160);
          ring.scale.set(p, p, 1);
        } else {
          ring.material.color.setHex(u.side === G.playerSide ? 0x5b9bff : 0xff6f5a);
          ring.scale.set(1, 1, 1);
        }
      }
      // 動畫：移動→walk、靜止→idle
      const mx = this._mixers[u.id];
      if (mx && mx.actions.walk && mx.cur !== "shoot"){   // 射擊動畫播畢由 finished 監聽器接回
        const want = moved ? "walk" : "idle";
        if (want !== mx.cur){ mx.actions[mx.cur].stop(); mx.actions[want].play(); mx.cur = want; }
      }
      seen[u.id] = 1;
    }
    for (const id in this._units){
      if (!seen[id]){ this.scene.remove(this._units[id]); delete this._units[id];
        if (this._mixers[id]){ delete this._mixers[id]; } }
    }
    if (this._rotor) this._rotor.rotation.y += 0.5; // 直升機旋翼
  },

  /* ---------- 3D 特效（曳光/爆炸/槍口閃光，資料仍是 Game.fx） ---------- */
  _fxMap: new Map(),
  syncFx(G){
    const seen = new Set();
    for (const f of G.fx){
      if (f.type !== "tracer" && f.type !== "boom") continue;   // 文字類仍走 2D
      seen.add(f);
      let e = this._fxMap.get(f);
      if (!e){ e = this._mkFx(f); this._fxMap.set(f, e); }
      this._updFx(f, e);
    }
    for (const [f, e] of this._fxMap){
      if (!seen.has(f)){ for (const o of e.objs) this.scene.remove(o); this._fxMap.delete(f); }
    }
  },
  _mkFx(f){
    const objs = [];
    if (f.type === "tracer"){
      const h1 = this.heightAt(f.x1, f.y1) + 12, h2 = this.heightAt(f.x2, f.y2) + 10;
      const geo = new THREE.BufferGeometry().setFromPoints([
        new THREE.Vector3(f.x1, h1, f.y1), new THREE.Vector3(f.x2, h2, f.y2)]);
      const line = new THREE.Line(geo, new THREE.LineBasicMaterial({
        color: f.hit ? 0xffe178 : 0xd8d8d8, transparent: true, blending: THREE.AdditiveBlending }));
      objs.push(line);
      const muzzle = new THREE.PointLight(0xffcf70, 2.2, 90);   // 槍口閃光
      muzzle.position.set(f.x1, h1 + 2, f.y1); objs.push(muzzle);
      this._tryShootAnim(f.x1, f.y1);
    } else { // boom
      const hb = this.heightAt(f.x, f.y) + 6;
      const ball = new THREE.Mesh(new THREE.SphereGeometry(1, 10, 8),
        new THREE.MeshBasicMaterial({ color: 0xff8a3a, transparent: true, blending: THREE.AdditiveBlending }));
      ball.position.set(f.x, hb, f.y); objs.push(ball);
      const glow = new THREE.PointLight(0xff9a40, 4, 220);      // 爆炸打亮周遭
      glow.position.set(f.x, hb + 8, f.y); objs.push(glow);
    }
    for (const o of objs) this.scene.add(o);
    return { objs };
  },
  _updFx(f, e){
    if (f.type === "tracer"){
      const k = 1 - f.t / 0.25;
      e.objs[0].material.opacity = Math.max(0, k);
      e.objs[1].intensity = f.t < 0.08 ? 2.2 * (1 - f.t / 0.08) : 0;
    } else {
      const k = f.t / 0.5, r = (f.r || 20) * (0.35 + k * 1.1);
      e.objs[0].scale.setScalar(r);
      e.objs[0].material.opacity = Math.max(0, 1 - k);
      e.objs[1].intensity = 4 * Math.max(0, 1 - k);
    }
  },
  /* 開火者若有 shoot 動畫片段 → 播一次再回原動作 */
  _tryShootAnim(x, y){
    for (const id in this._mixers){
      const g = this._units[id];
      if (!g || Math.hypot(g.position.x - x, g.position.z - y) > 25) continue;
      const mx = this._mixers[id];
      if (!mx.actions.shoot){
        const m = this._models.soldier;
        const clip = m && m.anims.find(a => /shoot|fire|attack|gun/i.test(a.name));
        if (!clip) return;
        mx.actions.shoot = mx.mixer.clipAction(clip);
        mx.actions.shoot.setLoop(THREE.LoopOnce); mx.actions.shoot.clampWhenFinished = false;
        mx.mixer.addEventListener("finished", () => { if (mx.cur !== "shoot") return; mx.actions.shoot.stop(); mx.actions.idle.play(); mx.cur = "idle"; });
      }
      mx.actions[mx.cur].stop(); mx.actions.shoot.reset().play(); mx.cur = "shoot";
      return;
    }
  },

  /* ---------- 每幀渲染（相機同步自 Camera3D） ---------- */
  render(G){
    if (!this.ok) return;
    if (this._mapRef !== G.map){ this.buildMap(G); this._mapRef = G.map; }
    this.syncUnits(G);
    this.syncFx(G);
    // 動畫推進
    const now = performance.now(), dt = Math.min(0.05, (now - (this._at || now)) / 1000); this._at = now;
    for (const id in this._mixers) this._mixers[id].mixer.update(dt);
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
      const alt = u.domain === "air" ? 52 : (u.domain === "sea" ? 0 : this.heightAt(u.x, u.y));
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
    for (const f of G.fx){ if (f.type === "tracer" || f.type === "boom") continue; Render3D._fx(ctx, cam, f); } // 曳光/爆炸已 3D 化
    if (cam.mode === "follow") Render3D._crosshair(ctx, cam.W, cam.H, cam.horizonY());
  }
};
