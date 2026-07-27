#!/usr/bin/env python
# make_sfx.py — 合成戰場音效（無外部素材，全部程式產生）。
#
# 為什麼自己合成：專案沒有音效素材，而 CC0 音效庫要下載、要記授權。
# 槍聲、爆炸、腳步這幾類本來就是「雜訊包絡 + 低頻衝擊」，合成出來夠用，
# 而且完全可重現、可調參，也不會有授權問題。
#
# 產物：godot/assets/audio/sfx/*.wav（22050Hz 單聲道 16bit）

import numpy as np, wave, os, struct

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "godot", "assets", "audio", "sfx")


def save(name, x):
    x = np.clip(x, -1.0, 1.0)
    # 尾端淡出，避免爆音
    n = min(len(x), int(SR * 0.01))
    x[-n:] *= np.linspace(1.0, 0.0, n)
    data = (x * 32767).astype("<i2").tobytes()
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, name)
    with wave.open(p, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)
    print(f"  {name}  {len(x)/SR*1000:.0f}ms  {len(data)/1024:.1f}KB")


def env(n, attack, decay, power=2.0):
    """攻擊很快、指數衰減——槍聲與撞擊的共同形狀"""
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-5), 0, 1)
    d = np.exp(-t / decay) ** power
    return a * d


def noise(n, seed):
    rng = np.random.default_rng(seed)
    return rng.standard_normal(n)


def lowpass(x, cutoff):
    """一階 IIR 低通：越低越悶（用來做遠處/低頻的部分）"""
    a = np.exp(-2.0 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):
        acc = a * acc + (1 - a) * x[i]
        y[i] = acc
    return y


def highpass(x, cutoff):
    return x - lowpass(x, cutoff)


def gunshot(dur, crack_hz, thump_hz, decay, seed, body=1.0):
    """槍聲＝高頻爆裂（火藥氣體）＋低頻胸腔衝擊（膛壓）＋短尾音"""
    n = int(SR * dur)
    t = np.arange(n) / SR
    crack = highpass(noise(n, seed), crack_hz) * env(n, 0.0004, decay * 0.35, 2.2)
    thump = np.sin(2 * np.pi * thump_hz * t * np.exp(-t * 9.0)) * env(n, 0.001, decay * 0.9, 1.4)
    tail = lowpass(noise(n, seed + 1), 900) * env(n, 0.004, decay * 2.4, 1.0) * 0.35
    return (crack * 0.75 + thump * body * 0.9 + tail) * 0.9


print("合成槍聲：")
save("shot_rifle.wav", gunshot(0.42, 2600, 132, 0.075, 11))
save("shot_carbine.wav", gunshot(0.34, 3000, 150, 0.055, 22, body=0.8))
save("shot_sniper.wav", gunshot(0.62, 2100, 96, 0.115, 33, body=1.25))
save("shot_lmg.wav", gunshot(0.36, 2500, 120, 0.06, 44, body=0.95))
save("shot_cannon.wav", gunshot(1.10, 1200, 52, 0.26, 55, body=1.9))
save("shot_rocket.wav", gunshot(0.85, 900, 68, 0.20, 66, body=1.5))

print("合成爆炸：")
n = int(SR * 1.6)
t = np.arange(n) / SR
boom = lowpass(noise(n, 77), 260) * env(n, 0.002, 0.30, 1.1) * 1.4
crack = highpass(noise(n, 78), 1800) * env(n, 0.0006, 0.045, 2.0) * 0.7
sub = np.sin(2 * np.pi * 42 * t * np.exp(-t * 4.0)) * env(n, 0.003, 0.34, 1.2)
deb = lowpass(noise(n, 79), 3000) * env(n, 0.08, 0.55, 1.0) * 0.25   # 碎屑落地
save("explosion.wav", boom + crack + sub + deb)

print("合成撞擊：")
n = int(SR * 0.28)
save("impact_dirt.wav", lowpass(noise(n, 91), 1400) * env(n, 0.0008, 0.035, 1.6) * 0.8)
n = int(SR * 0.40)
t = np.arange(n) / SR
ring = (np.sin(2 * np.pi * 1850 * t) + 0.6 * np.sin(2 * np.pi * 3100 * t)) * env(n, 0.0006, 0.085, 1.3)
save("impact_metal.wav", highpass(noise(n, 92), 2200) * env(n, 0.0005, 0.02, 2.0) * 0.6 + ring * 0.45)
n = int(SR * 0.30)
save("impact_wood.wav", lowpass(noise(n, 93), 2200) * env(n, 0.0007, 0.05, 1.5) * 0.7)

print("合成腳步（三種變化，避免機械重複）：")
for i, seed in enumerate([101, 102, 103]):
    n = int(SR * 0.22)
    step = lowpass(noise(n, seed), 900) * env(n, 0.0015, 0.035, 1.4) * 0.55
    grit = highpass(noise(n, seed + 50), 3500) * env(n, 0.001, 0.055, 1.2) * 0.20
    save("step_%d.wav" % (i + 1), step + grit)

print("合成換彈：")
n = int(SR * 0.5)
x = np.zeros(n)
for off, seed, g in [(0.0, 201, 0.5), (0.13, 202, 0.35), (0.30, 203, 0.6)]:
    st = int(SR * off)
    ln = min(int(SR * 0.09), n - st)
    click = highpass(noise(ln, seed), 2500) * env(ln, 0.0004, 0.012, 1.8) * g
    x[st:st + ln] += click
save("reload.wav", x)

print("完成。")
