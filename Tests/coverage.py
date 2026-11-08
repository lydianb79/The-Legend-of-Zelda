# Play the game with a bot (interpreter mode) and collect every ROM address
# the interpreter executed -> coverage seeds for the recompiler.
import sys, random; sys.path.insert(0,'Tests')
from bot import *
lib, out = sys.argv[1], sys.argv[2]
e=Emu(lib,ROM_PATH, interp=True)
random.seed(1)
start_game(e)
# title attract mode / story scroll is also code: covered by a separate run below
# grab the sword in the first cave
e.walk_to(64,141); e.step(UP,80); e.step(0,200)
e.walk_to(120,213); e.step(UP,60); e.step(0,30)
for _ in range(40):
    e.step(UP,4)
print('cave pos',e.pos(),'mode',e.ram(0x12)); e.shot('out/c_cave.png')
e.step(0,120); e.step(DOWN,150); e.step(0,100)
print('after exit',e.pos(),'mode',e.ram(0x12)); e.shot('out/c_exit.png')
# random exploration with sword swings
dirs=[UP,DOWN,LEFT,RIGHT]
snap=e.save()
for k in range(int(sys.argv[3]) if len(sys.argv)>3 else 30000):
    if k%30==0: d=random.choice(dirs)
    b=d
    if random.random()<0.15: b|=A
    if random.random()<0.01: b|=B
    if random.random()<0.002: b=START
    e.step(b)
    if e.ram(0x12) in (0x11,):  # dying / game over handling: just keep pressing start
        e.step(START,2)
print('final mode',e.ram(0x12),'level',e.ram(0x10),'pos',e.pos(), 'frames',e.frame); e.shot('out/c_end.png')
open(out,'w').write(e.misses())
