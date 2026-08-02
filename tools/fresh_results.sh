#!/bin/bash
# fresh_results.sh — 只報「本次批次」的測試結果，不吃殘留的舊 log。
#
# 為什麼需要：logs/ 裡每章一個固定檔名，批次跑到哪一章、後面那些章就還留著
# 上一輪的內容。直接 grep 全部 log 會把舊結果混進來當成本次成績
# （2026-08-01 差點這樣誤報——舊 walk 全綠、其實本批次還沒跑到）。
#
# 用法：bash tools/fresh_results.sh [基準檔]
#   基準檔預設 logs/play_clean.log（批次的第一個產物），比它新的才算本批次。
cd "$(dirname "$0")/.."
REF="${1:-logs/play_clean.log}"
if [ ! -f "$REF" ]; then
  echo "找不到基準檔 $REF —— 先跑批次或指定基準"
  exit 1
fi
echo "基準：$REF（$(date -r "$REF" '+%m-%d %H:%M')）以後的結果才算本批次"
echo "---- play ----"
grep -hE "^\[play\] FAILS=" "$REF" 2>/dev/null || echo "(無)"
bash "$(dirname "$0")/check_errors.sh" "$REF" || true
total_bad=0; total_miss=0; total_err=0
for mode in stress walk; do
  echo "---- $mode ----"
  n=0; bad=0; miss=0; errch=0
  for f in $(find logs -name "${mode}_ch*.log" -newer "$REF" 2>/dev/null | sort); do
    line=$(grep -hE "\[$mode\] ch[0-9]+ FAILS=" "$f")
    err=""
    bash "$(dirname "$0")/check_errors.sh" "$f" > /dev/null 2>&1 || err="＋紅字"
    [ -n "$err" ] && errch=$((errch+1))
    if [ -z "$line" ]; then
      # ⚠ 「未跑到結尾」以前只印一行、不計入任何數字，於是結尾的
      #   「0 章有 FAIL」讀起來像全綠（ch04/ch05 就是這樣被當成 0 FAIL 的）。
      #   缺少 FAILS= 總結行＝不合格，計入 miss。
      echo "$(basename "$f") 未跑到結尾（崩潰或仍在跑） $err"
      miss=$((miss+1))
    else
      echo "$line $err"
      n=$((n+1))
      echo "$line" | grep -qE "FAILS=[1-9]" && bad=$((bad+1))
    fi
  done
  echo "$mode：完成 $n 章／$bad 章有 FAIL／$miss 章未完成／$errch 章有紅字"
  total_bad=$((total_bad+bad)); total_miss=$((total_miss+miss)); total_err=$((total_err+errch))
done
echo "===================="
if [ "$total_bad" -eq 0 ] && [ "$total_miss" -eq 0 ] && [ "$total_err" -eq 0 ]; then
  echo "全部通過：無 FAIL、無未完成、無引擎紅字"
else
  echo "未通過：$total_bad 章有 FAIL／$total_miss 章未完成／$total_err 章有紅字"
  echo "（「未完成」與「有紅字」都算不通過——這兩類先前不計入數字，讀起來像全綠）"
fi
[ "$total_bad" -eq 0 ] && [ "$total_miss" -eq 0 ] && [ "$total_err" -eq 0 ]
