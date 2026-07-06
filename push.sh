#!/bin/bash
# push.sh - EMERGENCY FALLBACK deploy (scp over the tailnet).
# publish.sh (AWS Greengrass) is the normal way code reaches the fleet.
# Keep this for the day AWS is down or a single PC needs code pushed by hand:
#   ./push.sh              -> push to every NUC listed below
#   ./push.sh holly-002    -> push to one NUC
#   ./push.sh list         -> show which fleet PCs are reachable right now
KEY=~/.ssh/fleet_deploy
NUCS=(holly-001 holly-002 holly-003)                                   # exact lowercase tailnet names
SRC=/Users/henryforrest/Documents/code/holly-code/holly      # location of the code on your local machine
DEST="C:/code/"

# 'list' = show fleet reachability from Tailscale, then exit
if [ "${1:-}" = "list" ]; then
  echo "fleet status ('offline' = unreachable, anything else = ok to push):"
  for n in "${NUCS[@]}"; do
    line=$(tailscale status | awk -v h="$n" '$2 == h')
    if [ -n "$line" ]; then echo "  $line"; else echo "  $n  NOT ON TAILNET"; fi
  done
  exit 0
fi

# Optional first argument = a single device name to push to.
# No argument = push to every device in NUCS.
if [ -n "$1" ]; then
  target="$1"
  # check the name is actually in the list before doing anything
  match=false
  for n in "${NUCS[@]}"; do
    if [ "$n" = "$target" ]; then match=true; break; fi
  done
  if [ "$match" = false ]; then
    echo "error: '$target' is not in the NUCS list (${NUCS[*]})"
    exit 1
  fi
  TARGETS=("$target")
else
  TARGETS=("${NUCS[@]}")
fi

# Push to all targets IN PARALLEL. Each device's output goes to its own log;
# results are printed together at the end. ConnectTimeout keeps an offline PC
# from hanging the batch, BatchMode stops ssh ever waiting for a password.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "pushing to ${#TARGETS[@]} device(s) in parallel..."
for n in "${TARGETS[@]}"; do
  (
    if scp -i "$KEY" -o ConnectTimeout=10 -o BatchMode=yes -r \
        "$SRC" "holly@$n:$DEST" >"$WORK/$n.log" 2>&1; then
      echo ok >"$WORK/$n.result"
    fi
  ) &
done
wait

failed=0
for n in "${TARGETS[@]}"; do
  if [ "$(cat "$WORK/$n.result" 2>/dev/null)" = "ok" ]; then
    echo "==> $n   ok"
  else
    echo "==> $n   FAILED"
    tail -3 "$WORK/$n.log" 2>/dev/null | sed 's/^/      /'
    failed=1
  fi
done
echo "done."
exit $failed