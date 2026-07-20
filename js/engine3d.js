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
  failureReason: null,
  _units: {},          // unit.id -> THREE.Group
  _mapRef: null,
  _videoCache: {},     // class-state -> one shared HTMLVideoElement + VideoTexture
  _atlasCache: {},     // atlas path -> shared decoded image texture
  _videoGestureBound: false,

  init(){
    if (typeof THREE === "undefined") { this.failureReason="Three.js 未載入"; return; }
    try {
      const stage = document.getElementById("stage");
      const cv = document.createElement("canvas");
      cv.id = "game3d"; cv.width = 960; cv.height = 600;
      cv.style.cssText = "position:absolute;left:0;top:0;width:100%;height:100%;z-index:0;border:2px solid #3a4232;box-sizing:border-box;";
      stage.insertBefore(cv, stage.firstChild);
      const g2 = document.getElementById("game");
      g2.style.position = "relative"; g2.style.zIndex = "1";
      g2.style.background = "transparent"; g2.style.border = "2px solid transparent";

      this._lowPower = !!(window.matchMedia&&window.matchMedia("(pointer: coarse)").matches);
      this.renderer = new THREE.WebGLRenderer({ canvas: cv, antialias: true });
      this.renderer.setSize(960, 600, false);
      this.renderer.shadowMap.enabled = !this._lowPower;
      this.renderer.shadowMap.type = THREE.PCFShadowMap;   // Soft 在內顯上貴 3~4 倍，PCF 視覺差異小
      this.renderer.outputEncoding = THREE.sRGBEncoding;
      this.renderer.toneMapping = THREE.ACESFilmicToneMapping;   // 電影級色調映射
      this.renderer.toneMappingExposure = 1.12;

      this.scene = new THREE.Scene();
      this.scene.background = new THREE.Color(0x8fb8dc);
      this.scene.fog = new THREE.Fog(0xd9e3ea, 1150, 3400);   // 拉遠霧距：俯瞰不洗白、遠景仍朦朧

      this.camera = new THREE.PerspectiveCamera(65, 960 / 600, 2, 6000);

      const hemi = new THREE.HemisphereLight(0xd8ecff, 0x54604a, 0.55);
      this.scene.add(hemi);
      const sun = new THREE.DirectionalLight(0xfff1d6, 0.95);
      sun.castShadow = !this._lowPower;
      sun.shadow.mapSize.set(1024, 1024);
      this._sun = sun;
      this.scene.add(sun); this.scene.add(sun.target);

      // 環境光照（IBL）：程序化天空球 → PMREM。PBR 材質（Tripo 角色）沒有它會又平又悶。
      try {
        const pmrem = new THREE.PMREMGenerator(this.renderer);
        const envScene = new THREE.Scene();
        const cv = document.createElement("canvas"); cv.width = 2; cv.height = 64;
        const g = cv.getContext("2d"), gr = g.createLinearGradient(0, 0, 0, 64);
        gr.addColorStop(0, "#9ec6e6"); gr.addColorStop(0.6, "#e8ddc2"); gr.addColorStop(1, "#6d6a58");
        g.fillStyle = gr; g.fillRect(0, 0, 2, 64);
        const grad = new THREE.CanvasTexture(cv);
        const dome = new THREE.Mesh(new THREE.SphereGeometry(10, 16, 12),
          new THREE.MeshBasicMaterial({ map: grad, side: THREE.BackSide }));
        envScene.add(dome);
        this.scene.environment = pmrem.fromScene(envScene, 0.08).texture;
        pmrem.dispose();
      } catch (e) { /* IBL 失敗不影響遊戲 */ }

      this.ok = true;
      this.loadArtSheets();
      this.loadModels();
      // 步兵預設使用 MakeHuman 真人比例骨架模型；?primitiveCharacters=1 僅供低階備援比較。
    } catch (e){
      this.failureReason=e&&e.message?e.message:String(e);
      console.error("Engine3D 初始化失敗，正式流程已阻擋：", e);
      this.ok = false;
    }
  },

  /* ---------- 寫實召喚圖層（GDD/06：部署卡與戰場共用同一格位） ---------- */
  _artDefs: {
    land: {
      url:"assets/art-direction/land-roster-concept-v1.png", cols:5, rows:2,
      classes:["rifleman","assault","mg","mortar","sniper","at","engineer","specops","sam","tank"]
    },
    seaair: {
      url:"assets/art-direction/sea-air-roster-concept-v1.png", cols:4, rows:2,
      classes:["destroyer","missileboat","lst","submarine","fighter","attacker","gunship",null]
    }
  },
  _artWorldSize:{
    rifleman:{h:20},assault:{h:21},mg:{h:20},mortar:{h:21},sniper:{h:20},at:{h:21},engineer:{h:20},specops:{h:20},sam:{h:22},
    tank:{w:34},destroyer:{w:46},missileboat:{w:32},lst:{w:42},submarine:{w:34},fighter:{w:34},attacker:{w:36},gunship:{w:30}
  },
  _artImages:{}, _artTextures:{}, _artFailed:{}, _artAtlasState:{},
  loadArtSheets(){
    for (const cls of Object.keys(CLASS_BASE)) this._loadPreparedArt(cls);
  },
  _loadArtSheet(key){
    if(!this._artDefs[key]||this._artAtlasState[key])return;
    this._artAtlasState[key]="loading";
    const img=new Image();img.decoding="async";
    img.onload=()=>{this._artAtlasState[key]="ready";this._artImages[key]=img;
      for(const cls of this._artDefs[key].classes)if(cls&&!this._artTextures[cls])delete this._artFailed[cls];
      this._queueArtRebuild();};
    img.onerror=()=>{this._artAtlasState[key]="failed";for(const cls of this._artDefs[key].classes)if(cls)this._artFailed[cls]=true;};
    img.src=this._artDefs[key].url;
  },
  _loadAtlasFor(cls){const found=this._artDefFor(cls);if(found)this._loadArtSheet(found.key);},
  _validateArtImage(img){
    try{
      const w=img.naturalWidth||img.width,h=img.naturalHeight||img.height;
      if(!Number.isFinite(w)||!Number.isFinite(h)||w<2||h<2)return null;
      const cv=document.createElement("canvas");cv.width=w;cv.height=h;
      const ctx=cv.getContext("2d",{willReadFrequently:true});if(!ctx)return null;
      ctx.drawImage(img,0,0,w,h);
      const px=ctx.getImageData(0,0,w,h).data,total=w*h;let visible=0;
      for(let i=3;i<px.length;i+=4)if(px[i]>=24)visible++;
      if(visible<Math.max(16,Math.floor(total*0.005)))return null;
      return {canvas:cv,visible,total,ratio:visible/total};
    }catch(_e){return null;}
  },
  _loadPreparedArt(cls){
    const img=new Image();img.decoding="async";
    const embedded=(typeof UNIT_ART_DATA!=="undefined"&&UNIT_ART_DATA[cls])||null;
    const manifestOk=!!(embedded&&typeof UNIT_ART_SHA256!=="undefined"&&/^[a-f0-9]{64}$/.test(UNIT_ART_SHA256[cls]||""));
    img.onload=()=>{
      const checked=this._validateArtImage(img);
      if(!checked){console.warn(`寫實兵種圖片驗證失敗，改讀圖集備援：${cls}`);this._loadAtlasFor(cls);return;}
      const old=this._artTextures[cls];if(old && !old.prepared && old.tex) old.tex.dispose();
      const tex=new THREE.CanvasTexture(checked.canvas);tex.encoding=THREE.sRGBEncoding;
      tex.minFilter=THREE.LinearFilter;tex.magFilter=THREE.LinearFilter;
      let gpuWarm=false;try{if(this.renderer&&this.renderer.initTexture){this.renderer.initTexture(tex);gpuWarm=true;}}
      catch(e){tex.dispose();console.warn(`寫實兵種貼圖預載失敗，改讀圖集備援：${cls}`,e);this._loadAtlasFor(cls);return;}
      this._artTextures[cls]={tex,aspect:checked.canvas.width/checked.canvas.height,image:img,canvas:checked.canvas,
        prepared:true,gpuSafe:true,gpuWarm,validated:true,opaqueRatio:checked.ratio,source:manifestOk?"embedded":"asset"};
      delete this._artFailed[cls];this._queueArtRebuild();
    };
    img.onerror=()=>this._loadAtlasFor(cls); // 缺檔時才 lazy-load 原始圖集。
    img.src=(manifestOk?embedded:null)||`assets/units-realistic/${cls}.png`;
  },
  _queueArtRebuild(){
    if(this._artRebuildQueued)return;this._artRebuildQueued=true;
    requestAnimationFrame(()=>{
      this._artRebuildQueued=false;
      if(this.scene){for(const id in this._units)this.scene.remove(this._units[id]);this._units={};this._mixers={};}
    });
  },
  _artDefFor(cls){
    for (const key in this._artDefs){
      const d=this._artDefs[key], index=d.classes.indexOf(cls);
      if (index>=0) return {key,d,index};
    }
    return null;
  },
  /* 從格位邊界做連通背景移除：只吞平滑中性背景，保留武器／天線／桅杆等內部細節。 */
  _buildArtTexture(cls){
    if (this._artTextures[cls] || this._artFailed[cls]) return this._artTextures[cls]||null;
    const found=this._artDefFor(cls);
    if (!found || !this._artImages[found.key]) return null;
    try {
      const img=this._artImages[found.key], d=found.d;
      const col=found.index%d.cols, row=Math.floor(found.index/d.cols);
      const cw=img.width/d.cols, ch=img.height/d.rows, inset=3;
      const w=Math.max(8,Math.round(cw-inset*2)), h=Math.max(8,Math.round(ch-inset*2));
      const cv=document.createElement("canvas"); cv.width=w; cv.height=h;
      const ctx=cv.getContext("2d",{willReadFrequently:true});
      ctx.drawImage(img,col*cw+inset,row*ch+inset,cw-inset*2,ch-inset*2,0,0,w,h);
      const id=ctx.getImageData(0,0,w,h), px=id.data, total=w*h;
      const left=new Float32Array(h*3), right=new Float32Array(h*3), edge=Math.max(4,Math.round(w*0.025));
      for (let y=0;y<h;y++){
        let lr=0,lg=0,lb=0,rr=0,rg=0,rb=0;
        for (let x=0;x<edge;x++){
          let i=(y*w+x)*4; lr+=px[i];lg+=px[i+1];lb+=px[i+2];
          i=(y*w+(w-1-x))*4; rr+=px[i];rg+=px[i+1];rb+=px[i+2];
        }
        const j=y*3; left[j]=lr/edge;left[j+1]=lg/edge;left[j+2]=lb/edge;
        right[j]=rr/edge;right[j+1]=rg/edge;right[j+2]=rb/edge;
      }
      const bg=new Uint8Array(total), q=new Int32Array(total); let qh=0,qt=0;
      const seed=i=>{ if (!bg[i]){ bg[i]=1;q[qt++]=i; } };
      for (let x=0;x<w;x++){ seed(x);seed((h-1)*w+x); }
      for (let y=1;y<h-1;y++){ seed(y*w);seed(y*w+w-1); }
      const accept=(from,to)=>{
        const a=from*4,b=to*4, x=to%w,y=(to/w)|0,t=x/Math.max(1,w-1),j=y*3;
        const br=left[j]*(1-t)+right[j]*t,bg0=left[j+1]*(1-t)+right[j+1]*t,bb=left[j+2]*(1-t)+right[j+2]*t;
        const local=Math.max(Math.abs(px[b]-px[a]),Math.abs(px[b+1]-px[a+1]),Math.abs(px[b+2]-px[a+2]));
        const dr=px[b]-br,dg=px[b+1]-bg0,db=px[b+2]-bb;
        return local<=9 && (dr*dr+dg*dg+db*db)<=42*42;
      };
      while(qh<qt){
        const i=q[qh++],x=i%w,y=(i/w)|0;
        if(x>0){const n=i-1;if(!bg[n]&&accept(i,n)){bg[n]=1;q[qt++]=n;}}
        if(x<w-1){const n=i+1;if(!bg[n]&&accept(i,n)){bg[n]=1;q[qt++]=n;}}
        if(y>0){const n=i-w;if(!bg[n]&&accept(i,n)){bg[n]=1;q[qt++]=n;}}
        if(y<h-1){const n=i+w;if(!bg[n]&&accept(i,n)){bg[n]=1;q[qt++]=n;}}
      }
      let minX=w,minY=h,maxX=-1,maxY=-1;
      for(let y=0;y<h;y++) for(let x=0;x<w;x++){
        const i=y*w+x,p=i*4;
        if(bg[i]){px[p+3]=0;continue;}
        let edgeN=0;
        for(let yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1);yy++) for(let xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++) if(bg[yy*w+xx]) edgeN++;
        px[p+3]=edgeN?Math.max(96,255-edgeN*20):255;
        if(px[p+3]>40){minX=Math.min(minX,x);minY=Math.min(minY,y);maxX=Math.max(maxX,x);maxY=Math.max(maxY,y);}
      }
      if(maxX<minX || maxY<minY) throw new Error("empty art mask");
      ctx.putImageData(id,0,0);
      const pad=5,x0=Math.max(0,minX-pad),y0=Math.max(0,minY-pad),x1=Math.min(w-1,maxX+pad),y1=Math.min(h-1,maxY+pad);
      const out=document.createElement("canvas");out.width=x1-x0+1;out.height=y1-y0+1;
      out.getContext("2d").drawImage(cv,x0,y0,out.width,out.height,0,0,out.width,out.height);
      const tex=new THREE.CanvasTexture(out);tex.encoding=THREE.sRGBEncoding;tex.minFilter=THREE.LinearFilter;tex.magFilter=THREE.LinearFilter;
      const result={tex,aspect:out.width/out.height,canvas:out,gpuSafe:true,validated:true,source:"atlas-canvas"};
      this._artTextures[cls]=result; return result;
    } catch(_e){ this._artFailed[cls]=true; return null; }
  },
  _artSprite(u){
    const a=this._buildArtTexture(u.cls); if(!a) return null;
    if(a.gpuSafe===false || a.validated!==true || !a.tex || !Number.isFinite(a.aspect) || a.aspect<=0) return null;
    try{if(this.renderer&&this.renderer.initTexture)this.renderer.initTexture(a.tex);}
    catch(e){console.warn(`寫實兵種貼圖無法上傳 WebGL，保留 3D 備援：${u.cls}`,e);return null;}
    const size=this._artWorldSize[u.cls]||{h:20};
    const w=size.w||size.h*a.aspect,h=size.h||size.w/a.aspect;
    let mat,sp;
    try{
      mat=new THREE.MeshBasicMaterial({map:a.tex,color:0xffffff,transparent:true,alphaTest:0.06,
        depthWrite:true,fog:true,side:THREE.DoubleSide});
      const geo=new THREE.PlaneGeometry(1,1);geo.translate(0,.5,0);
      sp=new THREE.Mesh(geo,mat);sp.name=`generated-still-fallback-${u.cls}`;sp.scale.set(w,h,1);
      sp.userData.bottomAnchored=true;
      sp.frustumCulled=false;sp.castShadow=false;
    }catch(e){console.warn(`寫實兵種材質建立失敗，保留 3D 備援：${u.cls}`,e);return null;}
    const baseY=0;sp.position.y=baseY;sp.userData.baseY=baseY;sp.renderOrder=2;
    return {sprite:sp,w,h,source:a.source||"unknown",validated:true};
  },

  _videoSource(cls,state){
    const asset=typeof UNIT_VIDEO_ASSETS!=="undefined"&&UNIT_VIDEO_ASSETS[cls]&&UNIT_VIDEO_ASSETS[cls][state]||null;
    return typeof asset==="string"?asset:null;
  },
  _atlasAsset(cls,state){
    const asset=typeof UNIT_VIDEO_ASSETS!=="undefined"&&UNIT_VIDEO_ASSETS[cls]&&UNIT_VIDEO_ASSETS[cls][state]||null;
    return asset&&asset.atlas?asset:null;
  },
  _atlasEntry(asset){
    if(!asset)return null;
    if(this._atlasCache[asset.atlas])return this._atlasCache[asset.atlas];
    const entry={asset,texture:null,ready:false,failed:false};this._atlasCache[asset.atlas]=entry;
    new THREE.TextureLoader().load(asset.atlas,tex=>{
      tex.encoding=THREE.sRGBEncoding;tex.minFilter=THREE.LinearFilter;tex.magFilter=THREE.LinearFilter;
      tex.generateMipmaps=false;entry.texture=tex;entry.ready=true;
    },undefined,()=>{entry.failed=true;console.warn(`單位動作圖集載入失敗，保留原圖：${asset.atlas}`);});
    return entry;
  },
  _atlasSprite(u,state,entry){
    if(!entry||!entry.ready||!entry.texture)return null;
    const asset=entry.asset,tex=entry.texture.clone();tex.needsUpdate=true;
    tex.repeat.set(1/asset.cols,1/asset.rows);tex.offset.set(0,1-1/asset.rows);
    const aspect=(entry.texture.image.width/asset.cols)/(entry.texture.image.height/asset.rows);
    const size=this._artWorldSize[u.cls]||{h:20},w=size.w||size.h*aspect,h=size.h||size.w/aspect;
    const geo=new THREE.PlaneGeometry(1,1);geo.translate(0,.5,0);
    const sp=new THREE.Mesh(geo,new THREE.MeshBasicMaterial({map:tex,color:0xffffff,transparent:true,
      alphaTest:.035,depthWrite:true,fog:true,side:THREE.DoubleSide}));
    sp.name=`generated-atlas-${u.cls}-${state}`;sp.scale.set(w,h,1);sp.renderOrder=2;sp.frustumCulled=false;sp.visible=false;
    sp.userData.baseY=0;sp.userData.bottomAnchored=true;sp.userData.artSize={w,h};sp.userData.atlasAsset=asset;
    return sp;
  },
  _resumeUnitVideos(){
    for(const key in this._videoCache){const entry=this._videoCache[key];if(entry&&entry.ready&&entry.video.paused)this._playUnitVideo(entry);}
  },
  _playUnitVideo(entry){
    if(!entry||entry.failed||!entry.ready)return;
    try{
      const result=entry.video.play();
      if(result&&typeof result.then==="function")result.then(()=>{entry.playing=true;entry.blocked=false;}).catch(()=>{entry.blocked=true;});
      else entry.playing=!entry.video.paused;
    }catch(_e){entry.blocked=true;}
  },
  _videoEntry(cls,state){
    const src=this._videoSource(cls,state);if(!src)return null;
    const key=`${cls}-${state}`;if(this._videoCache[key])return this._videoCache[key];
    const video=document.createElement("video");
    video.muted=true;video.defaultMuted=true;video.playsInline=true;video.preload="auto";
    video.loop=state==="idle"||state==="move";video.disablePictureInPicture=true;video.src=src;
    const entry={key,src,video,texture:null,ready:false,playing:false,blocked:false,failed:false,
      hasAlpha:/\.webm(?:$|[?#])/i.test(src)};
    this._videoCache[key]=entry;
    video.addEventListener("loadeddata",()=>{
      entry.ready=video.videoWidth>0&&video.videoHeight>0;
      if(entry.ready&&!entry.texture){
        const tex=new THREE.VideoTexture(video);tex.encoding=THREE.sRGBEncoding;
        tex.minFilter=THREE.LinearFilter;tex.magFilter=THREE.LinearFilter;tex.generateMipmaps=false;
        entry.texture=tex;
      }
      this._playUnitVideo(entry);
    });
    video.addEventListener("playing",()=>{entry.playing=true;entry.blocked=false;});
    video.addEventListener("pause",()=>{entry.playing=false;});
    video.addEventListener("waiting",()=>{entry.playing=false;});
    video.addEventListener("stalled",()=>{entry.playing=false;});
    video.addEventListener("ended",()=>{entry.playing=false;});
    video.addEventListener("error",()=>{entry.failed=true;entry.playing=false;console.warn(`單位影片載入失敗，保留原圖：${src}`);});
    video.load();
    if(!this._videoGestureBound){
      this._videoGestureBound=true;
      const resume=()=>this._resumeUnitVideos();
      window.addEventListener("pointerdown",resume,{passive:true});
      window.addEventListener("keydown",resume,{passive:true});
    }
    return entry;
  },
  _videoMaterial(texture,hasAlpha){
    const mat=new THREE.MeshBasicMaterial({map:texture,color:0xffffff,transparent:true,alphaTest:.035,
      depthWrite:true,fog:true,side:THREE.DoubleSide});
    if(hasAlpha)return mat;
    mat.onBeforeCompile=shader=>{
      shader.fragmentShader=shader.fragmentShader.replace("#include <map_fragment>",`
#ifdef USE_MAP
  vec4 sampledDiffuseColor = texture2D( map, vUv );
  float greenLead = sampledDiffuseColor.g - max(sampledDiffuseColor.r, sampledDiffuseColor.b);
  float greenKey = smoothstep(0.10, 0.30, greenLead) * smoothstep(0.38, 0.72, sampledDiffuseColor.g);
  sampledDiffuseColor.a *= 1.0 - greenKey;
#ifdef DECODE_VIDEO_TEXTURE
  sampledDiffuseColor = vec4( mix(
    pow( sampledDiffuseColor.rgb * 0.9478672986 + vec3( 0.0521327014 ), vec3( 2.4 ) ),
    sampledDiffuseColor.rgb * 0.0773993808,
    vec3( lessThanEqual( sampledDiffuseColor.rgb, vec3( 0.04045 ) ) )
  ), sampledDiffuseColor.w );
#endif
  diffuseColor *= sampledDiffuseColor;
#endif`);
    };
    mat.customProgramCacheKey=()=>"unit-video-chroma-v3";
    return mat;
  },
  _videoSprite(u,state,entry){
    if(!entry||!entry.texture||!entry.ready)return null;
    const aspect=entry.video.videoWidth/entry.video.videoHeight;if(!Number.isFinite(aspect)||aspect<=0)return null;
    const size=this._artWorldSize[u.cls]||{h:20},w=size.w||size.h*aspect,h=size.h||size.w/aspect;
    const geo=new THREE.PlaneGeometry(1,1);geo.translate(0,.5,0);
    const sp=new THREE.Mesh(geo,this._videoMaterial(entry.texture,entry.hasAlpha));
    sp.name=`generated-video-${u.cls}-${state}`;sp.scale.set(w,h,1);sp.position.y=0;sp.renderOrder=2;
    sp.frustumCulled=false;sp.castShadow=false;sp.visible=false;
    sp.userData.baseY=0;sp.userData.bottomAnchored=true;sp.userData.videoEntry=entry;sp.userData.artSize={w,h};
    return sp;
  },
  _syncUnitVideoArt(g,u,state,now){
    const fallback=g.userData.artFallback;if(!fallback)return;
    const atlasAsset=this._atlasAsset(u.cls,state),atlasEntry=this._atlasEntry(atlasAsset);
    if(atlasEntry&&atlasEntry.ready&&!atlasEntry.failed){
      let atlasSprite=g.userData.videoSprites&&g.userData.videoSprites[state];
      if(!atlasSprite){atlasSprite=this._atlasSprite(u,state,atlasEntry);if(atlasSprite){g.userData.videoSprites[state]=atlasSprite;g.add(atlasSprite);}}
      if(atlasSprite){
        const a=atlasSprite.userData.atlasAsset;
        if(g.userData.atlasAnimState!==state){
          g.userData.atlasAnimState=state;
          g.userData.atlasAnimStartedAt=now;
        }
        const elapsed=Math.max(0,now-(g.userData.atlasAnimStartedAt||now));
        const frame=Math.floor(elapsed*.001*a.fps)%a.frames;
        atlasSprite.material.map.offset.set((frame%a.cols)/a.cols,1-(Math.floor(frame/a.cols)+1)/a.rows);
        const current=g.userData.artSprite;if(current!==atlasSprite){if(current)current.visible=false;atlasSprite.visible=true;g.userData.artSprite=atlasSprite;}
        g.userData.artSize=atlasSprite.userData.artSize;g.userData.artSource=`atlas:${a.atlas}`;return;
      }
    }
    const entry=this._videoEntry(u.cls,state);let next=fallback,size=g.userData.artFallbackSize,source=g.userData.artFallbackSource;
    if(entry&&entry.ready&&entry.playing&&!entry.failed){
      let videoSprite=g.userData.videoSprites&&g.userData.videoSprites[state];
      if(!videoSprite){
        videoSprite=this._videoSprite(u,state,entry);
        if(videoSprite){g.userData.videoSprites[state]=videoSprite;g.add(videoSprite);}
      }
      if(videoSprite){next=videoSprite;size=videoSprite.userData.artSize;source=`video:${entry.src}`;}
    }
    const current=g.userData.artSprite;
    if(current!==next){if(current)current.visible=false;next.visible=true;g.userData.artSprite=next;}
    g.userData.artSize=size;g.userData.artSource=source;
  },

  /* ---------- GLB 模型：非同步載入，完成後重建單位 ----------
   * 自動：量包圍盒→縮放到遊戲尺寸→貼地→軸向(長邊=車頭方向)；rotY 為「模型頭朝向修正」。
   * SkinnedMesh 必須用 SkeletonUtils.clone()，讓各單位擁有獨立骨架與 mixer。 */
  _models: {},
  _modelState: {},
  loadModels(){
    if (typeof THREE.GLTFLoader === "undefined") return;
    const defs = this._defs = {};
    for (const key in MODEL_ASSETS){
      const a=MODEL_ASSETS[key];
      if(!a.url){this._modelState[key]="missing";continue;}
      defs[key]={url:a.url,alt:a.alt,b64:a.b64,b64key:a.b64key,h:a.h,len:a.len,rotY:a.rotY,source:a.source,status:a.status,lazy:!!a.lazy,selfGear:!!a.selfGear};
    }
    const byUrl = {};                                     // 同 URL 只下載/解析一次
    for (const key in defs){ if (!defs[key].lazy) (byUrl[defs[key].url] = byUrl[defs[key].url] || []).push(key); }
    this._loadGroups(byUrl);
  },
  /* 按需載入：兵種首次出現才抓模型（_mkUnit 呼叫），載完自動重建單位 */
  _ensureModel(key){
    const d = this._defs && this._defs[key];
    if (!d || this._modelState[key]) return;
    const byUrl = {}; byUrl[d.url] = [key];
    this._loadGroups(byUrl);
  },
  /* 模型下載進度提示（右上小條；ratio=null 表示該檔完成/失敗即移除） */
  _loading: {}, _loadRetries: {},
  _loadError(url, error){
    let el = document.getElementById("modelLoadHint");
    const stage = document.getElementById("stage"); if (!stage) return;
    if (!el){ el = document.createElement("div"); el.id = "modelLoadHint"; stage.appendChild(el); }
    const msg = (error && (error.message || error.type || String(error))) || "未知錯誤";
    el.textContent = `⚠ 模型載入失敗：${url.split("/").pop()}（${String(msg).slice(0,120)}）`;
    el.style.display = "block"; el.style.color = "#ff9a7a";
    setTimeout(() => { if (el.textContent.startsWith("⚠")) el.style.display = "none"; }, 30000);
  },
  _loadHint(url, ratio){
    if (ratio === null) delete this._loading[url]; else this._loading[url] = ratio;
    let el = document.getElementById("modelLoadHint");
    const urls = Object.keys(this._loading);
    if (!urls.length){ if (el) el.style.display = "none"; return; }
    if (!el){
      el = document.createElement("div"); el.id = "modelLoadHint";
      const stage = document.getElementById("stage"); if (!stage) return;
      stage.appendChild(el);
    }
    const pct = Math.round(100 * urls.reduce((s,u)=>s+this._loading[u],0) / urls.length);
    el.textContent = `⟳ 高精度模型載入中 ${pct}%`;
    el.style.display = "block";
  },
  _loadGroups(byUrl){
    if (typeof THREE.GLTFLoader === "undefined") return;
    const loader = new THREE.GLTFLoader();
    const defs = this._defs;
    for (const url in byUrl){
      const keys = byUrl[url];
      for (const key of keys) this._modelState[key] = "loading";
      const onLoaded = g => {
        const s = g.scene;
        s.traverse(o => { if (o.isMesh){ o.castShadow = true; } });
        const d0 = defs[keys[0]];                                       // 同 URL 群組共用縮放定位
        const box = new THREE.Box3().setFromObject(s), sz = box.getSize(new THREE.Vector3());
        if (d0.len && sz.z > sz.x) s.rotation.y = Math.PI / 2;          // 長邊轉到 +x（車頭軸）
        const box1 = new THREE.Box3().setFromObject(s), sz1 = box1.getSize(new THREE.Vector3());
        const k = d0.len ? d0.len / Math.max(sz1.x, 0.001) : d0.h / Math.max(sz1.y, 0.001);
        s.scale.setScalar(k);
        const box2 = new THREE.Box3().setFromObject(s);
        s.position.y -= box2.min.y;                                     // 貼地
        s.position.x -= (box2.min.x + box2.max.x) / 2;                  // 置中
        s.position.z -= (box2.min.z + box2.max.z) / 2;
        for (const key of keys){
          const d = defs[key];
          this._models[key] = { scene: s, rotY: d.rotY, anims: g.animations || [],
            source:d.source, status:d.status, url:d.url };
          this._modelState[key] = "ready";
        }
        for (const id in this._units){ this.scene.remove(this._units[id]); } // 重建套用模型
        this._units = {}; this._mixers = {};
      };
      const onFailed = error => {
        console.warn("3D model load failed:", keys.join("/"), error || "unknown error");
        this._loadHint(url, null);
        const n = this._loadRetries[url] || 0;
        if (n < 2){                                                    // 自動重試 2 次（網路抖動）
          this._loadRetries[url] = n + 1;                              // 注意：重試期間維持 loading 狀態，防 _ensureModel 併發開新鏈
          setTimeout(() => { const again = {}; again[url] = keys; this._loadGroups(again); }, 1200 * (n + 1));
          return;
        }
        const altUrl = defs[keys[0]] && defs[keys[0]].alt;             // 換備援副檔名再試（防毒/過濾器攔 .glb 對策）
        if (altUrl && altUrl !== url && !this._loadRetries[altUrl]){
          this._loadRetries[altUrl] = 1;
          const again = {}; again[altUrl] = keys;
          setTimeout(() => this._loadGroups(again), 500);
          return;
        }
        // 最終備援：base64 封裝在 .js 內（腳本載入不會被下載過濾器攔截）
        const d1 = defs[keys[0]];
        if (d1 && d1.b64 && !this._b64Tried){
          this._b64Tried = true;
          this._loadViaB64(d1, keys, url, onLoaded, loader);
          return;
        }
        this._loadError(url, error);                                   // 最終失敗：畫面明示原因
        for (const key of keys) this._modelState[key] = "failed";      // 走幾何 fallback
      };
      const d0 = defs[keys[0]];
      // 此環境曾靠 b64 成功（防毒攔二進位下載）→ 直達 b64，不再浪費重試時間
      let preferB64 = false;
      try { preferB64 = localStorage.getItem("bf_prefer_b64") === "1"; } catch (e) {}
      if (preferB64 && d0 && d0.b64 && url === d0.url){
        this._loadViaB64(d0, keys, url, onLoaded, loader);
        continue;
      }
      const onProgress = ev => { if (ev && ev.total) this._loadHint(url, ev.loaded / ev.total); };
      const vurl = url + (typeof BUILD !== "undefined" ? (url.includes("?") ? "&" : "?") + BUILD : "");
      loader.load(vurl, g => { this._loadHint(url, null); onLoaded(g); }, onProgress, onFailed);
    }
  },
  /* base64-in-js 通道：注入腳本→解碼→GLTFLoader.parse；成功後記住偏好（localStorage） */
  _loadViaB64(d1, keys, url, onLoaded, loader){
    this._loadHint(url, 0.05);
    const tag = document.createElement("script");
    tag.src = d1.b64 + (typeof BUILD !== "undefined" ? "?" + BUILD : "");
    tag.onload = () => {
      try {
        const b64 = window.MODEL_B64 && window.MODEL_B64[d1.b64key];
        if (!b64) throw new Error("b64 資料缺失");
        const bin = Uint8Array.from(atob(b64), ch => ch.charCodeAt(0)).buffer;
        loader.parse(bin, "", g => {
          this._loadHint(url, null);
          try { localStorage.setItem("bf_prefer_b64", "1"); } catch (e) {}
          onLoaded(g);
        }, e2 => { this._loadHint(url, null); this._loadError(d1.b64, e2); for (const key of keys) this._modelState[key] = "failed"; });
      } catch (e3){ this._loadHint(url, null); this._loadError(d1.b64, e3); for (const key of keys) this._modelState[key] = "failed"; }
    };
    tag.onerror = () => { this._loadHint(url, null); this._loadError(d1.b64, new Error("備援腳本載入失敗")); for (const key of keys) this._modelState[key] = "failed"; };
    document.head.appendChild(tag);
  },

  /* 動畫交叉淡入淡出（dept-12：硬切→融合，消姿勢跳變）
   * 效能：淡出完成後必須 stop()，否則權重 0 的動作持續累積參與每幀取樣（卡頓元凶） */
  _xfade(mx, want, dur){
    const prev = mx.actions[mx.cur], nxt = mx.actions[want];
    if (!nxt){ return false; }
    if (prev === nxt && mx.cur === want) return true;
    nxt.reset(); nxt.paused = false;
    const d = dur || 0.22;
    if (prev && prev !== nxt && prev.isRunning()){
      nxt.play(); prev.crossFadeTo(nxt, d, false);
      setTimeout(() => { if (mx.actions[mx.cur] !== prev && prev.getEffectiveWeight() < 0.02) prev.stop(); }, d * 1000 + 80);
    } else {
      nxt.fadeIn(d).play();
    }
    mx.cur = want;
    return true;
  },

  /* 複製模型（骨架安全 clone）＋國家染色＋動畫 mixer（idle/walk） */
  _mixers: {},
  _cloneModel(key, u, preview){
    const m = this._models[key];
    if (!m) return null;
    const c = (typeof THREE.SkeletonUtils !== "undefined") ? THREE.SkeletonUtils.clone(m.scene) : m.scene.clone(true);
    const tint = new THREE.Color(NATIONS[u.nationId].uniformColor);
    const characterBones = {}, namedNodes = {};
    c.traverse(o => {
      if(o.name)namedNodes[o.name]=o;
      if (o.isBone) characterBones[o.name] = o;
      if (o.isMesh){ o.material = o.material.clone();
        const materialName=(o.material.name||"").toLowerCase();
        if (/uniform|combat_pants|olive_gear|plate_|pouches/.test(materialName)&&o.material.color) o.material.color.lerp(tint, 0.24);
        o.castShadow = !o.isSkinnedMesh;   // 骨骼網格不投動態陰影（有貼地假陰影，省一半骨骼計算）
        o.frustumCulled = false;
        if (u.cls === "specops" && /uniform|combat_pants|olive_gear|plate_|pouches/.test(materialName) && o.material.color) o.material.color.multiplyScalar(0.5); }   // 特種兵低視度黑
    });
    if (this._defs && this._defs[key] && this._defs[key].selfGear)
      c.traverse(o => { if (o.isMesh) o.userData.noToon = true; });   // 專屬模型保留原貼圖光影（貼圖已含手繪陰影，硬色階會糊細節）
    if (m.anims.length){
      const mixer = new THREE.AnimationMixer(c);
      const pick = re => m.anims.find(a => re.test(a.name));
      const idle = pick(/(^|\|)idle(_gun)?$/i)||pick(/idle/i);
      const walk = pick(/(^|\|)walk$/i)||pick(/walk/i);
      const run = pick(/(^|\|)run$/i)||pick(/run/i);
      const move = pick(/forward|move/i);
      const crouch = pick(/crouch/i), aim = pick(/aim|point/i), hit = pick(/hit|receive/i);
      const shoot=pick(/shoot|fire|attack|gun/i),death=pick(/death|die/i);
      const base=idle||walk||run||move||m.anims[0];
      const action=clip=>clip?mixer.clipAction(clip):null;
      const actions={idle:action(base),walk:action(walk||move||run),run:action(run||walk||move),
        crouch:action(crouch),aim:action(aim),shoot:action(shoot),hit:action(hit),death:action(death),
        wave:action(pick(/wave/i))};
      const staticIdle=!idle;
      actions.idle.play();if(staticIdle)actions.idle.paused=true;
      for(const one of [actions.shoot,actions.hit,actions.death])if(one){one.setLoop(THREE.LoopOnce);one.clampWhenFinished=one===actions.death;}
      if (preview) mixer.update(Math.min(0.3, Math.max(0.02, (base.duration||1)*0.2)));
      else {
        const entry={mixer,actions,cur:"idle",modelKey:key,staticIdle};this._mixers[u.id]=entry;
        mixer.addEventListener("finished",e=>{
          if(entry.cur==="death"||!([actions.hit,actions.shoot].includes(e.action)))return;
          Engine3D._xfade(entry,"idle",0.18);if(staticIdle)actions.idle.paused=true;
        });
      }
    }
    const wrap = new THREE.Group();
    c.rotation.y += m.rotY;
    wrap.add(c);
    wrap.userData.characterBones = characterBones;
    wrap.userData.namedNodes = namedNodes;
    wrap.userData.modelVariant = u.cls;
    wrap.userData.modelSource=m.source;
    wrap.userData.assetStatus=m.status;
    return wrap;
  },

  /* ---------- 地形高度場（純視覺，遊戲邏輯仍是 2D 平面） ----------
   * 山丘隆起 + 壕溝/彈坑/散兵坑真凹陷。單位/樹/建物 y 皆取此。 */
  heightAt(x, y){
    const m = this._mapRef;
    if (!m) return 0;
    // 全場連續微地形，避免沒有標記 hill 的地圖看起來仍是一張水平紙板。
    let h = Math.sin(x*0.011+0.7)*1.35 + Math.sin(y*0.014-0.4)*1.05 + Math.sin((x+y)*0.006)*0.8;
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

  /* ---------- 水彩渲染管線（技術美術部門，GDD/06 定調：手繪風非寫實風） ---------- */
  /* 三階賽璐璐漸層（暗/中/亮），NearestFilter 產生硬色階 */
  _gradientTex(){
    if (this._gradTex) return this._gradTex;
    const data = new Uint8Array([110, 110, 110, 255, 200, 200, 200, 255, 255, 255, 255, 255]);
    const t = new THREE.DataTexture(data, 3, 1, THREE.RGBAFormat);
    t.minFilter = t.magFilter = THREE.NearestFilter; t.needsUpdate = true;
    return (this._gradTex = t);
  },
  /* 全場景賽璐璐化：Lambert/Standard → Toon（保留色/貼圖/透明設定）。
   * 排除：Basic(特效/UI)、天空、地面(貼圖水彩感靠 buildTerrain 手繪) */
  _toonify(root){
    const grad = this._gradientTex();
    root.traverse(o => {
      if (!o.isMesh && !o.isInstancedMesh) return;
      if (o.userData.noToon) return;
      const conv = mt => {
        if (!mt || mt._toon || !(mt.isMeshLambertMaterial || mt.isMeshStandardMaterial)) return mt;
        const nm = new THREE.MeshToonMaterial({
          color: mt.color ? mt.color.clone() : new THREE.Color(0xffffff),
          map: mt.map || null, gradientMap: grad,
          transparent: mt.transparent, opacity: mt.opacity,
          alphaTest: mt.alphaTest || 0, side: mt.side, skinning: !!mt.skinning
        });
        nm._toon = true; nm._lin = mt._lin;
        return nm;
      };
      if (Array.isArray(o.material)) o.material = o.material.map(conv);
      else o.material = conv(o.material);
    });
  },
  /* 深度描邊後製：半解析度深度圖 → 全螢幕邊緣偵測疊描邊（鉛筆速寫輪廓）。
   * 免 vendored 後製鏈：自建 RT + 全屏四邊形，autoClear=false 疊加。 */
  _initOutline(){
    if (this._outline) return this._outline;
    const rtW = 960, rtH = 600;              // 全解析度：半解析度放大會造成整片糊邊（模糊事故）
    const rt = new THREE.WebGLRenderTarget(rtW, rtH);
    const depthMat = new THREE.MeshDepthMaterial({ depthPacking: THREE.RGBADepthPacking });
    const quadScene = new THREE.Scene();
    const quadCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
    const mat = new THREE.ShaderMaterial({
      transparent: true, depthTest: false, depthWrite: false,
      uniforms: { tDepth: { value: rt.texture }, texel: { value: new THREE.Vector2(1 / rtW, 1 / rtH) },
                  strength: { value: 0.55 } },
      vertexShader: "varying vec2 vUv; void main(){ vUv=uv; gl_Position=vec4(position.xy,0.,1.); }",
      fragmentShader: `
        uniform sampler2D tDepth; uniform vec2 texel; uniform float strength; varying vec2 vUv;
        float unpack(vec4 c){ return dot(c, vec4(1.0, 1.0/255.0, 1.0/65025.0, 1.0/16581375.0)); }
        void main(){
          float d0=unpack(texture2D(tDepth,vUv));
          float dx=abs(unpack(texture2D(tDepth,vUv+vec2(texel.x,0.)))-d0)
                  +abs(unpack(texture2D(tDepth,vUv-vec2(texel.x,0.)))-d0);
          float dy=abs(unpack(texture2D(tDepth,vUv+vec2(0.,texel.y)))-d0)
                  +abs(unpack(texture2D(tDepth,vUv-vec2(0.,texel.y)))-d0);
          float e=step(0.035,(dx+dy)*140.0);                /* 硬閾值：細而俐落的線，不暈開 */
          e*=smoothstep(1.0,0.96,d0);                       /* 遠景(天空)不描 */
          gl_FragColor=vec4(vec3(0.10,0.08,0.05), e*strength*0.8);
        }`
    });
    quadScene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), mat));
    return (this._outline = { rt, depthMat, quadScene, quadCam, mat });
  },
  _renderOutline(){
    const O = this._initOutline(), r = this.renderer;
    const fogSave = this.scene.fog; this.scene.fog = null;
    this.scene.overrideMaterial = O.depthMat;
    r.setRenderTarget(O.rt); r.clear(); r.render(this.scene, this.camera);
    r.setRenderTarget(null);
    this.scene.overrideMaterial = null; this.scene.fog = fogSave;
    const ac = r.autoClear; r.autoClear = false;
    r.render(O.quadScene, O.quadCam);
    r.autoClear = ac;
  },

  /* 修正 sRGB 輸出下的純色材質：hex 色值是 sRGB 直覺色，需轉線性才不會渲染偏白 */
  _linearize(root){
    root.traverse(o => {
      if (!o.isMesh && !o.isInstancedMesh) return;
      const ms = Array.isArray(o.material) ? o.material : [o.material];
      for (const mt of ms){
        if (mt && mt.isMeshLambertMaterial && !mt.map && mt.color && !mt._lin){
          mt.color.convertSRGBToLinear(); mt._lin = true;
        }
      }
    });
  },

  /* ---------- 程序化材質工廠（零素材：canvas 手繪，依地圖種子固定） ---------- */
  _rng(str){
    let h = 2166136261;
    for (let i = 0; i < str.length; i++) h = ((h ^ str.charCodeAt(i)) * 16777619) >>> 0;
    return () => ((h = (h * 1664525 + 1013904223) >>> 0) / 4294967296);
  },
  /* 牆面：灰泥底＋斑駁污漬＋兩排窗（玻璃反光/窗櫺）＋隨機木門＋底部濺泥 */
  _wallTex(rnd){
    const cv = document.createElement("canvas"); cv.width = 256; cv.height = 128;
    const c = cv.getContext("2d");
    const palette = ["#b8a888", "#a89a80", "#9a948a", "#b5ab96", "#8f8878", "#a99783"];
    c.fillStyle = palette[(rnd() * palette.length) | 0]; c.fillRect(0, 0, 256, 128);
    for (let i = 0; i < 90; i++){
      c.fillStyle = `rgba(${rnd() < 0.5 ? "0,0,0" : "255,255,255"},${(0.02 + rnd() * 0.05).toFixed(3)})`;
      const x = rnd() * 256, y = rnd() * 128, r = 3 + rnd() * 14;
      c.beginPath(); c.ellipse(x, y, r, r * 0.6, 0, 0, 7); c.fill();
    }
    const mud = c.createLinearGradient(0, 92, 0, 128);
    mud.addColorStop(0, "rgba(58,48,34,0)"); mud.addColorStop(1, "rgba(58,48,34,0.45)");
    c.fillStyle = mud; c.fillRect(0, 92, 256, 36);
    const doorAt = rnd() < 0.75 ? (rnd() * 4) | 0 : -1;
    for (let row = 0; row < 2; row++){
      const wy = row ? 72 : 20;
      for (let i = 0; i < 4; i++){
        const wx = 20 + i * 60;
        if (row === 1 && i === doorAt){                                  // 一樓此格改木門
          c.fillStyle = "#4a3a28"; c.fillRect(wx - 3, 66, 32, 62);
          c.fillStyle = "#3a2d1e"; c.fillRect(wx + 1, 72, 24, 56);
          c.fillStyle = "#c9b07a"; c.fillRect(wx + 19, 100, 3, 6);       // 門把
          continue;
        }
        c.fillStyle = "#2c2f33"; c.fillRect(wx, wy, 26, 32);
        c.fillStyle = "rgba(150,180,205,0.5)"; c.fillRect(wx + 2, wy + 2, 22, 13); // 玻璃反光
        c.lineWidth = 3; c.strokeStyle = "#55483a"; c.strokeRect(wx - 1.5, wy - 1.5, 29, 35);
        c.fillStyle = "#55483a"; c.fillRect(wx, wy + 15, 26, 2.5);       // 窗櫺
        if (rnd() < 0.25){ c.fillStyle = "rgba(20,22,24,0.85)"; c.fillRect(wx + 2, wy + 2, 22, 28); } // 破窗
      }
    }
    const t = new THREE.CanvasTexture(cv); t.encoding = THREE.sRGBEncoding; return t;
  },
  /* 接觸陰影：放射漸層黑圓（假 AO，鋪在建物/樹底） */
  _shadowTex(){
    if (this._shTex) return this._shTex;
    const cv = document.createElement("canvas"); cv.width = cv.height = 64;
    const c = cv.getContext("2d"), g = c.createRadialGradient(32, 32, 4, 32, 32, 32);
    g.addColorStop(0, "rgba(0,0,0,0.42)"); g.addColorStop(1, "rgba(0,0,0,0)");
    c.fillStyle = g; c.fillRect(0, 0, 64, 64);
    return (this._shTex = new THREE.CanvasTexture(cv));
  },
  _contactShadow(grp, x, y, w, d, hg){
    const s = new THREE.Mesh(new THREE.PlaneGeometry(w, d),
      new THREE.MeshBasicMaterial({ map: this._shadowTex(), transparent: true, depthWrite: false }));
    s.rotation.x = -Math.PI / 2; s.position.set(x, hg + 0.42, y); grp.add(s);
  },
  /* 草叢：透明底手繪草葉（交叉面片用） */
  _grassTex(){
    if (this._grTex) return this._grTex;
    const cv = document.createElement("canvas"); cv.width = 64; cv.height = 48;
    const c = cv.getContext("2d");
    for (let i = 0; i < 26; i++){
      const x = 6 + Math.random() * 52, sway = Math.random() * 14 - 7, h = 22 + Math.random() * 24;
      c.strokeStyle = `rgb(${60 + Math.random() * 40 | 0},${110 + Math.random() * 50 | 0},${45 + Math.random() * 30 | 0})`;
      c.lineWidth = 1.6 + Math.random();
      c.beginPath(); c.moveTo(x, 48); c.quadraticCurveTo(x + sway * 0.4, 48 - h * 0.6, x + sway, 48 - h); c.stroke();
    }
    this._grTex = new THREE.CanvasTexture(cv);
    this._grTex.encoding = THREE.sRGBEncoding;
    return this._grTex;
  },
  /* 雲：柔邊白棉團 */
  _cloudTex(){
    if (this._clTex) return this._clTex;
    const cv = document.createElement("canvas"); cv.width = 256; cv.height = 128;
    const c = cv.getContext("2d");
    for (let i = 0; i < 14; i++){
      const x = 40 + Math.random() * 176, y = 45 + Math.random() * 40, r = 18 + Math.random() * 30;
      const g = c.createRadialGradient(x, y, 2, x, y, r);
      g.addColorStop(0, "rgba(255,255,255,0.55)"); g.addColorStop(1, "rgba(255,255,255,0)");
      c.fillStyle = g; c.beginPath(); c.arc(x, y, r, 0, 7); c.fill();
    }
    return (this._clTex = new THREE.CanvasTexture(cv));
  },

  /* 真 3D 主路徑專用地表：只畫土色、道路與地表痕跡；建築/樹/工事不再烙成俯視圖。 */
  _groundCanvas(m){
    const W=m.w||960,H=m.h||600,cv=document.createElement("canvas");cv.width=W;cv.height=H;
    const c=cv.getContext("2d"),rnd=this._rng("ground-"+m.id+"-"+W+"x"+H);
    c.fillStyle=m.ground||"#7a8f5a";c.fillRect(0,0,W,H);
    for(let i=0;i<Math.round(W*H/4200);i++){
      const x=rnd()*W,y=rnd()*H,rx=10+rnd()*42,ry=rx*(0.35+rnd()*0.45);
      c.fillStyle=rnd()<0.55?`rgba(45,58,30,${0.025+rnd()*0.055})`:`rgba(165,145,92,${0.025+rnd()*0.05})`;
      c.beginPath();c.ellipse(x,y,rx,ry,rnd()*Math.PI,0,7);c.fill();
    }
    return cv;
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
    // 時段化光照（dept-12：太陽色溫/強度/霧色隨 sky 連動，鳴潮式大氣感）
    const LIGHTING = {
      day:  { sun:0xfff1d6, i:0.95, fog:0xd9e3ea, hemi:0.55 },
      dawn: { sun:0xffc9a0, i:0.82, fog:0xdccbbe, hemi:0.48 },
      dusk: { sun:0xff9a60, i:0.75, fog:0xcdb2a0, hemi:0.45 },
      night:{ sun:0x9ab0d8, i:0.50, fog:0x5a687e, hemi:0.38 }
    };
    const Lset = LIGHTING[m.sky] || LIGHTING.day;
    sun.color.setHex(Lset.sun); sun.intensity = Lset.i;
    this.scene.fog.color.setHex(Lset.fog);
    if (this.scene.background && this.scene.background.isColor) this.scene.background.setHex(Lset.fog);
    this.scene.traverse(o => { if (o.isHemisphereLight) o.intensity = Lset.hemi; });
    this.scene.fog.near = 1150 * S; this.scene.fog.far = 3400 * S;
    this.camera.far = 6000 * S;

    // 遠景大地（地圖外圍基色，接天際）
    const far = new THREE.Mesh(new THREE.PlaneGeometry(9000 * S, 9000 * S),
      new THREE.MeshLambertMaterial({ color: new THREE.Color(m.ground || "#7a8f5a").multiplyScalar(0.9) }));
    far.rotation.x = -Math.PI / 2; far.position.set(mw / 2, -0.25, mh / 2); far.receiveShadow = true;
    grp.add(far);

    // 天空穹頂：垂直漸層，依地圖 sky 欄位換時段（day/dawn/dusk/night，GDD/11 天空盒四時段）
    const SKY_STOPS = {
      day:  ["#4f8ac9", "#9ec6e6", "#e8ddc2", "#efe6cf"],
      dawn: ["#3c5a8a", "#b58ca0", "#f0c896", "#f6e3c0"],
      dusk: ["#2e3f66", "#8a6a8e", "#e8a06a", "#f2d3a0"],
      night:["#0b1430", "#1c2a52", "#3a4a72", "#54628c"]
    };
    const skyKind = SKY_STOPS[m.sky] ? m.sky : "day";
    this._skyTexes = this._skyTexes || {};
    if (!this._skyTexes[skyKind]){
      const sc2 = document.createElement("canvas"); sc2.width = 1; sc2.height = 256;
      const g2 = sc2.getContext("2d"), gr = g2.createLinearGradient(0, 0, 0, 256);
      const st = SKY_STOPS[skyKind];
      gr.addColorStop(0, st[0]); gr.addColorStop(0.55, st[1]); gr.addColorStop(0.78, st[2]); gr.addColorStop(1, st[3]);
      g2.fillStyle = gr; g2.fillRect(0, 0, 1, 256);
      const t = new THREE.CanvasTexture(sc2); t.encoding = THREE.sRGBEncoding;
      this._skyTexes[skyKind] = t;
    }
    const sky = new THREE.Mesh(new THREE.SphereGeometry(4200 * S, 24, 12, 0, Math.PI * 2, 0, Math.PI * 0.55),
      new THREE.MeshBasicMaterial({ map: this._skyTexes[skyKind], side: THREE.BackSide, fog: false }));
    sky.position.set(mw / 2, -40, mh / 2);
    grp.add(sky);

    // 遠景山脈剪影：地平線環狀低多邊形錐體，吃霧自然淡出（GDD/11 遠景）
    const mtnMat = new THREE.MeshLambertMaterial({ color: 0x6d7c92 });
    for (let i = 0; i < 15; i++){
      const a = (i / 15) * Math.PI * 2 + (i % 3) * 0.13;
      const hM = (260 + (i * 137) % 260) * S, wM = (520 + (i * 251) % 420) * S;
      const mtn = new THREE.Mesh(new THREE.ConeGeometry(wM, hM, 5), mtnMat);
      mtn.position.set(mw / 2 + Math.cos(a) * 2500 * S, hM / 2 - 6, mh / 2 + Math.sin(a) * 2500 * S);
      mtn.rotation.y = a; mtn.userData.noToon = true;
      grp.add(mtn);
    }

    // 雨天粒子（map.weather==="rain"）：以視錐附近循環下落
    if (this._rain){ this.scene.remove(this._rain); this._rain = null; }
    if (m.weather === "rain"){
      const N = 900, pos = new Float32Array(N * 3);
      for (let i = 0; i < N; i++){
        pos[i*3] = Math.random() * 900 - 450; pos[i*3+1] = Math.random() * 380; pos[i*3+2] = Math.random() * 900 - 450;
      }
      const geo = new THREE.BufferGeometry();
      geo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
      const rain = new THREE.Points(geo, new THREE.PointsMaterial({
        color: 0x9fb6cc, size: 1.8, transparent: true, opacity: 0.5, sizeAttenuation: true, fog: true }));
      rain.userData.noToon = true; rain.frustumCulled = false;
      this._rain = rain; this.scene.add(rain);
    }

    // 真 3D 地表：乾淨 diffuse＋高度場；不再把建築/樹/工事的俯視圖烙在地面。
    const tex = new THREE.CanvasTexture(this._groundCanvas(m));
    tex.anisotropy = 4;
    tex.encoding = THREE.sRGBEncoding;   // 渲染器輸出 sRGB，貼圖必須同標記，否則整張洗白
    const segX = Math.min(220, Math.round(mw / 8)), segY = Math.min(160, Math.round(mh / 8));
    const geo = new THREE.PlaneGeometry(mw, mh, segX, segY);
    geo.rotateX(-Math.PI / 2);                 // 幾何本身轉平（頂點 y=高度、x/z=世界）
    geo.translate(mw / 2, 0, mh / 2);
    const pos = geo.attributes.position;
    for (let i = 0; i < pos.count; i++){
      pos.setY(i, this.heightAt(pos.getX(i), pos.getZ(i)));
    }
    geo.computeVertexNormals();
    const gnd = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ map:tex, roughness:0.94, metalness:0.01 }));
    gnd.name="terrain-heightfield";gnd.receiveShadow = true;
    gnd.userData.noToon = true;          // 地面手繪貼圖不做色階化（避免把水彩底圖分色）
    grp.add(gnd);

    // 地圖厚度讓邊界與凹地有真正體積，不再像一張漂浮平面。
    const earth=new THREE.Mesh(new THREE.BoxGeometry(mw,10,mh),new THREE.MeshStandardMaterial({color:0x5f5138,roughness:1}));
    earth.name="terrain-volume";earth.position.set(mw/2,-6,mh/2);earth.receiveShadow=true;grp.add(earth);

    // 道路是貼合高度場的立體路面，不再畫進地表貼圖。
    if((m.allow||["land"]).includes("land")&&m.bases&&m.bases.length===2){
      const rr=this._rng("road-"+m.id),a=m.bases[0],b=m.bases[1];
      const mx=(a.x+b.x)/2+(rr()-.5)*110,my=(a.y+b.y)/2+(rr()-.5)*150;
      const roadDef=m.roads&&m.roads[0];
      const roadMat=new THREE.MeshLambertMaterial({color:0x765f42});
      const edgeMat=new THREE.MeshLambertMaterial({color:0x9a8057});
      const point=t=>roadDef?{x:roadDef.x1+(roadDef.x2-roadDef.x1)*t,z:roadDef.y1+(roadDef.y2-roadDef.y1)*t}:
        ({x:(1-t)*(1-t)*a.x+2*(1-t)*t*mx+t*t*b.x,z:(1-t)*(1-t)*a.y+2*(1-t)*t*my+t*t*b.y});
      for(let i=0;i<48;i++){
        const p=point(i/48),q=point((i+1)/48),cx=(p.x+q.x)/2,cz=(p.z+q.z)/2;
        const len=Math.hypot(q.x-p.x,q.z-p.z)+1.2,ang=Math.atan2(q.z-p.z,q.x-p.x),hy=this.heightAt(cx,cz);
        const rw=roadDef?roadDef.w:20;
        const edge=new THREE.Mesh(new THREE.BoxGeometry(len,0.7,rw),edgeMat);
        edge.name="road-foundation";edge.userData.terrainFunction="vehicle-cost-0.72;foot-cost-0.92";edge.position.set(cx,hy+0.18,cz);edge.rotation.y=-ang;edge.receiveShadow=true;grp.add(edge);
        const road=new THREE.Mesh(new THREE.BoxGeometry(len,0.55,rw*.75),roadMat);
        road.name="road-surface";road.userData.terrainFunction="vehicle-cost-0.72;foot-cost-0.92";road.position.set(cx,hy+0.58,cz);road.rotation.y=-ang;road.receiveShadow=true;grp.add(road);
      }
    }

    // 獨立 3D 水面與水底：深淺、透明與高光各異，涉水/艦艇可見浸水關係。
    const waterKinds=[
      [m.deepwaters,0x285a77,0.78,0x17394d],
      [m.waters,0x3d7891,0.68,0x28586d],
      [m.shallows,0x7fb9c4,0.52,0x668f86]
    ];
    for(const [list,col,opacity,bedCol] of waterKinds){for(const w of(list||[])){
      const bedMesh=new THREE.Mesh(new THREE.BoxGeometry(w.w,4,w.h),new THREE.MeshStandardMaterial({color:bedCol,roughness:0.86}));
      bedMesh.name="water-bed";bedMesh.position.set(w.x+w.w/2,-2.2,w.y+w.h/2);bedMesh.receiveShadow=true;grp.add(bedMesh);
      const wm=new THREE.MeshPhongMaterial({color:col,transparent:true,opacity,shininess:100,specular:0xb9e8ff,depthWrite:false,side:THREE.DoubleSide});
      const surf=new THREE.Mesh(new THREE.PlaneGeometry(w.w,w.h,8,8),wm);surf.name="water-surface";surf.rotation.x=-Math.PI/2;surf.position.set(w.x+w.w/2,0.58,w.y+w.h/2);surf.renderOrder=2;grp.add(surf);
      const wavePts=[];
      for(let yy=w.y+8;yy<w.y+w.h;yy+=14)for(let xx=w.x;xx<w.x+w.w-8;xx+=8){
        wavePts.push(xx,0.7,yy+Math.sin((xx+yy)*.08)*1.4,xx+8,0.7,yy+Math.sin((xx+8+yy)*.08)*1.4);
      }
      if(wavePts.length){const wg=new THREE.BufferGeometry();wg.setAttribute("position",new THREE.Float32BufferAttribute(wavePts,3));
        grp.add(new THREE.LineSegments(wg,new THREE.LineBasicMaterial({color:0xcbe9ec,transparent:true,opacity:opacity*.22})));}
    }}

    // 壕溝護牆與彈坑土堤是獨立幾何；凹陷仍由 heightAt 頂點場提供。
    const soilMat=new THREE.MeshStandardMaterial({color:0x69553a,roughness:1});
    for(const t of(m.trenches||[])){
      const horiz=t.w>=t.h,wallGeo=horiz?new THREE.BoxGeometry(t.w+5,3,3):new THREE.BoxGeometry(3,3,t.h+5);
      const a=new THREE.Mesh(wallGeo,soilMat),b=new THREE.Mesh(wallGeo,soilMat);
      a.name=b.name="trench-wall";
      if(horiz){a.position.set(t.x+t.w/2,1.2,t.y-1);b.position.set(t.x+t.w/2,1.2,t.y+t.h+1);}
      else{a.position.set(t.x-1,1.2,t.y+t.h/2);b.position.set(t.x+t.w+1,1.2,t.y+t.h/2);}
      a.castShadow=b.castShadow=true;grp.add(a,b);
    }
    for(const q of(m.craters||[]).concat(m.foxholes||[])){
      const rim=new THREE.Mesh(new THREE.TorusGeometry(q.r*.82,Math.max(1.1,q.r*.08),6,28),soilMat);
      rim.name="crater-rim";rim.rotation.x=-Math.PI/2;rim.scale.z=.8;rim.position.set(q.x,.45,q.y);rim.castShadow=true;grp.add(rim);
    }

    // 建築：窗戶牆面材質＋斜屋頂＋高矮錯落＋煙囪＋接觸陰影
    const rnd = this._rng((m.ground || "") + mw + "x" + mh);
    const wallTexes = [this._wallTex(rnd), this._wallTex(rnd), this._wallTex(rnd)];
    const roofCols = [0x7a4a38, 0x5a5f66, 0x6b5140, 0x4e585e];
    const topMat = new THREE.MeshLambertMaterial({ color: 0x8f887c });
    const brickMat = new THREE.MeshLambertMaterial({ color: 0x6e4636 });
    for (const s of (m.solids || [])){
      const cx = s.x + s.w / 2, cz = s.y + s.h / 2, hg = this.heightAt(cx, cz);
      const bh = 36 + rnd() * 18;                                        // 樓高錯落
      const wall = new THREE.MeshLambertMaterial({ map: wallTexes[(rnd() * 3) | 0] });
      const b = new THREE.Mesh(new THREE.BoxGeometry(s.w, bh, s.h),
        [wall, wall, topMat, topMat, wall, wall]);                        // 側面窗牆、頂面素色
      b.name="building-solid-3d";b.userData.terrainFunction="blocks-ground-and-los;wall-cover-0.65";
      b.position.set(cx, bh / 2 + hg, cz);
      b.castShadow = b.receiveShadow = true; grp.add(b);
      // 斜屋頂（三角柱擠出，屋脊沿長邊）
      const alongX = s.w >= s.h;
      const len = (alongX ? s.w : s.h) + 5, wid = (alongX ? s.h : s.w) + 5;
      const roofH = wid * (0.28 + rnd() * 0.12);
      const shp = new THREE.Shape();
      shp.moveTo(-wid / 2, 0); shp.lineTo(wid / 2, 0); shp.lineTo(0, roofH); shp.closePath();
      const rg = new THREE.ExtrudeGeometry(shp, { depth: len, bevelEnabled: false });
      rg.translate(0, 0, -len / 2);
      const roof = new THREE.Mesh(rg, new THREE.MeshLambertMaterial({ color: roofCols[(rnd() * roofCols.length) | 0] }));
      roof.name="building-roof-3d";roof.userData.terrainFunction="visual-roof";
      roof.rotation.y = alongX ? Math.PI / 2 : 0;
      roof.position.set(cx, bh + hg - 0.5, cz); roof.castShadow = true; grp.add(roof);
      if (rnd() < 0.55){                                                  // 煙囪
        const ch = new THREE.Mesh(new THREE.BoxGeometry(4, roofH + 8, 4), brickMat);
        ch.position.set(cx + (alongX ? (rnd() - 0.5) * s.w * 0.5 : s.w * 0.18),
                        bh + roofH * 0.5 + 3 + hg,
                        cz + (alongX ? s.h * 0.18 : (rnd() - 0.5) * s.h * 0.5));
        ch.castShadow = true; grp.add(ch);
      }
      this._contactShadow(grp, cx, cz, s.w + 18, s.h + 18, hg);
    }
    // 碉堡：低矮混凝土 + 射口帶
    const bunkMat = new THREE.MeshLambertMaterial({ color: 0x8d8a80 });
    const slitMat = new THREE.MeshLambertMaterial({ color: 0x23211d });
    for (const b of (m.bunkers || [])){
      const hg = this.heightAt(b.x + b.w / 2, b.y + b.h / 2);
      const k = new THREE.Mesh(new THREE.BoxGeometry(b.w, 24, b.h), bunkMat);
      k.name="bunker-3d";k.userData.terrainFunction="enterable-heavy-cover-0.3;blocks-los";
      k.position.set(b.x + b.w / 2, 12 + hg, b.y + b.h / 2); k.castShadow = k.receiveShadow = true; grp.add(k);
      const s1 = new THREE.Mesh(new THREE.BoxGeometry(b.w + 0.6, 3.5, b.h + 0.6), slitMat);
      s1.position.set(b.x + b.w / 2, 14 + hg, b.y + b.h / 2); grp.add(s1);
    }
    // 樹：三型混生（針葉塔/闊葉團/枯樹枝幹）＋色調與姿態抖動＋樹底陰影
    const trunkMat = new THREE.MeshLambertMaterial({ color: 0x4a3826 });
    const leafMats = [0x3a6030, 0x4c7a3c, 0x2f5228, 0x5c7f38, 0x466b2e]
      .map(c0 => new THREE.MeshLambertMaterial({ color: c0 }));
    for (const t of (m.trees || [])){
      const tr0 = this._rng("t" + t.x + "," + t.y);
      const dead = t.r < 18, hg = this.heightAt(t.x, t.y);
      const hT = dead ? 24 + tr0() * 8 : 30 + t.r * 0.5 + tr0() * 10;
      const tr = new THREE.Mesh(new THREE.CylinderGeometry(Math.max(1.6, t.r * 0.13), Math.max(2.4, t.r * 0.2), hT, 6), trunkMat);
      tr.position.set(t.x, hT / 2 + hg, t.y);
      tr.rotation.z = (tr0() - 0.5) * 0.1; tr.castShadow = true; grp.add(tr);
      if (dead){                                                          // 枯樹：兩根斜枝
        for (let i = 0; i < 2; i++){
          const br = new THREE.Mesh(new THREE.CylinderGeometry(0.7, 1.1, 10 + tr0() * 6, 5), trunkMat);
          br.position.set(t.x + (tr0() - 0.5) * 5, hT * (0.55 + tr0() * 0.3) + hg, t.y + (tr0() - 0.5) * 5);
          br.rotation.z = 0.6 + tr0() * 0.9; br.rotation.y = tr0() * 6.28;
          br.castShadow = true; grp.add(br);
        }
      } else if (tr0() < 0.45){                                           // 針葉：三層塔
        for (let i = 0; i < 3; i++){
          const rr = t.r * (0.95 - i * 0.24), mat = leafMats[(tr0() * leafMats.length) | 0];
          const c1 = new THREE.Mesh(new THREE.ConeGeometry(rr, t.r * (1.15 - i * 0.18), 7), mat);
          c1.position.set(t.x, hT * 0.55 + t.r * (0.45 + i * 0.5) + hg, t.y);
          c1.castShadow = true; grp.add(c1);
        }
      } else {                                                            // 闊葉：不規則球團
        for (let i = 0; i < 3; i++){
          const rr = t.r * (0.55 + tr0() * 0.35), mat = leafMats[(tr0() * leafMats.length) | 0];
          const bl = new THREE.Mesh(new THREE.IcosahedronGeometry(rr, 1), mat);
          bl.position.set(t.x + (tr0() - 0.5) * t.r * 0.8, hT * 0.85 + (tr0() - 0.3) * t.r * 0.5 + hg,
                          t.y + (tr0() - 0.5) * t.r * 0.8);
          bl.scale.y = 0.82; bl.castShadow = true; grp.add(bl);
        }
      }
      this._contactShadow(grp, t.x, t.y, t.r * 2.2, t.r * 2.2, hg);
    }

    // 指定 bush＝可進入的立體高草 Terrain Action 區，不再只是一塊地面色斑。
    {
      const blades=[];
      for(const b of(m.bushes||[])){
        const br=this._rng("bush-"+b.x+"-"+b.y);
        const count=Math.max(16,Math.round(b.r*1.5));
        for(let i=0;i<count;i++){
          const a=br()*Math.PI*2,rr=Math.sqrt(br())*b.r*.92,x=b.x+Math.cos(a)*rr,y=b.y+Math.sin(a)*rr;
          blades.push({x,y,s:.75+br()*.7,r:br()*Math.PI});
        }
      }
      if(blades.length){
        const bladeGeo=new THREE.ConeGeometry(.5,7,5),mat=new THREE.MeshLambertMaterial({color:0x3f6f31});
        const inst=new THREE.InstancedMesh(bladeGeo,mat,blades.length),d=new THREE.Object3D();
        inst.name="terrain-bush-grass-3d";
        blades.forEach((v,i)=>{d.position.set(v.x,this.heightAt(v.x,v.y)+3.4*v.s,v.y);d.rotation.set(Math.sin(v.r)*.1,v.r,Math.cos(v.r)*.12);d.scale.set(v.s*.7,v.s,v.s*.7);d.updateMatrix();inst.setMatrixAt(i,d.matrix);});
        inst.castShadow=true;grp.add(inst);
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

    // 沙包：一顆顆堆疊的立體沙包牆（InstancedMesh，兩層交錯）
    {
      const bags = [];
      for (const sb of (m.sandbags || []).concat(m.reefs ? [] : [])){
        const horiz = sb.w >= sb.h, L = horiz ? sb.w : sb.h;
        const n = Math.max(3, Math.round(L / 7));
        for (let lay = 0; lay < 2; lay++){
          for (let i = 0; i < n - lay; i++){
            const f = (i + 0.5 + lay * 0.5) / n;
            bags.push({
              x: sb.x + (horiz ? f * sb.w : sb.w / 2) + (rnd() - 0.5) * 1.4,
              y: sb.y + (horiz ? sb.h / 2 : f * sb.h) + (rnd() - 0.5) * 1.4,
              h: 1.6 + lay * 3.1, ry: (horiz ? 0 : Math.PI / 2) + (rnd() - 0.5) * 0.3,
              s: 0.9 + rnd() * 0.25
            });
          }
        }
      }
      if (bags.length){
        const bagGeo = new THREE.SphereGeometry(1, 7, 5); bagGeo.scale(3.6, 1.8, 2.3);
        const inst = new THREE.InstancedMesh(bagGeo, new THREE.MeshLambertMaterial({ color: 0x9d8b63 }), bags.length);
        inst.name="sandbag-cover-3d";inst.userData.terrainFunction="directional-cover-0.5";
        const d = new THREE.Object3D();
        bags.forEach((b, i) => {
          d.position.set(b.x, b.h + this.heightAt(b.x, b.y), b.y);
          d.rotation.set(0, b.ry, 0); d.scale.setScalar(b.s);
          d.updateMatrix(); inst.setMatrixAt(i, d.matrix);
        });
        inst.castShadow = true; grp.add(inst);
      }
    }

    // 鐵絲網：木樁＋三道鐵線＋交錯斜線（樁 InstancedMesh、線一筆 LineSegments）
    {
      const posts = [], segs = [];
      for (const w of (m.wires || [])){
        const horiz = w.w >= w.h, L = horiz ? w.w : w.h;
        const n = Math.max(2, Math.round(L / 16)) + 1;
        const pts = [];
        for (let i = 0; i < n; i++){
          const f = i / (n - 1);
          const px = w.x + (horiz ? f * w.w : w.w / 2), py = w.y + (horiz ? w.h / 2 : f * w.h);
          pts.push([px, py, this.heightAt(px, py)]);
          posts.push({ x: px, y: py });
        }
        for (let i = 0; i < pts.length - 1; i++){
          const [ax, ay, ah] = pts[i], [bx, by, bh2] = pts[i + 1];
          for (const hh of [2.6, 5.4, 8.0])                                        // 三道橫線
            segs.push(ax, ah + hh, ay, bx, bh2 + hh, by);
          segs.push(ax, ah + 2.6, ay, bx, bh2 + 8.0, by);                          // 交錯斜線
          segs.push(ax, ah + 8.0, ay, bx, bh2 + 2.6, by);
        }
      }
      if (posts.length){
        const pGeo = new THREE.CylinderGeometry(0.55, 0.7, 9.5, 5);
        const pInst = new THREE.InstancedMesh(pGeo, new THREE.MeshLambertMaterial({ color: 0x4c3a26 }), posts.length);
        const d = new THREE.Object3D();
        posts.forEach((p, i) => {
          d.position.set(p.x, 4.75 + this.heightAt(p.x, p.y), p.y);
          d.rotation.set(0, 0, (rnd() - 0.5) * 0.12); d.updateMatrix(); pInst.setMatrixAt(i, d.matrix);
        });
        pInst.castShadow = true; grp.add(pInst);
        const lg = new THREE.BufferGeometry();
        lg.setAttribute("position", new THREE.Float32BufferAttribute(segs, 3));
        const wireLines=new THREE.LineSegments(lg,new THREE.LineBasicMaterial({color:0x3d3d38}));
        wireLines.name="wire-obstacle-3d";wireLines.userData.terrainFunction="infantry-slow;tank-crush";grp.add(wireLines);
      }
    }

    // 混凝土路障與反戰車拒馬：視覺物件和 game.js 的移動成本／碰撞使用同一資料。
    {
      const concrete=new THREE.MeshStandardMaterial({color:0x8c8d87,roughness:.92,metalness:.02});
      const rust=new THREE.MeshStandardMaterial({color:0x544b40,roughness:.58,metalness:.65});
      for(const r of(m.roadblocks||[])){
        const horiz=r.w>=r.h,L=horiz?r.w:r.h,n=Math.max(1,Math.round(L/16));
        for(let i=0;i<n;i++){
          const f=(i+.5)/n,x=r.x+(horiz?f*r.w:r.w/2),z=r.y+(horiz?r.h/2:f*r.h),hg=this.heightAt(x,z);
          const barrier=new THREE.Mesh(new THREE.BoxGeometry(horiz?L/n-1:5.5,5,horiz?5.5:L/n-1),concrete);
          barrier.name="roadblock-concrete-3d";barrier.userData.terrainFunction="vehicle-cost-2.35;infantry-cost-1.25";
          barrier.position.set(x,hg+2.5,z);barrier.castShadow=barrier.receiveShadow=true;grp.add(barrier);
        }
      }
      for(const r of(m.tanktraps||[])){
        const horiz=r.w>=r.h,L=horiz?r.w:r.h,n=Math.max(1,Math.round(L/14));
        for(let i=0;i<n;i++){
          const f=(i+.5)/n,x=r.x+(horiz?f*r.w:r.w/2),z=r.y+(horiz?r.h/2:f*r.h),hg=this.heightAt(x,z);
          const trap=new THREE.Group();trap.name="tanktrap-hedgehog-3d";trap.userData.terrainFunction="tracked-block;infantry-pass";trap.position.set(x,hg+3,z);
          for(const [rz,ry] of [[Math.PI/4,0],[-Math.PI/4,0],[0,Math.PI/2]]){
            const beam=new THREE.Mesh(new THREE.BoxGeometry(10,1.25,1.25),rust);beam.rotation.set(0,ry,rz);beam.castShadow=true;trap.add(beam);
          }
          grp.add(trap);
        }
      }
    }

    // 散景：草叢（交叉面片）＋岩石，避開水域/建物/碉堡
    {
      const ok = (x, y) => !(G.isWater && G.isWater(x, y)) &&
        !G.inAny(m.solids, x, y) && !G.inAny(m.bunkers, x, y) && !G.inAny(m.waters, x, y);
      // 植被密度對照上市遊戲全面上調（關卡設計部門 2026-07-19）：雙色草交錯、體型加大
      const tufts = [];
      for (let i = 0, tries = 0; i < 430 * S && tries < 2200; tries++){
        const x = rnd() * mw, y = rnd() * mh;
        if (!ok(x, y)) continue;
        tufts.push({ x, y, r: rnd() * Math.PI, s: 1.0 + rnd() * 1.6 }); i++;
      }
      if (tufts.length){
        const cols = [0x5a8438, 0x6f9440];
        for (let ci = 0; ci < 2; ci++){
          const mine = tufts.filter((_, i) => i % 2 === ci);
          if (!mine.length) continue;
          const gMat = new THREE.MeshLambertMaterial({ color: cols[ci] });
          const inst = new THREE.InstancedMesh(new THREE.ConeGeometry(.5, 5.6, 4), gMat, mine.length);
          const d = new THREE.Object3D(); inst.name = "terrain-grass-3d";
          mine.forEach((t, i) => {
            d.position.set(t.x, 2.6 * t.s + this.heightAt(t.x, t.y), t.y);
            d.rotation.set(Math.sin(t.r) * .13, t.r, Math.cos(t.r) * .13); d.scale.set(t.s * .7, t.s, t.s * .7);
            d.updateMatrix(); inst.setMatrixAt(i, d.matrix);
          });
          inst.castShadow = true; grp.add(inst);
        }
      }
      const rocks = [];
      for (let i = 0, tries = 0; i < 36 * S && tries < 300; tries++){
        const x = rnd() * mw, y = rnd() * mh;
        if (!ok(x, y)) continue;
        rocks.push({ x, y, s: 1.2 + rnd() * 2.6, r: rnd() * Math.PI * 2 }); i++;
      }
      if (rocks.length){
        const inst = new THREE.InstancedMesh(new THREE.IcosahedronGeometry(1, 0),
          new THREE.MeshLambertMaterial({ color: 0x7d7a70 }), rocks.length);
        const d = new THREE.Object3D();
        rocks.forEach((r, i) => {
          d.position.set(r.x, r.s * 0.45 + this.heightAt(r.x, r.y), r.y);
          d.rotation.set(r.r, r.r * 2.3, 0); d.scale.set(r.s, r.s * 0.7, r.s * 0.85);
          d.updateMatrix(); inst.setMatrixAt(i, d.matrix);
        });
        inst.castShadow = true; grp.add(inst);
      }
    }

    // 天空生氣：太陽光暈 + 飄浮雲層（Sprite 恆面向相機，不受霧影響）
    {
      const sunSpr = new THREE.Sprite(new THREE.SpriteMaterial({ map: this._shadowTex(), // 佔位，下行改色
        color: 0xfff3c0, transparent: true, opacity: 0.9, fog: false,
        blending: THREE.AdditiveBlending, depthWrite: false }));
      sunSpr.material.map = this._cloudTex();
      sunSpr.position.set(mw * 0.79, 560 * S, mh * 0.13); sunSpr.scale.set(260 * S, 130 * S, 1);
      grp.add(sunSpr);
      for (let i = 0; i < 6; i++){
        const cl = new THREE.Sprite(new THREE.SpriteMaterial({ map: this._cloudTex(),
          transparent: true, opacity: 0.35 + rnd() * 0.3, fog: false, depthWrite: false }));
        cl.position.set(rnd() * mw * 1.6 - mw * 0.3, (330 + rnd() * 220) * S, rnd() * mh * 1.6 - mh * 0.3);
        cl.scale.set((320 + rnd() * 380) * S, (90 + rnd() * 120) * S, 1);
        grp.add(cl);
      }
    }
    this._linearize(grp);
    this._toonify(grp);
    this.scene.add(grp);
    // 舊單位快取全清（換圖重建）
    for (const id in this._units){ this.scene.remove(this._units[id]); }
    this._units = {};
  },

  /* 可動程序化人員：所有肢體都是獨立 3D 關節，不使用圖片或 billboard。 */
  _soldierRig(u, mats){
    const root=new THREE.Group(),hips=new THREE.Group(),torso=new THREE.Group();
    root.name=`clean-soldier-${u.cls}`;hips.name="hips";torso.name="torso";
    hips.position.y=8.15;root.add(hips);hips.add(torso);
    const mesh=(geo,mat,parent,x=0,y=0,z=0)=>{const o=new THREE.Mesh(geo,mat);o.position.set(x,y,z);o.castShadow=true;o.receiveShadow=true;parent.add(o);return o;};
    const box=(w,h,d,mat,parent,x=0,y=0,z=0)=>mesh(new THREE.BoxGeometry(w,h,d),mat,parent,x,y,z);
    const cyl=(rt,rb,h,mat,parent,x=0,y=0,z=0,seg=10)=>mesh(new THREE.CylinderGeometry(rt,rb,h,seg),mat,parent,x,y,z);
    const olive=new THREE.MeshStandardMaterial({color:0x53613d,roughness:.82,metalness:.04});
    const cloth=new THREE.MeshStandardMaterial({color:mats.body.color,roughness:.9,metalness:0});
    const armor=new THREE.MeshStandardMaterial({color:0x30372d,roughness:.68,metalness:.08});
    const rubber=new THREE.MeshStandardMaterial({color:0x171b18,roughness:.76,metalness:.03});
    const metal=new THREE.MeshStandardMaterial({color:0x4c5450,roughness:.38,metalness:.62});
    const tan=new THREE.MeshStandardMaterial({color:0x806d4d,roughness:.86,metalness:.02});
    const glass=new THREE.MeshStandardMaterial({color:0x283b3d,roughness:.2,metalness:.45});

    // Pelvis, jacket and plate carrier form a readable military silhouette from every angle.
    box(5.1,2.6,3.5,cloth,hips,0,.15,0);
    cyl(2.9,3.35,6.3,cloth,torso,0,4.3,0,10);
    box(5.5,4.5,3.75,armor,torso,.05,4.4,0);
    box(3.2,2.2,.55,olive,torso,0,4.1,-2.08);
    for(const z of [-1.35,0,1.35])box(.95,1.55,.72,tan,torso,1.55,3.45,z);
    const neck=new THREE.Group();neck.name="neck";neck.position.set(0,8.25,0);torso.add(neck);
    cyl(.72,.78,1.2,mats.skin,neck,0,0,0,9);
    const head=mesh(new THREE.SphereGeometry(1.9,14,10),mats.skin,neck,0,1.35,0);head.scale.set(.86,1.08,.9);
    const helmet=mesh(new THREE.SphereGeometry(2.18,14,9,0,Math.PI*2,0,Math.PI*.62),olive,neck,0,2.05,0);helmet.scale.y=.72;
    box(2.85,.28,1.15,olive,neck,1.05,2.05,0);
    box(.42,.7,2.75,glass,neck,1.62,1.42,0);
    box(.38,.75,2.35,rubber,neck,1.45,.62,0);

    const joint=(name,parent,x,y,z)=>{const p=new THREE.Group();p.name=name;p.position.set(x,y,z);parent.add(p);return p;};
    const leg=(side)=>{
      const upper=joint(`upper-leg-${side}`,hips,side*1.45,-.55,0);
      cyl(1.02,1.15,4.15,cloth,upper,0,-2.05,0,9);
      box(2.15,1.05,2.35,armor,upper,0,-3.75,0);
      const lower=joint(`lower-leg-${side}`,upper,0,-4.05,0);
      cyl(.82,1.0,3.9,cloth,lower,0,-1.88,0,9);
      box(2.05,2.75,2.65,rubber,lower,.38,-3.55,.28);
      box(3.15,1.15,2.75,rubber,lower,1.05,-4.55,.28);
      return {upper,lower};
    };
    const leftLeg=leg(1),rightLeg=leg(-1);
    const arm=(side)=>{
      const upper=joint(`upper-arm-${side}`,torso,side*3.25,6.65,0);
      mesh(new THREE.SphereGeometry(1.18,9,7),armor,upper,0,-.35,0);
      cyl(.72,.9,3.25,cloth,upper,0,-1.9,0,9);
      const lower=joint(`lower-arm-${side}`,upper,0,-3.45,0);
      cyl(.58,.72,3.05,cloth,lower,0,-1.45,0,9);
      mesh(new THREE.SphereGeometry(.72,9,7),rubber,lower,0,-3.05,0);
      return {upper,lower};
    };
    const leftArm=arm(1),rightArm=arm(-1);

    // Class equipment is attached to the rig, so it follows the character instead of floating.
    const pack=joint("backpack",torso,-2.1,4.15,0);
    const packSize=u.cls==="engineer"?5.1:(u.cls==="at"||u.cls==="sam"?4.5:3.5);
    box(2.35,packSize,4.6,u.cls==="specops"?rubber:olive,pack,0,0,0);
    for(const z of [-2.55,2.55])cyl(.42,.42,packSize*.78,metal,pack,0,0,z,8);
    const weapon=joint("weapon",rightArm.lower,0,-2.55,-1.05);
    weapon.rotation.z=-1.12;weapon.rotation.x=.08;
    const longGun=u.cls==="sniper"||u.cls==="mg"||u.cls==="at"||u.cls==="sam";
    const gunL=longGun?13.4:9.8;
    if(u.cls==="at"||u.cls==="sam"){
      const tube=cyl(1.18,1.42,gunL,u.cls==="sam"?olive:rubber,weapon,gunL/2,0,0,12);tube.rotation.z=Math.PI/2;
      cyl(1.7,1.35,1.8,metal,weapon,gunL-.7,0,0,12).rotation.z=Math.PI/2;
      box(1.2,2.8,1.1,rubber,weapon,2.4,-1.55,0);
    }else if(u.cls==="engineer"){
      const handle=cyl(.25,.3,9,tan,weapon,4.5,0,0,8);handle.rotation.z=Math.PI/2;
      box(2.1,1.35,.55,metal,weapon,9,0,0);
    }else{
      box(gunL,1.0,1.3,metal,weapon,gunL/2,0,0);
      box(3.4,1.65,1.65,rubber,weapon,2.3,-.45,0);
      box(1.25,2.4,1.25,rubber,weapon,2.1,-1.7,0);
      box(2.2,2.2,1.15,metal,weapon,4.4,-1.25,0);
      if(u.cls==="sniper")cyl(.42,.42,3.2,glass,weapon,4.2,1.0,0,10).rotation.z=Math.PI/2;
      if(u.cls==="mg")box(2.6,3.2,1.15,tan,weapon,3.5,-2.2,0);
    }
    leftArm.upper.rotation.z=-.2;rightArm.upper.rotation.z=.2;
    const rig={root,hips,torso,neck,legL:leftLeg.upper,legR:rightLeg.upper,kneeL:leftLeg.lower,kneeR:rightLeg.lower,
      armL:leftArm.upper,armR:rightArm.upper,elbowL:leftArm.lower,elbowR:rightArm.lower,weapon,baseHipY:8.15};
    root.userData.rig=rig;root.userData.cleanCharacter=true;
    return root;
  },

  /* ---------- 單位（真正 3D 幾何與可動節點） ---------- */
  _mkUnit(u, G, preview){
    const g = new THREE.Group();
    const visual = new THREE.Group();
    visual.name = "unit-visual";
    g.add(visual); g.userData.visual = visual;
    const nat = NATIONS[u.nationId];
    const uniform = new THREE.Color(nat.uniformColor);
    const bodyMat = new THREE.MeshLambertMaterial({ color: uniform });
    const darkMat = new THREE.MeshLambertMaterial({ color: 0x23271f });
    const metalMat = new THREE.MeshLambertMaterial({ color: 0x6d726a });
    const steelMat = new THREE.MeshLambertMaterial({ color: 0x8a9099 });
    const add = (mesh, x, y, z) => { mesh.position.set(x, y, z); mesh.castShadow = true; visual.add(mesh); return mesh; };

    // 戰場固定使用可控的真 3D 組裝模型；圖片只保留給部署卡／圖鑑。
    const isInfantry = u.domain === "land" && u.cls !== "tank";
    const loadedVehicle=!isInfantry?this._cloneModel(u.cls,u,preview):null;
    if(loadedVehicle){
      visual.add(loadedVehicle);
      g.userData.modelVariant=u.cls;
      g.userData.modelSource=loadedVehicle.userData.modelSource||null;
      g.userData.assetStatus=loadedVehicle.userData.assetStatus||"provisional";
      g.userData.loadedModel=true;
      const nodes=loadedVehicle.userData.namedNodes||{};
      if(u.cls==="tank"){
        g.userData.turret=nodes.Tank_Turret||null;
        g.userData.trackBones=Object.values(nodes).filter(o=>o&&o.isBone&&/^TankTrack\d+\.[LR]$/.test(o.name));
      }
      if(u.cls==="lst")g.userData.bowRamp=nodes.BowRamp||null;
      if(u.domain==="sea")g.userData.shipTurret=nodes.Ship_Turret||Object.values(nodes).find(o=>o&&!o.isMesh&&/turret|gun_mount|cannon_mount/i.test(o.name))||null;
      if(u.cls==="submarine"&&nodes.Propeller){nodes.Propeller.userData.spinAxis="x";nodes.Propeller.userData.spinSpeed=10;}
      if(u.domain==="air"){
        const modelSurfaces=[nodes.Aileron_L,nodes.Aileron_R].filter(Boolean);
        modelSurfaces.forEach((surface,index)=>surface.userData.side=index===0?-1:1);
        const modelRotors=[nodes.MainRotor,nodes.TailRotor].filter(Boolean);
        if(nodes.MainRotor){nodes.MainRotor.userData.spinAxis="y";nodes.MainRotor.userData.spinSpeed=29;}
        if(nodes.TailRotor){nodes.TailRotor.userData.spinAxis="x";nodes.TailRotor.userData.spinSpeed=38;}
        const airGear=this._airGear(u,modelSurfaces.length>0||modelRotors.length>0);visual.add(airGear);
        g.userData.controlSurfaces=modelSurfaces.length?modelSurfaces:(airGear.userData.controlSurfaces||[]);
      }
      return this._finishUnit(g,visual,u,G,preview);
    }
    g.userData.loadedModel=false;
    g.userData.assetStatus=(MODEL_ASSETS[u.cls]&&MODEL_ASSETS[u.cls].status)||"missing";

    if (u.cls === "tank"){
      add(new THREE.Mesh(new THREE.BoxGeometry(30, 8, 20), bodyMat), 0, 8, 0);            // 車體
      add(new THREE.Mesh(new THREE.BoxGeometry(32, 5, 4), darkMat), 0, 3, -11);            // 履帶
      add(new THREE.Mesh(new THREE.BoxGeometry(32, 5, 4), darkMat), 0, 3, 11);
      const wheels=[];
      for(const z of [-11,11])for(let i=0;i<5;i++){
        const wh=new THREE.Mesh(new THREE.CylinderGeometry(2.5,2.5,1.5,10),metalMat);wh.rotation.x=Math.PI/2;
        wh.position.set(-12+i*6,3,z);wh.castShadow=true;visual.add(wh);wheels.push(wh);
      }
      const turret=new THREE.Group();turret.name="tank-turret";turret.position.set(-1,14.5,0);visual.add(turret);
      const cup=new THREE.Mesh(new THREE.BoxGeometry(13,5.5,12),metalMat);cup.castShadow=true;turret.add(cup);
      const bar=new THREE.Mesh(new THREE.CylinderGeometry(1.1,1.1,24,8),metalMat);bar.rotation.z=-Math.PI/2;bar.position.set(13,0.5,0);bar.castShadow=true;turret.add(bar);
      g.userData.turret=turret;g.userData.wheels=wheels;
    } else if (u.domain === "sea"){
      if (u.cls === "submarine"){
        const hull = new THREE.Mesh(new THREE.CapsuleGeometry ? new THREE.CapsuleGeometry(4.5, 30, 4, 8) : new THREE.CylinderGeometry(4.5, 4.5, 34, 8), steelMat);
        hull.rotation.z = Math.PI / 2; add(hull, 0, 3, 0);
        add(new THREE.Mesh(new THREE.BoxGeometry(6, 7, 3.6), darkMat), 0, 9, 0);           // 帆罩
      } else if (u.cls === "missileboat"){
        // 飛彈快艇：低矮高速船體＋前駕駛艙＋雙聯箱式反艦飛彈，不是縮小版驅逐艦。
        add(new THREE.Mesh(new THREE.BoxGeometry(27, 4.5, 8), steelMat), 0, 3, 0);
        const bow = new THREE.Mesh(new THREE.ConeGeometry(4.05, 8, 4), steelMat);
        bow.rotation.z = -Math.PI / 2; add(bow, 17, 3, 0);
        add(new THREE.Mesh(new THREE.BoxGeometry(8, 5, 6), darkMat), 4, 7.2, 0);            // 低矮駕駛艙
        for (const z of [-2.3, 2.3]){
          const launcher = new THREE.Mesh(new THREE.BoxGeometry(7, 2.4, 1.8), metalMat);
          launcher.rotation.z = -0.16; add(launcher, -4, 8.1, z);                         // 箱式飛彈發射器
        }
        const mast = new THREE.Mesh(new THREE.CylinderGeometry(0.25, 0.35, 6, 6), metalMat);
        add(mast, 3, 12, 0);
      } else if (u.cls === "lst"){
        // 登陸艦：寬大運輸艦體、艦艏門、長飛行甲板與後置艦橋，輪廓刻意避開驅逐艦。
        add(new THREE.Mesh(new THREE.BoxGeometry(42, 7, 14), steelMat), 0, 4, 0);
        add(new THREE.Mesh(new THREE.BoxGeometry(4.5, 5.4, 12), darkMat), 21, 4.2, 0);      // 艦艏登陸門
        const ramp = add(new THREE.Mesh(new THREE.BoxGeometry(7, 0.9, 10), metalMat), 23.5, 1.2, 0);
        ramp.rotation.z = -0.18;                                                           // 收起中的艦艏跳板
        add(new THREE.Mesh(new THREE.BoxGeometry(31, 1.1, 13), bodyMat), -3.5, 8.1, 0);    // 飛行／車輛甲板
        add(new THREE.Mesh(new THREE.BoxGeometry(9, 8, 11), darkMat), -13.5, 12.1, 0);     // 後置艦橋
        add(new THREE.Mesh(new THREE.BoxGeometry(3, 2.2, 4), metalMat), -6, 9.8, 0);       // 甲板設備
        const pad = new THREE.Mesh(new THREE.RingGeometry(3.2, 3.7, 20), new THREE.MeshBasicMaterial({ color: 0xd9d2a8 }));
        pad.rotation.x = -Math.PI / 2; add(pad, 7, 8.72, 0);                               // 直升機甲板標記
      } else {
        const L = 46, W = 13;
        add(new THREE.Mesh(new THREE.BoxGeometry(L, 7, W), steelMat), 0, 3.5, 0);          // 船體
        add(new THREE.Mesh(new THREE.BoxGeometry(L * 0.3, 8, W * 0.66), darkMat), -L * 0.08, 11, 0); // 艦橋
        if (u.cls === "destroyer"){
          const turret=new THREE.Group();turret.name="destroyer-main-turret";turret.position.set(L*.27,9,0);visual.add(turret);
          const cup=new THREE.Mesh(new THREE.CylinderGeometry(3.2,3.7,2.5,8),steelMat);cup.castShadow=true;turret.add(cup);
          const gun=new THREE.Mesh(new THREE.CylinderGeometry(.62,.78,14,8),metalMat);gun.rotation.z=-Math.PI/2;gun.position.set(7,1,0);gun.castShadow=true;turret.add(gun);
          g.userData.shipTurret=turret;
        }
      }
    } else if (u.domain === "air"){
      if (u.cls === "gunship"){
        add(new THREE.Mesh(new THREE.BoxGeometry(16, 6, 6), darkMat), 0, 6, 0);
        add(new THREE.Mesh(new THREE.BoxGeometry(12, 1.4, 1.6), darkMat), -12, 8, 0);      // 尾樑
      } else {
        // 現代固定翼軍機：fighter 細長後掠翼；attacker 粗壯、寬翼、雙發動機莢艙。
        const isFighter = u.cls === "fighter";
        const fusR = isFighter ? 2.15 : 2.85, fusL = isFighter ? 22 : 21;
        const fus = new THREE.Mesh(new THREE.CylinderGeometry(fusR * 0.78, fusR, fusL, 10), steelMat);
        fus.rotation.z = -Math.PI / 2; add(fus, -1, 6, 0);
        const nose = new THREE.Mesh(new THREE.ConeGeometry(fusR, isFighter ? 7 : 5.5, 10), steelMat);
        nose.rotation.z = -Math.PI / 2; add(nose, fusL / 2 + 1.6, 6, 0);
        const cockpit = add(new THREE.Mesh(new THREE.SphereGeometry(isFighter ? 2 : 2.4, 10, 7), darkMat), 3.5, 8, 0);
        cockpit.scale.set(1.55, 0.72, 0.82);
        const wing = (side, span, rootFront, tipBack) => {
          const z0 = side * 1.1, z1 = side * span;
          const geo = new THREE.BufferGeometry();
          geo.setAttribute("position", new THREE.Float32BufferAttribute([
            rootFront,0,z0, tipBack,0,z1, -5,0,z0
          ],3));
          geo.computeVertexNormals();
          const mesh = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color: uniform, roughness:0.62, metalness:0.34, side:THREE.DoubleSide }));
          mesh.position.y = 6; mesh.castShadow = true; visual.add(mesh);
        };
        wing(1, isFighter ? 11 : 13, isFighter ? 4 : 3, isFighter ? -5 : -3);
        wing(-1, isFighter ? 11 : 13, isFighter ? 4 : 3, isFighter ? -5 : -3);
        const controlSurfaces=[];
        for(const side of [-1,1]){
          const pivot=new THREE.Group();pivot.name=`${u.cls}-aileron-${side>0?"R":"L"}`;
          pivot.position.set(-4.8,6,side*(isFighter?6.2:7.4));pivot.userData.side=side;visual.add(pivot);
          const flap=new THREE.Mesh(new THREE.BoxGeometry(3.8,.28,isFighter?3.2:4.1),bodyMat);flap.castShadow=true;pivot.add(flap);controlSurfaces.push(pivot);
        }
        g.userData.controlSurfaces=controlSurfaces;
        if (isFighter){
          add(new THREE.Mesh(new THREE.BoxGeometry(4.5, 4.8, 0.55), bodyMat), -9.5, 8.2, -1.9);
          add(new THREE.Mesh(new THREE.BoxGeometry(4.5, 4.8, 0.55), bodyMat), -9.5, 8.2, 1.9);
        } else {
          add(new THREE.Mesh(new THREE.BoxGeometry(4.8, 5.4, 0.75), bodyMat), -9.5, 8.4, 0);
          for (const z of [-4.5,4.5]){
            const eng = new THREE.Mesh(new THREE.CylinderGeometry(1.45,1.45,6.5,10), darkMat);
            eng.rotation.z = -Math.PI/2; add(eng,-4,7.4,z);
          }
        }
      }
      visual.add(this._airGear(u));
    } else {
      const usePrimitive=typeof location!=="undefined"&&new URLSearchParams(location.search).get("primitiveCharacters")==="1";
      this._ensureModel(u.cls);              // 兵種模型按需載入（載完自動重建單位）
      const soldier=usePrimitive?null:this._cloneModel(u.cls,u,preview);
      if(soldier){
        visual.add(soldier);
        g.userData.characterBones=soldier.userData.characterBones||null;
        g.userData.modelVariant=u.cls;
        g.userData.modelSource=soldier.userData.modelSource||null;
        g.userData.loadedModel=true;
        g.userData.riggedModel=Object.keys(soldier.userData.characterBones||{}).length>0;
        g.userData.assetStatus=soldier.userData.assetStatus||"provisional";
        g.userData.soldierWrap=soldier;
      }else{
        const fallback=this._soldierRig(u,{body:bodyMat,dark:darkMat,metal:metalMat,skin:new THREE.MeshLambertMaterial({color:0xd9b48a})});
        visual.add(fallback);g.userData.rig=fallback.userData.rig;g.userData.riggedModel=false;
        g.userData.assetStatus="procedural-fallback";g.userData.cleanCharacter=false;
      }
      // 兵種專屬裝備剪影（共用基底模型的差異化層，勿再移除）。
      // 例外：selfGear 模型（如 Tripo 專屬角色模型）武器已內建，掛配件會因骨名不符糊在模型上。
      const selfGear = this._defs && this._defs[u.cls] && this._defs[u.cls].selfGear && g.userData.loadedModel;
      if (!selfGear) visual.add(this._classGear(u));
    }
    return this._finishUnit(g, visual, u, G, preview);
  },

  _finishUnit(g, visual, u, G, preview){
    if (preview){ this._linearize(g); return g; }
    // 戰場一律保留真 3D visual；圖片只供部署卡與圖鑑使用。
    const art=null;
    const artUsable=!!(art&&art.validated===true&&art.sprite&&art.sprite.material&&art.sprite.material.map);
    visual.visible=!artUsable;
    if(artUsable){
      g.add(art.sprite);g.userData.artSprite=art.sprite;g.userData.artSize={w:art.w,h:art.h};
      g.userData.artSource=art.source;g.userData.artFallback=art.sprite;
      g.userData.artFallbackSize={w:art.w,h:art.h};g.userData.artFallbackSource=art.source;
      g.userData.videoSprites={};this._videoEntry(u.cls,"move");
    }
    const sm=new THREE.MeshBasicMaterial({color:0x111611,transparent:true,opacity:u.domain==="air"?0.16:0.22,depthWrite:false});
    const shadow=new THREE.Mesh(new THREE.CircleGeometry(1,24),sm);shadow.name=`model-shadow-${u.cls}`;
    shadow.rotation.x=-Math.PI/2;shadow.position.y=u.domain==="air"?-51.6:0.16;
    shadow.scale.set(Math.max(2,artUsable?art.w*.34:u.r*1.05),Math.max(1.4,artUsable?art.w*.095:u.r*.42),1);shadow.renderOrder=1;
    if(u.domain!=="sea"){g.add(shadow);g.userData.modelShadow=shadow;}
    if (u.domain === "sea" && u.cls !== "submarine"){
      const wake = this._shipWake(u);
      g.add(wake); g.userData.wake = wake;
    }
    this._addRing(g, u, G);
    g.userData.rotors = [];
    g.traverse(o => { if (o.userData && o.userData.spinAxis) g.userData.rotors.push(o); });
    g.userData.actionHistory=[];
    g.userData.observedMovement=false;
    g.userData.observedRotorMotion=false;
    this._linearize(g);
    this._toonify(g);
    return g;
  },

  /* 目前真正顯示之模型的螢幕包圍盒。只量 visual，刻意排除選取環與艦尾航跡。 */
  unitScreenBounds(u, cam){
    const g=this._units[u.id], visual=g&&g.userData.visual;
    if (!g || !cam) return null;
    g.updateWorldMatrix(true,true);
    const art=g.userData.artSprite;
    if (art && art.visible){
      const box=new THREE.Box3().setFromObject(art),xs=[box.min.x,box.max.x],ys=[box.min.y,box.max.y],zs=[box.min.z,box.max.z];
      let left=Infinity,top=Infinity,right=-Infinity,bottom=-Infinity,depth=Infinity,n=0;
      for(const x of xs)for(const y of ys)for(const z of zs){const p=cam.project(x,z,y);if(!p)continue;
        left=Math.min(left,p.sx);right=Math.max(right,p.sx);top=Math.min(top,p.sy);bottom=Math.max(bottom,p.sy);depth=Math.min(depth,p.depth);n++;}
      return n?{left,top,right,bottom,depth}:null;
    }
    if (!visual) return null;
    const box=new THREE.Box3().setFromObject(visual);
    if (box.isEmpty()) return null;
    const xs=[box.min.x,box.max.x], ys=[box.min.y,box.max.y], zs=[box.min.z,box.max.z];
    let left=Infinity,top=Infinity,right=-Infinity,bottom=-Infinity,depth=Infinity,n=0;
    for (const x of xs) for (const y of ys) for (const z of zs){
      const p=cam.project(x,z,y);
      if (!p) continue;
      left=Math.min(left,p.sx); right=Math.max(right,p.sx);
      top=Math.min(top,p.sy); bottom=Math.max(bottom,p.sy);
      depth=Math.min(depth,p.depth); n++;
    }
    return n?{left,top,right,bottom,depth}:null;
  },

  /* 艦尾航跡：root sibling，船體 bob/roll 時仍貼住水面。local -x = 艦尾。 */
  _shipWake(u){
    const wake = new THREE.Group();
    wake.name = `ship-wake-${u.cls}`; wake.visible = false;
    const len0 = u.big ? 28 : 20, spread0 = u.big ? 4.5 : 3;
    for (let i = 0; i < 4; i++){
      const len = len0 + i * 4, opacity = 0.22 - i * 0.035;
      for (const side of [-1,1]){
        const mat = new THREE.MeshBasicMaterial({ color:0xd7f2ff, transparent:true, opacity:0,
          depthWrite:false, side:THREE.DoubleSide, polygonOffset:true, polygonOffsetFactor:-1 });
        const streak = new THREE.Mesh(new THREE.PlaneGeometry(len, 0.7), mat);
        streak.rotation.x = -Math.PI / 2;
        streak.position.set(-u.r - len * 0.48 - i * 2, 0.62, side * (spread0 + i * 1.3));
        streak.userData.maxOpacity = opacity; streak.renderOrder = 3; wake.add(streak);
      }
    }
    const foamMat = new THREE.MeshBasicMaterial({ color:0xe8f8ff, transparent:true, opacity:0,
      depthWrite:false, side:THREE.DoubleSide });
    const foam = new THREE.Mesh(new THREE.PlaneGeometry(8, Math.max(3,u.r * 0.72)), foamMat);
    foam.rotation.x = -Math.PI/2; foam.position.set(-u.r - 3.5,0.64,0);
    foam.userData.maxOpacity = 0.28; foam.renderOrder = 3; wake.add(foam);
    return wake;
  },
  /* ---------- 兵種專屬裝備（掛在士兵模型上，一眼認出兵種） ----------
   * 座標系：+x 前方、y 上、z 右手側。士兵高 19，肩高約 12~14。 */
  _classGear(u){
    const kit = new THREE.Group();
    kit.name = `class-gear-${u.cls}`;
    kit.userData.cls = u.cls;
    // 裝備改用 Standard 材質：布料高粗糙、金屬低粗糙，維持低面數但有清楚材質層次。
    const dark  = new THREE.MeshStandardMaterial({ color: 0x2b2f27, roughness: 0.68, metalness: 0.28 });
    const metal = new THREE.MeshStandardMaterial({ color: 0x596157, roughness: 0.34, metalness: 0.72 });
    const olive = new THREE.MeshStandardMaterial({ color: 0x4a5d3a, roughness: 0.88, metalness: 0.04 });
    const tan   = new THREE.MeshStandardMaterial({ color: 0x8a744e, roughness: 0.82, metalness: 0.03 });
    const red   = new THREE.MeshStandardMaterial({ color: 0xc23b2e, roughness: 0.62, metalness: 0.04 });
    const put = (mesh, x, y, z, rz = 0, rx = 0) => {
      mesh.position.set(x, y, z); mesh.rotation.z = rz; mesh.rotation.x = rx;
      mesh.castShadow = true; kit.add(mesh); return mesh;
    };
    const box = (w, h, d, mat) => new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat);
    const cyl = (r, len, mat, seg = 7) => new THREE.Mesh(new THREE.CylinderGeometry(r, r, len, seg), mat);

    switch (u.cls){
      case "rifleman":   // 步槍兵：制式小背包＋水壺
        put(box(2.6, 4.2, 4.6, olive), -2.6, 11.5, 0);
        put(cyl(0.9, 2.2, tan), -1.8, 7.5, 2.6);
        put(box(1.8, .7, 3.8, olive), -.4, 16.1, 0);                     // 制式頭盔外罩
        break;
      case "assault":    // 突擊兵：胸掛彈匣袋×2＋輕背囊
        put(box(1.4, 2.4, 1.8, dark), 2.4, 11.5, -1.2);
        put(box(1.4, 2.4, 1.8, dark), 2.4, 11.5, 1.2);
        put(box(2.2, 3.4, 4, olive), -2.4, 11, 0);
        put(box(.65, 1.25, 3.5, dark), 1.2, 15.3, 0);                    // 護目鏡
        put(box(1.0, 1.5, 4.4, dark), .2, 9.5, 0);                      // 腰封
        break;
      case "sniper": {   // 狙擊手：背上斜揹超長狙擊槍＋瞄準鏡＋偽裝披肩
        const rifle = put(cyl(0.55, 17, metal), -2.8, 12, 0, 0.95);
        rifle.rotation.y = 0.25;
        put(box(1.1, 1.1, 2, dark), -3.6, 14.5, 0);                       // 瞄準鏡
        const cape = new THREE.Mesh(new THREE.ConeGeometry(4.2, 6.5, 8, 1, true),
          new THREE.MeshLambertMaterial({ color: 0x55663f, side: THREE.DoubleSide }));
        put(cape, -0.6, 11.5, 0);                                          // 吉利披肩
        put(box(2.5, 2.1, 4.2, olive), -.7, 15.2, 0);                    // 偽裝兜帽
        break;
      }
      case "mg":         // 機槍兵：肩扛重機槍（粗長管＋腳架）＋背彈藥箱
        put(cyl(0.95, 13, dark), 3.5, 14, -2, -Math.PI / 2);
        put(box(3.2, 2, 1.6, dark), 0.5, 13.5, -2);                        // 機匣
        put(cyl(0.35, 4.5, metal), 8, 12, -2.8, 0, 0.5);                   // 腳架×2
        put(cyl(0.35, 4.5, metal), 8, 12, -1.2, 0, -0.5);
        put(box(3, 3.4, 5.2, olive), -2.8, 11, 0);                         // 彈藥箱
        for(let i=0;i<6;i++)put(cyl(.18,1.15,tan,6),1.7+i*.38,10.8,-2.45,0,Math.PI/2); // 彈鏈
        break;
      case "at":         // 火箭兵：扛肩火箭筒（喇叭尾口）
        put(cyl(1.6, 14, dark), 0.5, 14.5, -2.4, -Math.PI / 2);
        put(new THREE.Mesh(new THREE.CylinderGeometry(2.3, 1.7, 2.4, 8), dark), -6.5, 14.5, -2.4, -Math.PI / 2);
        put(box(2.4, 3, 3.6, olive), -2.4, 10.5, 1);                       // 備彈袋
        break;
      case "sam": {      // 防空兵：肩射防空飛彈（筒斜指天＋方形導引頭）
        const tube = put(cyl(1.4, 13, olive), 0.5, 15, -2.2, -1.05);
        tube.rotation.y = 0.15;
        put(box(2.6, 2.6, 2.6, dark), 3.5, 19, -2.2);                      // 導引頭
        put(box(1.6, 2.2, 1.2, metal), -0.5, 12, -3.4);                    // 握把電池
        break;
      }
      case "mortar":     // 迫擊砲兵：背負砲管＋圓底板
        put(cyl(1.25, 12, metal), -2.8, 12, 1, 0.55);
        put(new THREE.Mesh(new THREE.CylinderGeometry(3.4, 3.4, 0.7, 10), dark), -3.2, 10.5, -1.6, 0.3, 0.2); // 底板
        put(box(3.8,2.4,4.5,tan),-2.8,7.8,0);                            // 砲彈攜行箱
        break;
      case "engineer":   // 工兵：大工具背包＋鏟子＋修理扳手
        put(box(4.4, 5.4, 5.6, tan), -3, 11.5, 0);
        put(cyl(0.32, 8, new THREE.MeshStandardMaterial({ color: 0x6b4a2e, roughness: 0.9, metalness: 0.02 })), -4.6, 14, 1.6, 0.35); // 鏟柄
        put(box(1.8, 2.4, 0.5, metal), -5.9, 17.5, 2.8);                   // 鏟頭
        put(box(0.6, 3, 0.6, metal), -4.6, 14.5, -2, -0.3);                // 扳手
        break;
      case "specops":    // 特種兵：低視度小包＋通訊天線＋消音管（配合全身暗色）
        put(box(2.2, 3, 3.6, dark), -2.2, 11.5, 0);
        put(cyl(0.16, 6.5, dark), -3, 17, 1.4, 0.18);                      // 天線
        put(box(7.5,1.0,1.35,dark),3.8,12.4,1.8);                        // 短管卡賓槍
        put(cyl(0.5, 4, dark), 9.4, 12.4, 1.8, -Math.PI / 2);             // 消音管
        put(box(1.2,1.15,3.7,dark),1.15,15.2,0);                         // 面罩
        for(const z of [-.7,.7])put(cyl(.32,1.8,metal,8),1.9,16.2,z,0,Math.PI/2); // 夜視鏡
        break;
      case "medic":      // 醫護兵（保留擴充）：紅十字背包
        put(box(3.4, 4.4, 5, new THREE.MeshStandardMaterial({ color: 0xe8e4da, roughness: 0.86, metalness: 0.01 })), -2.8, 11.5, 0);
        put(box(0.8, 2.6, 0.9, red), -4.4, 11.5, 0);
        put(box(0.8, 0.9, 2.6, red), -4.4, 11.5, 0);
        break;
    }
    kit.userData.geometrySignature = `${u.cls}:${kit.children.map(o=>o.geometry&&o.geometry.type||o.type).join("|")}`;
    return kit;
  },

  /* ---------- 空軍專屬掛載（GLB 與幾何體 fallback 共用） ----------
   * 座標系：+x 機首、y 上、z 右翼；掛載刻意略放大，確保遊戲距離仍能辨識。 */
  _airGear(u, modelMechanics=false){
    const kit = new THREE.Group();
    kit.name = `air-gear-${u.cls}`;
    kit.userData.cls = u.cls;
    const metal = new THREE.MeshStandardMaterial({ color: 0x606760, roughness: 0.38, metalness: 0.68 });
    const dark  = new THREE.MeshStandardMaterial({ color: 0x252a27, roughness: 0.64, metalness: 0.32 });
    const olive = new THREE.MeshStandardMaterial({ color: 0x596246, roughness: 0.76, metalness: 0.14 });
    const put = (mesh, x, y, z) => { mesh.position.set(x,y,z); mesh.castShadow=true; kit.add(mesh); return mesh; };
    const missile = (len, radius, mat) => {
      const m = new THREE.Mesh(new THREE.CylinderGeometry(radius, radius * 0.72, len, 8), mat);
      m.rotation.z = -Math.PI / 2; return m;
    };
    kit.userData.controlSurfaces=[];

    if (u.cls === "fighter"){
      for (const z of [-8.2, -5.4, 5.4, 8.2]){
        const m = put(missile(6.2, 0.38, metal), 0.8, 4.5, z);
        const fin = new THREE.Mesh(new THREE.BoxGeometry(1.2, 0.12, 1.35), dark);
        fin.position.set(-2.2, 0, 0); m.add(fin);
      }
      if(!modelMechanics)for(const side of [-1,1]){
        const pivot=new THREE.Group();pivot.name=`fighter-aileron-${side>0?"R":"L"}`;
        pivot.position.set(-5.2,4.7,side*7.2);pivot.userData.side=side;
        const flap=new THREE.Mesh(new THREE.BoxGeometry(4.4,.22,3.0),dark);flap.castShadow=true;pivot.add(flap);
        kit.add(pivot);kit.userData.controlSurfaces.push(pivot);
      }
    } else if (u.cls === "attacker"){
      for (const z of [-8.5, -5.2, 5.2, 8.5]){
        const m = put(missile(7.4, 0.62, olive), -0.4, 4.1, z);
        const fin = new THREE.Mesh(new THREE.BoxGeometry(1.4, 0.18, 1.8), dark);
        fin.position.set(-2.6, 0, 0); m.add(fin);
      }
      for (const z of [-2.7, 2.7]) put(new THREE.Mesh(new THREE.SphereGeometry(1.15, 8, 6), dark), -2.8, 3.7, z);
      if(!modelMechanics)for(const side of [-1,1]){
        const pivot=new THREE.Group();pivot.name=`attacker-aileron-${side>0?"R":"L"}`;
        pivot.position.set(-5.0,4.3,side*8.1);pivot.userData.side=side;
        const flap=new THREE.Mesh(new THREE.BoxGeometry(4.8,.26,3.8),olive);flap.castShadow=true;pivot.add(flap);
        kit.add(pivot);kit.userData.controlSurfaces.push(pivot);
      }
    } else if (u.cls === "gunship"){
      for (const z of [-5.2, 5.2]){
        put(new THREE.Mesh(new THREE.BoxGeometry(6.8, 0.65, 1.1), dark), 0.3, 4.2, z * 0.62); // 短翼掛架
        const pod = put(new THREE.Mesh(new THREE.CylinderGeometry(1.15, 1.15, 4.8, 10), olive), 1.1, 3.2, z);
        pod.rotation.z = -Math.PI / 2;
        const face = new THREE.Mesh(new THREE.CircleGeometry(0.86, 10), dark);
        face.rotation.y = Math.PI / 2; face.position.x = 2.42; pod.add(face);
      }
      if(!modelMechanics){const rotorMat = new THREE.MeshStandardMaterial({ color:0x343936, roughness:0.58, metalness:0.42 });
      const main = new THREE.Group(); main.name = "gunship-main-rotor";
      main.position.set(-0.5,8.8,0); main.userData.spinAxis="y"; main.userData.spinSpeed=29;
      main.add(new THREE.Mesh(new THREE.BoxGeometry(22,0.14,0.5),rotorMat));
      main.add(new THREE.Mesh(new THREE.BoxGeometry(0.5,0.14,22),rotorMat)); kit.add(main);
      const tail = new THREE.Group(); tail.name = "gunship-tail-rotor";
      tail.position.set(-8.5,4.8,-0.9); tail.userData.spinAxis="x"; tail.userData.spinSpeed=38;
      tail.add(new THREE.Mesh(new THREE.BoxGeometry(0.16,5.2,0.38),rotorMat));
      tail.add(new THREE.Mesh(new THREE.BoxGeometry(0.16,0.38,5.2),rotorMat)); kit.add(tail);
      }
    }
    return kit;
  },

  _addRing(g, u, G){
    const col = u.side === G.playerSide ? 0x5b9bff : 0xff6f5a;
    const ring = new THREE.Mesh(new THREE.RingGeometry(u.r + 1, u.r + 3, 20), new THREE.MeshBasicMaterial({ color: col, transparent: true, opacity: 0.85 }));
    ring.rotation.x = -Math.PI / 2; ring.position.y = 0.3; g.add(ring);
    g.userData.ring = ring;
  },

  syncUnits(G, now, dt){
    const seen = {};
    for (const u of G.units){
      let g = this._units[u.id];
      if(!u.alive){
        const mx=this._mixers[u.id];
        if(g&&mx&&mx.actions.death){
          if(!g.userData.deathStarted){
            if(mx.actions[mx.cur])mx.actions[mx.cur].stop();
            this._xfade(mx,"death",0.25);g.userData.deathStarted=true;
            g.userData.actionHistory.push({name:"death",at:Math.round(now)});
            g.userData.deathUntil=now+Math.max(650,(mx.actions.death.getClip().duration||0.8)*1000);
          }
          if(now<(g.userData.deathUntil||0)){g.visible=true;seen[u.id]=1;continue;}
        }
        continue;
      }
      const isP = u.side === G.playerSide;
      const vis = isP || G.enemyVisible(u);
      if (!g){ g = this._units[u.id] = this._mkUnit(u, G); this.scene.add(g); }
      g.visible = vis;
      const alt = u.domain === "air" ? 52 : (u.domain === "sea" ? 0 : this.heightAt(u.x, u.y));
      const hadLast = Number.isFinite(g.userData.lastX), dx = hadLast ? u.x-g.userData.lastX : 0, dy = hadLast ? u.y-g.userData.lastY : 0;
      const dist = Math.hypot(dx,dy), moved = hadLast && dist > 0.01 && dist < 150;
      if(moved)g.userData.observedMovement=true;
      if(moved)g.userData.moveUntil=now+180;
      const activeMove=moved||now<(g.userData.moveUntil||0);
      const tookHit=Number.isFinite(g.userData.lastHp)&&u.hp<g.userData.lastHp;
      if(tookHit)g.userData.hitUntil=now+220;
      // 受擊閃白：材質 emissive 短促打亮（步兵與載具通用；材質清單首次受擊時快取）
      if (tookHit){
        if (!g.userData.flashMats){ const fm=[]; g.traverse(o=>{ if(o.isMesh&&o.material&&o.material.emissive) fm.push(o.material); }); g.userData.flashMats=fm; }
        g.userData.flashUntil = now + 150;
      }
      if (g.userData.flashMats){
        const fl = Math.max(0, ((g.userData.flashUntil||0) - now) / 150);
        const fv = fl > 0 ? 0.85 * fl : 0;
        if (g.userData.flashCur !== fv){
          for (const fmt of g.userData.flashMats) fmt.emissive.setScalar(fv);
          g.userData.flashCur = fv;
        }
      }
      const targetMotion=activeMove?1:0;
      g.userData.motion=(g.userData.motion||0)+(targetMotion-(g.userData.motion||0))*(1-Math.exp(-(moved?14:8)*dt));
      g.userData.activeMove=activeMove;
      g.userData.motionPhase=now*.012+u.id*1.7;
      g.userData.secondaryShoot=now<(g.userData.shootUntil||0);
      g.userData.secondaryHit=now<(g.userData.hitUntil||0);
      g.position.set(u.x, alt, u.y);
      g.rotation.y = -u.facing;
      const visual = g.userData.visual;
      const targetCrouch=u.domain==="land"&&u.cls!=="tank"&&u.crouched?1:0;
      g.userData.crouch=(g.userData.crouch||0)+(targetCrouch-(g.userData.crouch||0))*(1-Math.exp(-12*dt));
      const posture=1-0.32*g.userData.crouch;
      if(visual&&u.domain==="land"&&u.cls!=="tank")visual.scale.y=g.userData.riggedModel?1:posture;
      const rig=g.userData.rig;
      if(rig){
        const motion=g.userData.motion,phase=now*.012+u.id*1.7,step=Math.sin(phase)*.72*motion;
        const shooting=now<(g.userData.shootUntil||0),hit=now<(g.userData.hitUntil||0),cr=g.userData.crouch;
        const aiming=G.sel===u&&!!G.aimTarget&&!activeMove;
        rig.legL.rotation.z=step+cr*.62;rig.legR.rotation.z=-step-cr*.38;
        if(rig.kneeL)rig.kneeL.rotation.z=Math.max(0,-step)*.78+cr*.72;
        if(rig.kneeR)rig.kneeR.rotation.z=Math.max(0,step)*.78+cr*.62;
        const hold=shooting||aiming;
        rig.armL.rotation.z=hold?1.12:-step*.58+cr*.26;
        rig.armR.rotation.z=hold?1.24:step*.58+cr*.3;
        rig.armL.rotation.x=hold?-.34:0;rig.armR.rotation.x=hold?.18:0;
        if(rig.elbowL){rig.elbowL.rotation.z=hold?-.78:.18+Math.max(0,step)*.22;rig.elbowL.rotation.x=hold?.22:0;}
        if(rig.elbowR){rig.elbowR.rotation.z=hold?-.46:.12+Math.max(0,-step)*.18;rig.elbowR.rotation.x=hold?-.12:0;}
        rig.hips.position.y=(rig.baseHipY||7.4)-Math.abs(Math.sin(phase))*motion*.38-cr*2.15;
        rig.torso.scale.y=1+Math.sin(now*.0022+u.id)*.018*(1-motion);
        rig.torso.rotation.z=hit?.22*Math.sin(now*.08):(-cr*.16);
        rig.torso.rotation.x=hold?.08:0;
        rig.neck.rotation.y=Math.sin(now*.0013+u.id)*.12*(1-motion);
      }
      if(g.userData.wheels&&moved)for(const wh of g.userData.wheels)wh.rotation.y-=dist*.12;
      if(g.userData.turret){
        let want=0;
        if(G.sel===u&&G.aimTarget)want=-(Math.atan2(G.aimTarget.y-u.y,G.aimTarget.x-u.x)-u.facing);
        g.userData.turret.rotation.y+=(want-g.userData.turret.rotation.y)*(1-Math.exp(-6*dt));
      }
      if(g.userData.shipTurret){
        let want=0;
        if(G.sel===u&&G.aimTarget)want=-(Math.atan2(G.aimTarget.y-u.y,G.aimTarget.x-u.x)-u.facing);
        g.userData.shipTurret.rotation.y+=(want-g.userData.shipTurret.rotation.y)*(1-Math.exp(-4*dt));
      }
      if(g.userData.bowRamp){
        const want=now<(u.unloadingUntil||0)?-1.24:0,before=g.userData.bowRamp.rotation.z;
        g.userData.bowRamp.rotation.z+=(want-g.userData.bowRamp.rotation.z)*(1-Math.exp(-5*dt));
        if(Math.abs(g.userData.bowRamp.rotation.z-before)>0.0001)g.userData.observedRampMotion=true;
      }
      let airBob=0;
      if (visual && u.domain === "air"){
        const prevF = g.userData.lastFacing;
        const turnRate = Number.isFinite(prevF) && dt > 0 ? Math.atan2(Math.sin(u.facing-prevF),Math.cos(u.facing-prevF))/dt : 0;
        const targetBank = clamp(-turnRate * 0.12, -0.32, 0.32), ease = 1-Math.exp(-8*dt);
        g.userData.bank = (g.userData.bank||0) + (targetBank-(g.userData.bank||0))*ease;
        visual.rotation.x = g.userData.bank;
        for(const surface of (g.userData.controlSurfaces||[]))surface.rotation.x+=(surface.userData.side*targetBank*.7-surface.rotation.x)*ease;
        const amp = u.cls === "gunship" ? 1.05 : u.cls === "attacker" ? 0.68 : 0.56;
        airBob = Math.sin(now*0.0017 + u.id*1.73) * amp; visual.position.y = airBob;
      }
      if(visual&&u.domain==="sea"){
        visual.position.y=Math.sin(now*.0021+u.id)*.28;
        visual.rotation.x=Math.sin(now*.0017+u.id*.7)*.022;
      }
      const videoState=now<(g.userData.hitUntil||0)?"hit":now<(g.userData.shootUntil||0)?"attack":activeMove?"move":"idle";
      this._syncUnitVideoArt(g,u,videoState,now);
      const art=g.userData.artSprite, artSize=g.userData.artSize;
      if (art && artSize){
        art.rotation.y=u.facing-Math.PI/2-Camera3D.yaw; // root 已旋轉 -facing；抵銷後讓影片平面正面朝相機
        art.rotation.z=u.domain==="air"?(g.userData.bank||0):0;
        if(Number.isFinite(g.userData.lastHp) && u.hp<g.userData.lastHp) g.userData.artHitUntil=now+160;
        art.material.color.setHex(now<(g.userData.artHitUntil||0)?0xffa58f:0xffffff);
        const z=u.domain==="air"?52:alt+(art.userData.baseY||0);
        const p0=Camera3D.project(u.x,u.y,z),p1=Camera3D.project(u.x+Math.cos(u.facing)*10,u.y+Math.sin(u.facing)*10,z);
        const screenDx=p0&&p1?p1.sx-p0.sx:0;
        if(!g.userData.artFlip)g.userData.artFlip=screenDx>0?-1:1;
        if(Math.abs(screenDx)>0.6)g.userData.artFlip=screenDx>0?-1:1;
        const minPx=(u.domain==="land"?(u.cls==="tank"?13:14):12)+(G.sel===u?2:0);
        const targetLod=clamp(minPx/(artSize.h*Math.max(0.001,p0?p0.scale:1)),1,2.2);
        if(!Number.isFinite(g.userData.artLod))g.userData.artLod=targetLod;
        else g.userData.artLod+=(targetLod-g.userData.artLod)*(1-Math.exp(-9*dt));
        const lod=g.userData.artLod;
        const artPosture=u.domain==="land"&&u.cls!=="tank"?posture:1;
        art.scale.set(artSize.w*lod*g.userData.artFlip,artSize.h*lod*artPosture,1);
        art.position.y=(art.userData.baseY||0)*lod*artPosture;
      }
      if(g.userData.modelShadow&&u.domain==="air")g.userData.modelShadow.position.y=this.heightAt(u.x,u.y)-alt+0.16;
      if (g.userData.wake){
        const target = moved ? 1 : 0, rate = moved ? 12 : 3.2;
        g.userData.wakeLevel = (g.userData.wakeLevel||0) + (target-(g.userData.wakeLevel||0))*(1-Math.exp(-rate*dt));
        const level = g.userData.wakeLevel; g.userData.wake.visible = level > 0.015;
        g.userData.wake.traverse(o => { if (o.material && o.userData.maxOpacity) o.material.opacity=o.userData.maxOpacity*level; });
      }
      for (const rotor of (g.userData.rotors||[])){
        const axis=rotor.userData.spinAxis, before=rotor.rotation[axis];
        rotor.rotation[axis] += (rotor.userData.spinSpeed||28)*dt;
        if(Math.abs(rotor.rotation[axis]-before)>0.0001)g.userData.observedRotorMotion=true;
      }
      g.userData.lastX=u.x; g.userData.lastY=u.y; g.userData.lastFacing=u.facing;g.userData.lastHp=u.hp;
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
      // 蹲伏替代姿態：專屬模型無 crouch 片段時，以前傾+下沉近似（絕對值賦值，遵守 GDD/10 鐵則）
      const sw = g.userData.soldierWrap;
      if (sw && this._mixers[u.id] && !this._mixers[u.id].actions.crouch){
        const ck = u.crouched ? 1 : 0;
        sw.rotation.x = 0.16 * ck;
        sw.position.y = -2.0 * ck;
      }
      // 真骨架狀態：移動／蹲伏／瞄準／待機，受擊與射擊為一次性動作。
      const mx = this._mixers[u.id];
      if(tookHit&&mx&&mx.actions.hit&&mx.cur!=="shoot"){
        this._xfade(mx,"hit",0.12);
        g.userData.actionHistory.push({name:"hit",at:Math.round(now)});
      }
      // 勝利姿勢：戰鬥結束時勝方步兵揮手歡呼（有 wave 片段才播）
      if (G.over && mx && mx.actions.wave && u.side === G.over.winner && mx.cur !== "wave" && mx.cur !== "death"){
        this._xfade(mx,"wave",0.3);
      }
      if (mx && mx.actions.walk && mx.cur !== "shoot" && mx.cur !== "hit" && mx.cur!=="death" && mx.cur!=="wave"){
        const locomotion=mx.actions.run&&(g.userData.motion||0)>.72?"run":"walk";
        const want=activeMove?locomotion:u.crouched&&mx.actions.crouch?"crouch":
          (G.sel===u&&G.aimTarget&&mx.actions.aim?"aim":"idle");
        if (want !== mx.cur && mx.actions[want]){
          this._xfade(mx, want, 0.22);mx.actions[want].paused=want==="idle"&&mx.staticIdle;
          g.userData.actionHistory.push({name:want,at:Math.round(now)});
          if(g.userData.actionHistory.length>24)g.userData.actionHistory.shift();
        }
      }
      seen[u.id] = 1;
    }
    for (const id in this._units){
      if (!seen[id]){ this.scene.remove(this._units[id]); delete this._units[id];
        if (this._mixers[id]){ delete this._mixers[id]; } }
    }
  },

  /* ---------- 3D 特效（曳光/爆炸/槍口閃光，資料仍是 Game.fx） ---------- */
  _fxMap: new Map(),
  syncFx(G){
    const seen = new Set();
    for (const f of G.fx){
      if (f.type !== "tracer" && f.type !== "boom" &&
          f.type !== "hitfx" && f.type !== "death") continue;   // 文字類仍走 2D
      if (f.type === "hitfx" && f.heal) continue;               // 治療只顯示 2D 綠字
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
    } else if (f.type === "hitfx"){                             // 命中：彈著塵土揚起
      const hb = this.heightAt(f.x, f.y) + 2;
      for (let i = 0; i < 3; i++){
        const puff = new THREE.Mesh(new THREE.SphereGeometry(1.6 + Math.random(), 7, 6),
          new THREE.MeshBasicMaterial({ color: 0x9c8a6a, transparent: true, opacity: 0.55 }));
        puff.position.set(f.x + (Math.random() * 8 - 4), hb + Math.random() * 3, f.y + (Math.random() * 8 - 4));
        puff.userData.rise = 5 + Math.random() * 7;
        objs.push(puff);
      }
      const spark = new THREE.PointLight(0xffd070, 1.4, 55);    // 命中火花
      spark.position.set(f.x, hb + 8, f.y); objs.push(spark);
      for (let i = 0; i < 6; i++){                              // 飛濺火星（拋物線＋加法混色）
        const sp = new THREE.Mesh(new THREE.SphereGeometry(0.55, 4, 3),
          new THREE.MeshBasicMaterial({ color: 0xffd070, transparent: true, blending: THREE.AdditiveBlending }));
        sp.position.set(f.x, hb + 9, f.y);
        const a = Math.random() * Math.PI * 2, v = 26 + Math.random() * 30;
        sp.userData.vel = new THREE.Vector3(Math.cos(a) * v, 18 + Math.random() * 26, Math.sin(a) * v);
        sp.userData.spark = true; objs.push(sp);
      }
    } else if (f.type === "death"){                             // 死亡：黑煙柱（載具更大＋餘燼火光）
      const hb = this.heightAt(f.x, f.y) + 3;
      const n = f.vehicle ? 5 : 3, base = f.vehicle ? 4.5 : 2.2;
      for (let i = 0; i < n; i++){
        const smoke = new THREE.Mesh(new THREE.SphereGeometry(base * (0.7 + Math.random() * 0.6), 7, 6),
          new THREE.MeshBasicMaterial({ color: f.vehicle ? 0x2a2a2a : 0x4a4a44, transparent: true, opacity: 0.6 }));
        smoke.position.set(f.x + (Math.random() * 10 - 5), hb + Math.random() * 6, f.y + (Math.random() * 10 - 5));
        smoke.userData.rise = (f.vehicle ? 16 : 9) + Math.random() * 8;
        objs.push(smoke);
      }
      const ember = new THREE.PointLight(0xff6a28, f.vehicle ? 3.2 : 1.2, f.vehicle ? 180 : 70);
      ember.position.set(f.x, hb + 6, f.y); objs.push(ember);
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
    } else if (f.type === "hitfx" || f.type === "death"){
      const k = Math.min(1, f.t / 0.9);
      for (const o of e.objs){
        if (o.isPointLight){ o.intensity *= 0.9; continue; }                 // 火光快速熄滅
        if (o.userData.spark){                                               // 火星：拋物線飛濺急滅
          o.userData.vel.y -= 90 * 0.016;
          o.position.addScaledVector(o.userData.vel, 0.016);
          o.material.opacity = Math.max(0, 1 - f.t / 0.4);
          continue;
        }
        o.position.y += o.userData.rise * 0.016;                             // 煙塵上飄
        o.scale.setScalar(1 + k * (f.type === "death" ? 2.2 : 1.4));         // 擴散
        o.material.opacity = Math.max(0, (f.type === "death" ? 0.6 : 0.55) * (1 - k));
      }
    } else {
      const k = f.t / 0.5, r = (f.r || 20) * (0.35 + k * 1.1);
      e.objs[0].scale.setScalar(r);
      e.objs[0].material.opacity = Math.max(0, 1 - k);
      e.objs[1].intensity = 4 * Math.max(0, 1 - k);
    }
  },
  /* 開火者若有 shoot 動畫片段 → 播一次再回原動作 */
  _tryShootAnim(x, y){
    let nearest=null,best=25;
    for(const id in this._units){const g=this._units[id],d=g?Math.hypot(g.position.x-x,g.position.z-y):Infinity;if(d<best){best=d;nearest=g;}}
    if(nearest)nearest.userData.shootUntil=performance.now()+320;
    for (const id in this._mixers){
      const g = this._units[id];
      if (!g || Math.hypot(g.position.x - x, g.position.z - y) > 25) continue;
      const mx = this._mixers[id];
      if (!mx.actions.shoot){
        const m = this._models[mx.modelKey];
        const clip = m && m.anims.find(a => /shoot|fire|attack|gun/i.test(a.name));
        if (!clip) break;
        mx.actions.shoot = mx.mixer.clipAction(clip);
        mx.actions.shoot.setLoop(THREE.LoopOnce); mx.actions.shoot.clampWhenFinished = false;
        mx.mixer.addEventListener("finished", () => { if (mx.cur !== "shoot") return; Engine3D._xfade(mx, "idle", 0.18); });
      }
      this._xfade(mx, "shoot", 0.1);
      g.userData.observedShoot=true;
      g.userData.actionHistory.push({name:"shoot",at:Math.round(performance.now())});
      break;
    }
  },

  /* GLB clip 之上的小幅次級動作：補足呼吸、落腳重心、負重與後座。
   * mixer 每幀先寫入正式骨架 clip，本函式再做微量 additive，不改原始動畫資產。 */
  /* 次級動作鐵則：骨骼由 AnimationMixer 全權驅動，禁止在骨骼上做 +=/*= 疊加——
   * 動畫未覆蓋的通道（如 scale）不會被 mixer 歸位，每幀疊加＝頭變長/姿勢歪斜（殭屍 bug 前科）。
   * 這裡只准對「非骨骼掛件」做絕對值(=)賦值。 */
  _applyCharacterSecondary(G, now){
    for(const u of G.units){
      const g=this._units[u.id];
      if(!g||u.domain!=="land"||u.cls==="tank")continue;
      const move=g.userData.motion||0,phase=g.userData.motionPhase||0;
      const heavy={mg:.58,mortar:.62,at:.68,sam:.66,engineer:.76}[u.cls]||1;
      const stride=Math.sin(phase),landing=Math.abs(Math.sin(phase));
      const gear=g.userData.classGear;
      if(gear){gear.position.y=-landing*.16*move*heavy;gear.rotation.z=-stride*.012*move*heavy;}
    }
  },

  _publishQA(G){
    if(typeof window==="undefined")return;
    const units=[];
    for(const u of G.units){
      const g=this._units[u.id],mx=this._mixers[u.id];let meshCount=0,skinnedMeshes=0;
      if(g)g.traverse(o=>{if(o.isMesh)meshCount++;if(o.isSkinnedMesh)skinnedMeshes++;});
      units.push({id:u.id,cls:u.cls,alive:u.alive,visible:!!(g&&g.visible),
        loadedModel:!!(g&&g.userData.loadedModel),modelVariant:g&&g.userData.modelVariant||null,
        modelSource:g&&g.userData.modelSource||null,assetStatus:g&&g.userData.assetStatus||null,
        meshCount,skinnedMeshes,rotors:g&&g.userData.rotors?g.userData.rotors.length:0,
        rotorAngles:g&&g.userData.rotors?g.userData.rotors.map(r=>Number(r.rotation[r.userData.spinAxis].toFixed(4))):[],
        observedMovement:!!(g&&g.userData.observedMovement),observedShoot:!!(g&&g.userData.observedShoot),
        observedRotorMotion:!!(g&&g.userData.observedRotorMotion),
        actionHistory:g&&g.userData.actionHistory?g.userData.actionHistory.slice(-12):[],
        mechanics:g?{motion:Number((g.userData.motion||0).toFixed(4)),activeMove:!!g.userData.activeMove,
          turretYaw:(g.userData.turret||g.userData.shipTurret)?Number((g.userData.turret||g.userData.shipTurret).rotation.y.toFixed(4)):null,
          controlSurfaceAngles:(g.userData.controlSurfaces||[]).map(s=>Number(s.rotation.x.toFixed(4))),
          wakeLevel:g.userData.wake?Number((g.userData.wakeLevel||0).toFixed(4)):null,
          bowRampAngle:g.userData.bowRamp?Number(g.userData.bowRamp.rotation.z.toFixed(4)):null,
          observedRampMotion:!!g.userData.observedRampMotion,cargoCount:(u.carried||[]).length}:null,
        animation:mx?{current:mx.cur,actions:Object.fromEntries(Object.entries(mx.actions).map(([k,a])=>[k,a&&a.getClip?a.getClip().name:null]))}:null});
    }
    const snapshot={engine3d:this.ok,modelState:{...this._modelState},units,
      fog:{visible:Fog.visible.size,explored:Fog.explored.size,cols:Fog._cols,rows:Fog._rows},timestamp:Date.now()};
    window.BATTLEFIELD_QA=snapshot;
    document.documentElement.setAttribute("data-battlefield-qa",JSON.stringify(snapshot));
  },

  /* ---------- 每幀渲染（相機同步自 Camera3D） ---------- */
  render(G){
    if (!this.ok) return;
    if (this._mapRef !== G.map){ this.buildMap(G); this._mapRef = G.map; }
    const now = performance.now(), dt = Math.min(0.05, (now - (this._at || now)) / 1000); this._at = now;
    this.syncUnits(G, now, dt);
    this.syncFx(G);
    // 動畫推進
    for (const id in this._mixers) this._mixers[id].mixer.update(dt);
    // 雨滴下落（循環盒跟隨相機注視點）
    if (this._rain){
      const p = this._rain.geometry.attributes.position, tgt = Camera3D.target || { x: 480, y: 300 };
      this._rain.position.set(tgt.x, 0, tgt.y);
      for (let i = 1; i < p.array.length; i += 3){
        p.array[i] -= 240 * dt;
        if (p.array[i] < 0) p.array[i] += 380;
      }
      p.needsUpdate = true;
    }
    this._applyCharacterSecondary(G,now);
    this._publishQA(G);
    const cam = Camera3D;
    this.camera.fov = 2 * Math.atan(300 / cam.focal) * 180 / Math.PI;
    this.camera.updateProjectionMatrix();
    this.camera.position.set(cam.cx, cam.ch, cam.cy);
    const cp = Math.cos(cam.pitch);
    this.camera.lookAt(cam.cx + Math.cos(cam.yaw) * cp, cam.ch - Math.sin(cam.pitch), cam.cy + Math.sin(cam.yaw) * cp);
    this.renderer.render(this.scene, this.camera);
    if (this.outlineOn !== false) this._renderOutline();   // 鉛筆速寫描邊（過慢時可設 false 關閉）
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
      const grp=this._units[u.id],art=grp&&grp.userData.artSprite,artSize=grp&&grp.userData.artSize;
      const figH = u.cls === "tank" ? 18 : u.domain === "sea" ? 14 : u.domain === "air" ? 12 : 22;
      const centerH=art&&artSize?art.position.y+Math.abs(art.scale.y)*.5:figH*.5;
      const topH=art&&artSize?art.position.y+Math.abs(art.scale.y):figH;
      const top = cam.project(u.x, u.y, alt + topH + 4);
      if (!top) continue;
      const bw = art&&artSize?Math.max(14,Math.min(46,Math.abs(art.scale.x)*top.scale*0.72)):
        Math.max(14, (u.cls === "tank" ? 30 : 20) * top.scale * 0.5), bx = top.sx - bw / 2, y0 = top.sy - 5;
      ctx.fillStyle = "#222"; ctx.fillRect(bx, y0, bw, 3);
      ctx.fillStyle = isP ? (u.hp > u.maxhp * 0.3 ? "#4fd05e" : "#e04b3a") : "#e53935";
      ctx.fillRect(bx, y0, bw * clamp(u.hp / u.maxhp, 0, 1), 3);
      if(u.crouched){ctx.fillStyle="#f1d46a";ctx.font="bold 10px sans-serif";ctx.textAlign="center";ctx.fillText("掩",top.sx,y0-3);}
      if (G.sel === u){ ctx.strokeStyle = "#ffd83d"; ctx.lineWidth = 2; ctx.strokeRect(bx - 1, y0 - 1, bw + 2, 5); }
      if (G.aimTarget === u){ const mid = cam.project(u.x, u.y, alt + centerH);
        if (mid){ ctx.strokeStyle = "#ff5a4a"; ctx.lineWidth = 2; ctx.beginPath(); ctx.arc(mid.sx, mid.sy, Math.max(10, 16 * mid.scale), 0, 7); ctx.stroke(); } }
    }
    for (const f of G.fx){ if (f.type === "tracer" || f.type === "boom") continue; Render3D._fx(ctx, cam, f); } // 曳光/爆炸已 3D 化
    if (cam.mode === "follow") Render3D._crosshair(ctx, cam.W, cam.H, cam.horizonY());
    this._paperGrade(ctx, cam.W, cam.H);
  },

  /* 手繪紙質後製（真3D 版）：邊角壓暗＋紙紋顆粒＋暖色水彩罩染。
   * 美術方向唯一權威：本作走「水彩手繪風」而非寫實風（GDD/06），低模在此風格下才成立。 */
  _paperGrade(ctx, W, H){
    const vig = ctx.createRadialGradient(W / 2, H * 0.52, H * 0.42, W / 2, H * 0.52, H * 0.95);
    vig.addColorStop(0, "rgba(0,0,0,0)"); vig.addColorStop(1, "rgba(20,14,6,0.28)");
    ctx.fillStyle = vig; ctx.fillRect(0, 0, W, H);
    if (!this._grainPat){
      const g = document.createElement("canvas"); g.width = g.height = 96;
      const gc = g.getContext("2d"), im = gc.createImageData(96, 96);
      let s = 54321; const rn = () => ((s = s * 16807 % 2147483647) / 2147483647);
      for (let i = 0; i < im.data.length; i += 4){ const v = 118 + rn() * 20 | 0; im.data[i] = im.data[i + 1] = im.data[i + 2] = v; im.data[i + 3] = 255; }
      gc.putImageData(im, 0, 0);
      this._grainPat = ctx.createPattern(g, "repeat");
    }
    ctx.save(); ctx.globalAlpha = 0.14; ctx.globalCompositeOperation = "overlay";
    ctx.fillStyle = this._grainPat; ctx.fillRect(0, 0, W, H); ctx.restore();
    ctx.save(); ctx.globalAlpha = 0.055; ctx.fillStyle = "#e8d9b0"; ctx.fillRect(0, 0, W, H); ctx.restore();
  }
};
