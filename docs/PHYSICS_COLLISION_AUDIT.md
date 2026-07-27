# 物理／碰撞／角色控制稽核報告

日期：2026-07-27　　稽核對象：`godot/`（《戰場》Godot 版）

---

## ⚠ 前提修正：本專案沒有使用 Godot 的物理引擎

稽核清單是照「標準 Godot 物理專案」寫的（CharacterBody3D／RigidBody3D／CollisionShape3D／
collision layer／move_and_slide）。**這些在本專案一個都不存在。** 實際查證：

```
$ grep -rl CharacterBody3D RigidBody3D StaticBody3D CollisionShape3D Area3D \
        move_and_slide move_and_collide _integrate_forces apply_impulse apply_force \
        linear_velocity collision_layer collision_mask AnimationTree _physics_process \
        scripts/ scenes/ project.godot
（全部零筆命中）
```

- 16 個 `.tscn` 的根節點型別統計：`Node3D ×15`、`Node2D ×1`。**沒有任何 PhysicsBody3D。**
- `project.godot` **沒有 `[physics]` 區段**（用引擎預設值，但因為沒有物理體，這些設定不生效）。
- 唯一命中的 `root_motion` 是 `Unit._strip_root_motion()`，用途是**關掉** root motion
  （把位移從動畫抽走，改由程式驅動）——也就是清單第四項擔心的「Root Motion 與程式移動並存」
  **已經被明確處理過了，只有一套**。
- Autoload 只有兩個：`GameData`、`Audio`，都不碰移動。

因此下列項目在本專案 **不適用（N/A）**，不是「沒查」而是「不存在」：
collision layer/mask 對照表、Hitbox/Hurtbox 分層、RigidBody3D 質量與推力、
continuous_cd、restitution/friction、move_and_slide 呼叫順序、`_integrate_forces`、
凹面網格用於動態物件、物理 tick 與 delta 重複相乘。

**碰撞層標準文件（`COLLISION_LAYER_STANDARD.md`）也因此改寫成本專案真正的等價物**：
障礙分類與三套判定的對照表。硬套 Godot layer 會是憑空發明一套沒人用的規格。

---

## 1. 專案基本資料

| 項目 | 值 |
|---|---|
| Godot 版本 | 4.7.1 stable（`config/features=PackedStringArray("4.7")`） |
| 渲染 | `forward_plus`（web 為 `gl_compatibility`） |
| 主場景 | `res://scenes/Main.tscn`（根節點 `Node3D`） |
| 主控制腳本 | `scripts/Main.gd`（4244 行，戰場主控＋驗收台） |
| 角色腳本 | `scripts/Unit.gd`（1470 行，`extends Node3D`） |
| 物理引擎 | **未使用**（自寫俯視 2D 解算） |

## 2. 實際的角色移動資料流

```
玩家輸入 (Main._tps_control, _process)
        ↓  方向向量
Unit.move_dir(dir, delta)  ──→ global_position += dir * 速度 * delta
        ↑                        （速度＝WALK_SPEED × 蹲行/匍匐/涉水倍率）
點擊移動 Unit.move_to(p) ──→ Unit._process 內朝 _move_target 逼近

每幀（Main._process）：
  Main._solid_bodies()
     ├─ _resolve_solids(pos, r)   ← 牆推出＋障礙圓/線段推出＋載具推出
     └─ 步兵兩兩對稱推開
  Unit._stick_to_ground(delta)
     ├─ 腳下高度 = Main._ground_height()  ← 地形 ∪ 建築樓板 ∪ 矮障礙頂面
     ├─ 離地 → 自由落體 9.81 m/s²
     └─ 地面在腳上方 → 以 CLIMB_SPEED 2.4 m/s 抬起
  Unit._tilt_to_slope(delta)      ← 身體軸隨坡面傾斜（站/蹲/趴）
  Main._clamp_to_map()            ← 夾回地圖範圍
```

**只有一套主路徑**，這點是好的。移動全部在 `_process(delta)`（不是 `_physics_process`）——
因為沒有物理引擎，沒有固定 tick 可搭，這是自洽的選擇，但代價見問題 M-1。

## 3. 所有會直接寫座標的位置（本專案的等價於「直接改 Transform」）

