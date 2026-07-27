# -*- coding: utf-8 -*-
"""
gen-expressions.py — 以既有全身立繪為基底生成表情差分（OpenAI images/edits, gpt-image-2）
用法：python tools/gen-expressions.py --key <API_KEY> [--chars sniper,mg,engineer] [--moods angry,hurt,smile]
輸出：assets/portraits-full/<key>_<mood>.jpg
"""
import argparse, base64, json, os, sys, uuid, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "portraits-full")

MOODS = {
    "angry": "furious intense expression, furrowed brows, gritted teeth",
    "hurt":  "wounded pained expression, wincing, small blood scrape on cheek, slightly hunched",
    "smile": "warm gentle smile, relaxed eyes",
}

def edit_image(key, img_path, prompt):
    boundary = uuid.uuid4().hex
    with open(img_path, "rb") as f:
        img = f.read()
    parts = []
    def field(name, value):
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode())
    field("model", "gpt-image-2")
    field("prompt", prompt)
    field("size", "1024x1536")
    parts.append((f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"base.jpg\"\r\n"
                  "Content-Type: image/jpeg\r\n\r\n").encode() + img + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)
    req = urllib.request.Request("https://api.openai.com/v1/images/edits", data=body, headers={
        "Authorization": "Bearer " + key,
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    })
    with urllib.request.urlopen(req, timeout=300) as r:
        j = json.loads(r.read())
    return base64.b64decode(j["data"][0]["b64_json"])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True)
    ap.add_argument("--chars", default="sniper,mg,engineer")
    ap.add_argument("--moods", default="angry,hurt,smile")
    a = ap.parse_args()
    ok = fail = 0
    for c in a.chars.split(","):
        base = os.path.join(OUT, c + ".jpg")
        for m in a.moods.split(","):
            prompt = ("Keep the exact same character, art style, watercolor texture, outfit, weapon, "
                      "pose and background composition. Only change the facial expression to: "
                      + MOODS[m] + ". Same face identity, same hairstyle, same colors.")
            try:
                img = edit_image(a.key, base, prompt)
                out = os.path.join(OUT, f"{c}_{m}.jpg")
                with open(out, "wb") as f: f.write(img)
                print(f"[OK] {c}_{m}: {len(img)} bytes"); ok += 1
            except Exception as e:
                print(f"[FAIL] {c}_{m}: {e}"); fail += 1
    print(f"完成 {ok}，失敗 {fail}")
    sys.exit(1 if fail else 0)

if __name__ == "__main__":
    main()
