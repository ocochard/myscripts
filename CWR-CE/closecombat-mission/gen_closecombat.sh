#!/bin/sh
# Generate a close-combat CWR-CE mission: dense grid of soldiers packed within
# ~10-35m of a ground-level camera, so many render at the VIEW LOD (the only LOD
# GPU skinning covers). Purpose: give --gpu-skinning its maximal fair shot, which
# the distant-patrol Benchmark.Abel scene did not.
#
# Layout (Abel/Malden flat area, same known-good land the benchmark uses):
#   grid: ROWS x COLS soldiers, SPACING m apart, front row at y=FRONTY
#   player: back-center soldier, carries the camera init
#   camera: in front of the block (y < FRONTY), eye height, targets the player
#           => looks down the length of the block, nearest soldiers at view LOD
set -eu
OUT="${1:-/tmp/closecombat.sqm}"
ROWS=11; COLS=10; SP=2.0
CX=7999.0            # block center x
FRONTY=9250.0        # front row map-y
Z=32.174999         # ground altitude here
CAMY=9247.0          # camera map-y (3m in front of front row)
CAMH=2.0            # camera height ABOVE GROUND (eye level; camCreate z is AGL)

x0=$(awk "BEGIN{print $CX - ($COLS-1)*$SP/2}")   # leftmost col x
pbx=$(awk "BEGIN{print $CX}")                     # player x (center col)
pby=$(awk "BEGIN{print $FRONTY + ($ROWS-1)*$SP}") # player y (back row)

# Freeze every soldier so the dense grid holds (no AI dispersal) while still
# idle-animating (skinning stays exercised). "" = literal quote in sqm.
FREEZE="this disableAI \"\"MOVE\"\"; this disableAI \"\"AUTOTARGET\"\"; this setbehaviour \"\"SAFE\"\""
# Player (back-center) additionally spawns the eye-level camera at [CX,CAMY,CAMH]
# targeting itself => looks down the packed column, front rows at view LOD.
INIT="$FREEZE; pcam = \"\"camera\"\" camcreate [$CX, $CAMY, $CAMH]; pcam camsettarget this; pcam cameraeffect [\"\"internal\"\",\"\"back\"\"]; pcam camcommit 0"

{
echo 'version=11;'
echo 'class Mission'
echo '{'
echo '	randomSeed=3469315;'
echo '	class Intel'
echo '	{'
echo '	};'
echo '	class Groups'
echo '	{'
echo "		items=$ROWS;"
gid=0; id=1
r=0
while [ "$r" -lt "$ROWS" ]; do
  y=$(awk "BEGIN{print $FRONTY + $r*$SP}")
  echo "		class Item$r"
  echo '		{'
  echo '			side="WEST";'
  echo '			class Vehicles'
  echo '			{'
  echo "				items=$COLS;"
  c=0
  while [ "$c" -lt "$COLS" ]; do
    x=$(awk "BEGIN{print $x0 + $c*$SP}")
    # rotate soldier type for variety (all skinned infantry)
    case $(( (r*COLS + c) % 4 )) in
      0) veh="SoldierWB";;
      1) veh="SoldierWMG";;
      2) veh="SoldierWG";;
      *) veh="SoldierWLAW";;
    esac
    echo "				class Item$c"
    echo '				{'
    echo "					position[]={$x,$Z,$y};"
    echo '					azimut=180.000000;'   # face south = toward camera
    echo "					id=$id;"
    echo '					side="WEST";'
    # player = back-row center soldier (carries camera). Leader per row.
    is_player=0
    if [ "$r" -eq $((ROWS-1)) ] && [ "$c" -eq $((COLS/2)) ]; then is_player=1; fi
    echo "					vehicle=\"$veh\";"
    if [ "$is_player" -eq 1 ]; then
      echo '					player="PLAYER COMMANDER";'
      echo "					init=\"$INIT\";"
    else
      echo "					init=\"$FREEZE\";"
    fi
    if [ "$c" -eq 0 ]; then echo '					leader=1;'; fi
    echo '					skill=0.500000;'
    echo '				};'
    c=$((c+1)); id=$((id+1))
  done
  echo '			};'
  echo '		};'
  r=$((r+1))
done
echo '	};'
echo '};'
echo 'class Intro { randomSeed=16099331; class Intel {}; };'
echo 'class OutroWin { randomSeed=16696835; class Intel {}; };'
echo 'class OutroLoose { randomSeed=7588867; class Intel {}; };'
} > "$OUT"
echo "wrote $OUT ($(grep -c 'vehicle=' "$OUT") soldiers, $ROWS groups)"