| 位置 | 用途 | 是否經過碰撞解算 |
|---|---|---|
| `Unit.move_dir()` | 第三人稱/鍵盤移動 | ✅ 下一幀 `_solid_bodies` 修正 |
| `Unit._process` 的 `_move_target` 逼近 | 點擊移動、AI 移動 | ✅ 同上 |
| `Unit._stick_to_ground()` | 只改 y | ✅（y 由支撐面決定） |
| `Main._solid_bodies()` | 碰撞修正本身 | — |
| `Main._clamp_to_map()` | 邊界夾限 | — |
| `Main` 部署／生成 | 出生點 | ✅ 生成時也跑 `_resolve_solids` |
| **驗收台（`-- selftest` 內）** | 把測試單位瞬移到測試點 | ❌ 刻意，僅測試路徑 |

> 沒有發現「繞過碰撞的衝刺／擊退／爬坡」路徑。衝刺只是 `speed_mul`，一樣走同一條解算。

## 4. 這次稽核發現並修正的問題

| 級別 | 問題 | 根因 | 修正 |
|---|---|---|---|
| **Critical** | 步兵不擋彈道／不擋視線 | `_shot_clear` 掃單位時只算載具 | 步兵納入，依姿勢高度（站 1.75／蹲 1.22／趴 0.55） |
| **Critical** | 深水圍欄**從來沒生效過** | `_build_water()` 把圍欄塞進 `_blockers`，但它跑在 `_blockers = []`（重建清空）**之前**，整批被清掉 | 改存 `_water_blk`，在清空之後才併入 |
| **Critical** | 樓板不是實體 | `ground_sampler` 只問地形 | 新增 `Building.floor_at()`＋`Main._ground_height()`；樓梯做成連續斜面 |
| **High** | 畫出來的散落沙包沒有碰撞 | `Fortify` 只登記主牆中線 | 散落袋登記為矮障礙 |
| **High** | 沒有任何東西有「頂面」 | 障礙只有水平推擠 | 新增 `STEP_UP = 0.5m` 通則：矮的給頂面支撐，高的水平擋 |
| **High** | 趴姿不隨坡面傾斜 | `_tilt_to_slope` 遇 prone 直接歸零 | 開放趴姿，取樣基線加長到 0.95m（身體長度） |
| **High** | 可涉水區完全沒有物理 | `waters/shallows` 只有視覺 | `Terrain.water_depth()`＋依深度減速＋>0.35m 不能趴 |
| **High** | 手臂與武器在跑動中整條消失 | `ik_two_bone` 在手臂折疊時 `(c-a).normalized()` 為零向量 → `Quaternion(0,dir)` 產生 **NaN** → 骨骼 global pose NaN → 蒙皮塌陷（NaN 不會噴任何錯誤） | 退化情況提前 return＋`_rotate_bone` 拒收非有限四元數 |
| **Medium** | M-1：移動在 `_process` | 沒有物理引擎可搭固定 tick | 未改（自洽；但幀率波動會讓位移量抖動） |
| **Medium** | M-2：`terrain_mobility.json` 沒人讀 | 資料寫好了，程式另外寫死倍率 | 未改（違反鐵律 3，列入待辦） |
| **Low** | L-1：`_ground_height` 取樣成本 | 每幀 5×單位數 | 加空間格網粗剔除 |

### 人物穿牆／穿物件的最可能根因（總結）

**不是牆太薄，也不是速度太快，而是「畫出來的東西」與「登記進碰撞表的東西」是兩份清單。**
本專案的碰撞真相是 `Main._blockers` 這個陣列；任何模組畫了幾何卻沒有 append 進去，
就會變成可以穿過去的貼圖。這次抓到三件都是同一個模式：
沙包主牆（2026-07-26 已修）、散落沙包、深水圍欄。

**第二個根因是碰撞只有水平維度**：`_resolve_solids` 是 2D 的圓／線段推擠，
沒有「頂面」概念，所以矮物件只能選擇「完全擋住」或「完全穿過」，兩種都不真實。

## 5. 不應修改的系統

- **不要改成 Godot 物理引擎**：現有解算與 AP／回合制／視線／彈道緊密耦合
  （`_resolve_solids`、`_shot_clear`、`_los_clear` 共用同一份 `_blockers`），
  換引擎等於重寫戰鬥系統，而且會失去「依姿勢高度判定遮蔽」這個已經做對的設計。
- **不要把步兵互穿改回去**：那是 2026-07-27 才補上的鐵律 0 要求。
- **不要動 `Retarget.gd` 的相對容差**：那是「手臂消失」前一版的修正，寫死常數會回歸。

## 6. 建議修正順序（未做的）

