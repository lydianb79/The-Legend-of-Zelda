import sys; sys.path.insert(0,'Tests')
from bot import *
e=Emu(sys.argv[1],ROM_PATH, interp=len(sys.argv)>2 and sys.argv[2]=='interp')
start_game(e); print('mode',e.ram(0x12),'pos',e.pos()); e.shot('out/b0.png')
e.walk_to(64,141); print(e.pos()); e.step(UP,80); print('after up',e.pos(),'mode',e.ram(0x12)); e.step(0,60); e.shot('out/b1.png')
