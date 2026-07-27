# -*- coding: utf-8 -*-
"""
gen-portraits.py — 曙光特遣隊 9 名角色全身立繪生成器（dept-11）
用法：
  python tools/gen-portraits.py --backend pollinations --key <TOKEN> [--only sniper,mg]
  python tools/gen-portraits.py --backend gemini      --key <API_KEY>
  python tools/gen-portraits.py --backend openai      --key <API_KEY> [--base https://api.openai.com/v1 --model gpt-image-1]
輸出：assets/portraits-full/<key>.jpg（832x1216 直式）
風格：水彩動漫全身立繪，鳴潮式軍武時尚。seed 固定，重生同角色請改 SEED_OFFSET。
零依賴：僅用標準庫 urllib。
"""
import argparse, base64, json, os, sys, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "portraits-full")
SEED_OFFSET = 0

STYLE = ("watercolor anime illustration, one single full body character, {desc}, "
         "stylish modern military tactical outfit with fashionable asymmetric details, "
         "dynamic standing pose, clean ivory paper background, soft watercolor washes, "
         "crisp ink lineart, elegant dark-fantasy modern military anime aesthetic, "
         "solo figure only, no text, no letters, no labels, no logo, no annotation panels")

CHARS = {
    "sniper":   (41, "beautiful east asian woman sniper captain, long dark hair with frost white streak, cold elegant expression, holding long anti-materiel sniper rifle"),
    "mg":       (42, "rugged middle aged man machine gunner, grizzled beard, scar over eyebrow, weathered face, carrying heavy light machine gun with ammo belt"),
    "rifleman": (43, "cheerful young male soldier, short black hair, bright optimistic grin, holding assault rifle across chest"),
    "assault":  (44, "energetic young woman assault trooper, fiery red short hair, confident smirk, compact submachine gun, sprinting-ready stance"),
    "at":       (45, "huge muscular man anti-tank gunner, buzz cut, friendly giant vibe, shoulder-carried rocket launcher"),
    "mortar":   (46, "elegant calm woman artillery specialist, ash blonde bun, thin glasses, holding rangefinder, mortar tube beside her, umbrella charm on belt"),
    "engineer": (47, "gentle middle aged man engineer, round glasses, warm teacher smile, tool backpack with wrench and cables, rolled up sleeves"),
    "sam":      (48, "tall watchful woman air-defense trooper, dark skin, goggles pushed up on forehead, shoulder-mounted anti-air missile launcher, looking upward"),
    "specops":  (49, "mysterious silent woman special operations agent, black bob hair, half face mask, dark sleek tactical suit, suppressed carbine, shadow-like presence"),
}

VEH_STYLE = ("watercolor military illustration, single {desc}, dramatic three-quarter view, "
             "clean ivory paper background, soft watercolor washes, crisp ink lineart, "
             "elegant dark-fantasy modern military aesthetic, subject only, no humans, "
             "no text, no letters, no labels, no logo, no annotation panels")

VEHICLES = {
    "tank":        (61, "modern main battle tank, composite armor, low-profile turret, dust around tracks"),
    "destroyer":   (62, "modern guided-missile destroyer warship cutting through waves, phased-array radar mast"),
    "missileboat": (63, "small fast-attack missile boat at speed, anti-ship missile canisters, sea spray"),
    "lst":         (64, "tank landing ship approaching beach, opened bow doors, landing ramp"),
    "submarine":   (65, "attack submarine surfaced on dark water, sail and hydroplanes, wake trail"),
    "fighter":     (66, "multirole jet fighter banking in flight, afterburner glow, condensation trails"),
    "attacker":    (67, "ground-attack jet aircraft low pass, underwing rocket pods, rugged silhouette"),
    "gunship":     (68, "attack helicopter hovering, chin gun turret, stub wings with missile pods, rotor blur"),
}

def fetch(url, data=None, headers=None, timeout=180):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

def gen_pollinations(key, prompt, seed):
    q = urllib.parse.quote(prompt)
    url = (f"https://image.pollinations.ai/prompt/{q}"
           f"?width=832&height=1216&nologo=true&seed={seed}&model=flux")
    return fetch(url, headers={"Authorization": "Bearer " + key})

def gen_gemini(key, prompt, seed):
    model = "gemini-2.5-flash-image"
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    body = json.dumps({
        "contents": [{"parts": [{"text": prompt + ", portrait orientation 2:3 aspect ratio"}]}],
        "generationConfig": {"responseModalities": ["IMAGE"], "seed": seed},
    }).encode()
    raw = fetch(url, data=body, headers={"Content-Type": "application/json", "x-goog-api-key": key})
    j = json.loads(raw)
    for part in j["candidates"][0]["content"]["parts"]:
        if "inlineData" in part:
            return base64.b64decode(part["inlineData"]["data"])
    raise RuntimeError("Gemini 回應無影像: " + raw[:200].decode(errors="replace"))

def gen_openai(key, prompt, seed, base, model, size="1024x1536"):
    url = base.rstrip("/") + "/images/generations"
    body = json.dumps({"model": model, "prompt": prompt, "size": size, "n": 1}).encode()
    raw = fetch(url, data=body, headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
    j = json.loads(raw)
    d = j["data"][0]
    if d.get("b64_json"):
        return base64.b64decode(d["b64_json"])
    return fetch(d["url"])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", required=True, choices=["pollinations", "gemini", "openai"])
    ap.add_argument("--key", required=True)
    ap.add_argument("--base", default="https://api.openai.com/v1")
    ap.add_argument("--model", default="gpt-image-1")
    ap.add_argument("--only", default="")
    ap.add_argument("--vehicles", action="store_true", help="生載具立繪（橫式）")
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    table = VEHICLES if a.vehicles else CHARS
    keys = [k.strip() for k in a.only.split(",") if k.strip()] or list(table)
    ok = fail = 0
    for k in keys:
        seed, desc = table[k]
        prompt = (VEH_STYLE if a.vehicles else STYLE).format(desc=desc)
        try:
            if a.backend == "pollinations": img = gen_pollinations(a.key, prompt, seed + SEED_OFFSET)
            elif a.backend == "gemini":     img = gen_gemini(a.key, prompt, seed + SEED_OFFSET)
            else:                            img = gen_openai(a.key, prompt, seed + SEED_OFFSET, a.base, a.model, "1536x1024" if a.vehicles else "1024x1536")
            if len(img) < 20000 or img[:1] == b"{":
                raise RuntimeError("回應疑似錯誤訊息: " + img[:150].decode(errors="replace"))
            with open(os.path.join(OUT, k + ".jpg"), "wb") as f:
                f.write(img)
            print(f"[OK] {k}: {len(img)} bytes"); ok += 1
        except Exception as e:
            print(f"[FAIL] {k}: {e}"); fail += 1
    print(f"完成 {ok} 張，失敗 {fail} 張 → {OUT}")
    sys.exit(1 if fail else 0)

if __name__ == "__main__":
    main()
