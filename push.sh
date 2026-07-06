#!/bin/bash
# push.sh - EMERGENCY FALLBACK deploy (scp over the tailnet).
# publish.sh (AWS Greengrass) is the normal way code reaches the fleet.
# Keep this for the day AWS is down or a single PC needs code pushed by hand:
#   ./push.sh              -> push to every NUC listed below
#   ./push.sh holly-002    -> push to one NUC
KEY=~/.ssh/fleet_deploy
NUCS=(holly-001 holly-002 holly-003)                                   # exact lowercase tailnet names
SRC=/Users/henryforrest/Documents/code/holly-code/holly      # location of the code on your local machine
DEST="C:/code/"

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

for n in "${TARGETS[@]}"; do
  echo "==> $n"
  if scp -i "$KEY" -r "$SRC" "holly@$n:$DEST"; then
    echo "   ok"
  else
    echo "   FAILED — skipping"
  fi
done
echo "done."