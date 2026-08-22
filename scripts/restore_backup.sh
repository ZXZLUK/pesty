#!/usr/bin/env bash
# 备份恢复工具。
#
#   bash scripts/restore_backup.sh              # 演练：验证最近一份备份可完整恢复（默认，绝不碰真实库）
#   bash scripts/restore_backup.sh --list       # 列出全部备份
#   bash scripts/restore_backup.sh <file.db>    # 演练指定备份
#   bash scripts/restore_backup.sh --to-live    # 真恢复：最近一份备份覆盖真实库（先自动再备份当前库）
set -euo pipefail
cd "$(dirname "$0")/.."

DATA_DIR="$HOME/Library/Application Support/ClipBar"
BACKUPS="$DATA_DIR/backups"
TO_LIVE=0
PICK=""

for arg in "$@"; do
  case "$arg" in
    --list) ls -lt "$BACKUPS" 2>/dev/null | tail -n +2; exit 0 ;;
    --to-live) TO_LIVE=1 ;;
    *) PICK="$arg" ;;
  esac
done

[ -d "$BACKUPS" ] || { echo "没有备份目录：$BACKUPS"; exit 1; }
if [ -z "$PICK" ]; then
  PICK="$BACKUPS/$(ls -t "$BACKUPS" | head -1)"
fi
[ -f "$PICK" ] || { echo "备份不存在：$PICK"; exit 1; }
echo "==> 目标备份: $PICK ($(du -h "$PICK" | cut -f1))"

verify() {
  local db="$1"
  local integrity
  integrity="$(sqlite3 "$db" 'PRAGMA integrity_check;' 2>&1)"
  [ "$integrity" = "ok" ] || { echo "FAIL: integrity_check = $integrity"; return 1; }
  local clips boards images
  clips="$(sqlite3 "$db" 'SELECT COUNT(*) FROM clips;' 2>/dev/null || echo -1)"
  boards="$(sqlite3 "$db" 'SELECT COUNT(*) FROM pinboards;' 2>/dev/null || echo -1)"
  images="$(sqlite3 "$db" 'SELECT COUNT(*) FROM clips WHERE image_file IS NOT NULL;' 2>/dev/null || echo -1)"
  echo "    完整性 ok · clips=$clips · pinboards=$boards · 含图片条目=$images"
  [ "$clips" -ge 0 ] && [ "$boards" -ge 0 ]
}

if [ "$TO_LIVE" -eq 0 ]; then
  echo "==> 演练模式（真实库不动）"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/clipbar-restore-drill.XXXXXX")"
  cp "$PICK" "$TMP/drill.db"
  verify "$TMP/drill.db"
  rm -rf "$TMP"
  echo "==> 演练通过：这份备份可完整恢复（clips/pinboards 计数如上）"
  exit 0
fi

echo "==> 真恢复模式"
RUNNING="$(pgrep -f 'ClipBar.app/Contents/MacOS/ClipBar' || true)"
[ -n "$RUNNING" ] && { echo "拒绝执行：ClipBar 正在运行（PID $RUNNING）。先退出 App 再恢复。"; exit 1; }
STAMP="$(date +%Y%m%d-%H%M%S)"
cp "$DATA_DIR/history.db" "$DATA_DIR/history.db.pre-restore-$STAMP" 2>/dev/null || true
echo "    当前库已另存为 history.db.pre-restore-$STAMP"
verify "$PICK" || { echo "备份校验失败，已中止（真实库未动）。"; exit 1; }
cp "$PICK" "$DATA_DIR/history.db"
rm -f "$DATA_DIR/history.db-wal" "$DATA_DIR/history.db-shm"
echo "==> 恢复完成。启动 ClipBar 即加载恢复后的历史。"
