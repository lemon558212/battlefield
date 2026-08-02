#!/bin/bash
# check_errors.sh — 檢查一份測試 log 裡有沒有「不該出現的引擎紅字」。
#
# 為什麼獨立成一支（2026-08-02）：走查與壓測腳本原本只認 stdout 的 `FAILS=` 行，
# stderr 的 `ERROR:` 完全不影響判定。於是 15 章共 90 次
# 「UVs are required to generate tangents」（石頭 mesh 無 UV）與
# 「第 N 章要出 X 台敵方載具，但沒有任何已解鎖的載具可選」（敵載具從不生成）
# 兩個真 bug，可以與「30/30 章 0 FAIL」長期共存。專案 CLAUDE.md 的驗收標準
# 明寫「console 無紅字」，那條標準先前沒有任何自動化在守。
#
# 用法：bash tools/check_errors.sh <logfile>
#   退出碼 0＝乾淨；1＝有未列白名單的紅字（會把種類與次數印出來）
# 白名單見 tools/known_errors.txt（每條都要寫理由）。
cd "$(dirname "$0")/.."
F="$1"
[ -f "$F" ] || { echo "check_errors: 找不到 $F"; exit 1; }

WL="tools/known_errors.txt"
tmp_all=$(mktemp)
# Godot 的紅字有兩種前綴：`ERROR:`（引擎/push_error）與 `SCRIPT ERROR:`（腳本例外）
grep -E "^(ERROR|SCRIPT ERROR):" "$F" > "$tmp_all" 2>/dev/null

if [ ! -s "$tmp_all" ]; then
  rm -f "$tmp_all"
  exit 0
fi

tmp_bad=$(mktemp)
cp "$tmp_all" "$tmp_bad"
if [ -f "$WL" ]; then
  # 白名單逐條過濾（跳過註解與空行）；grep -F ＝固定字串比對
  while IFS= read -r pat; do
    case "$pat" in ''|\#*) continue ;; esac
    grep -vF "$pat" "$tmp_bad" > "$tmp_bad.n" && mv "$tmp_bad.n" "$tmp_bad"
  done < "$WL"
fi

n=$(wc -l < "$tmp_bad" | tr -d ' ')
if [ "$n" -gt 0 ]; then
  echo "  ↑ 引擎紅字 $n 行（未列白名單），種類："
  sort "$tmp_bad" | uniq -c | sort -rn | head -12 | sed 's/^/    /'
  rm -f "$tmp_all" "$tmp_bad"
  exit 1
fi
rm -f "$tmp_all" "$tmp_bad"
exit 0
