#!/bin/zsh
# Finderからのダブルクリックとターミナルの両方に対応。
cd -- "${0:A:h}" || exit 1
/usr/bin/python3 scripts/update_iphone.py "$@"
result=$?
if [[ -t 0 && $# -eq 0 ]]; then
  read "?Enterキーで終了します。"
fi
exit $result
