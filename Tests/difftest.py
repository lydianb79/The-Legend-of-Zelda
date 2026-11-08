# Lockstep differential test: interpreter vs recompiled code, identical input.
import sys, random, ctypes; sys.path.insert(0,'Tests')
from bot import *
libA, libB, frames, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]) if len(sys.argv)>4 else 2
A_ = Emu(libA,ROM_PATH, interp=True)
B_ = Emu(libB,ROM_PATH, interp=False)
class Both:
    def __init__(s,a,b): s.a=a; s.b=b; s.frame=0; s.bad=0
    def ram(s,x): return s.a.ram(x)
    def pos(s): return s.a.pos()
    def step(s,btn=0,k=1):
        for _ in range(k):
            s.a.step(btn); s.b.step(btn); s.frame+=1; s.check()
    def press(s,btn,hold=3,after=10): s.step(btn,hold); s.step(0,after)
    def check(s):
        ra=bytes(s.a.L.nes_cpu_ram(s.a.n)[:2048]); rb=bytes(s.b.L.nes_cpu_ram(s.b.n)[:2048])
        fa=bytes(ctypes.string_at(s.a.L.nes_framebuffer(s.a.n),256*240*4)); fb=bytes(ctypes.string_at(s.b.L.nes_framebuffer(s.b.n),256*240*4))
        if ra!=rb or fa!=fb:
            s.bad+=1
            if s.bad<5:
                d=[hex(i) for i in range(2048) if ra[i]!=rb[i]][:10]
                print('MISMATCH frame',s.frame,'ram diffs',d,'fb equal',fa==fb)
            if s.bad==5: raise SystemExit('too many mismatches')
    walk_to=Emu.walk_to
e=Both(A_,B_)
start_game(e)
e.walk_to(64,141); e.step(UP,80); e.step(0,200); e.walk_to(120,213); e.step(UP,220); e.step(0,120); e.step(DOWN,150)
random.seed(seed); dirs=[UP,DOWN,LEFT,RIGHT]
for k in range(frames):
    if k%30==0: d=random.choice(dirs)
    b=d
    if random.random()<0.15: b|=A
    if random.random()<0.002: b=START
    e.step(b)
ia=A_.L.nes_stat_interp_instructions(A_.n); rb_=B_.L.nes_stat_recomp_instructions(B_.n); ib=B_.L.nes_stat_interp_instructions(B_.n)
print('frames',e.frame,'mismatches',e.bad,'| recomp: blocks run',rb_,'interp fallback instrs',ib,'(interp-only run:',ia,'instrs)')
open('out/diff_misses.txt','w').write(B_.misses())