1. `terrain_mobility.json` 接進移動成本（資料已就緒，違反鐵律 3）。
2. `[apchk]`：AP 承諾距離未含地形成本（**等使用者拍板**，會動到移動規則）。
3. 窗戶可以直接走過去（沒有窗台高度）。
4. 二樓的遮蔽仍照平地算。
5. 移動改為固定步長累積（消除幀率對位移的影響）。

## 7. 本次修改檔案清單

```
godot/scripts/Main.gd        彈道納入步兵、_ground_height、STEP_UP、深水圍欄、空間格網、四組新驗證
godot/scripts/Unit.gd        body_top()、涉水、趴姿貼坡、水中不可趴
godot/scripts/Building.gd    floor_at()（樓板＋樓梯斜面）
godot/scripts/Terrain.gd     water_depth()／water_depth_world()／WATER_SURFACE_Y
godot/scripts/Fortify.gd     散落沙包登記為矮障礙
godot/scripts/Retarget.gd    IK 退化保護＋NaN 攔截
GDD/15-物理法則稽核.md        全域物理對照表（A~I 九類）
docs/PHYSICS_COLLISION_AUDIT.md
docs/COLLISION_LAYER_STANDARD.md
docs/PHYSICS_TEST_REPORT.md
```

## 8. 回滾點

修改前 HEAD＝`35bedd2`（乾淨工作區）。回滾：`git reset --hard 35bedd2`。

---

## 2026-07-27 追加：形狀稽核（使用者回報「從戰車後面可以穿到車子中間」）

### 真因分類：**碰撞形狀與畫出來的幾何不一致**

這不是「忘了加碰撞」，而是「加了、但形狀不對」。三種變形：

| 症狀 | 例子 | 舊登記 | 實際幾何 | 可穿入 |
|------|------|--------|----------|--------|
| 長條形用圓形 | 坦克 | 圓 r=1.6m | 3.1×6.0m 盒 | 車頭／車尾各 1.4m |
| 長條形用圓形 | 卡車殘骸 | 圓 r=1.5m | 4.6×2.1m 盒 | 車頭／車尾各 0.8m |
| 畫了完全沒登記 | 室內翻倒的桌子 | 無 | 1.12m 高擋板 | 整件 |
| 畫了完全沒登記 | 巨石 sc ≤ 0.7 | 無（門檻擋掉） | 半徑可達 0.98m | 整顆 |
| 登記高度與畫的不符 | 疊兩層的木箱 | h=0.42m | 頂端 0.9m | 踩在半空／上層插進身體 |

### 修法

1. `_blockers` 新增第三種形狀 **`obb`**（有向矩形），並把所有掃 `_blockers` 的迴圈
   收斂到四支共用函式：`_blk_closest` / `_blk_inside` / `_blk_aabb` / `_blk_push` / `_blk_ray_t`。
   **往後新增形狀只要改這五支**；先前每個迴圈各寫一次 `if bk["t"] == "cir"`，
   新增形狀時漏掉任何一處，症狀都是「畫得出來但穿得過去」而且沒有任何錯誤訊息。
2. 載具改用 `_vehicle_obb()`（隨車身朝向即時計算，因為車會開、砲塔會轉），
   同時套用在**擋人**（`_resolve_solids`）與**擋彈**（`_shot_clear`）。
3. `_resolve_solids` 改跑兩輪：被 A 推開後可能正好推進 B 裡（車體與牆之間、兩道柵欄的夾角）。
4. 載具貼地：`_ground_normal` 的取樣尺度改成隨物體尺寸（步兵 0.35m／趴姿 0.95m／
   **載具 2.1m**），車身高度取「車心」與「四角平均」的較高者。
   舊版拿腳掌尺度去問一台 6m 長的坦克「腳下是什麼坡」，量到的是地形雜訊，車頭因此插進土裡。

### 驗收（兩端都要驗）

- `res://scenes/ObbProbe.tscn`：18 條純幾何斷言，3 秒跑完，不必等 `-- play` 的 9 分鐘。
- `-- play` 的〔撞戰車〕改成**四個方向**（車尾／車頭／左側／右側）都走一次，
  判準從「離車心距離」改成**換算到車體座標系**看有沒有進到 3.00×1.75 的盒子裡。
  **並且補上限**：走完還離車體 0.8m 以上＝根本沒撞到，判 FAIL（前提不成立的測試等於沒測）。
  舊斷言 `離車心 > 1.44m` 在「人站在車體正中央」時照樣通過——量錯維度＝白驗。
