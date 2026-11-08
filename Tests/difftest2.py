# attract-mode + gameplay with a different random seed
import sys, random; sys.path.insert(0,'Tests')
exec(open('Tests/difftest.py').read().split("e=Both(A_,B_)")[0])
e=Both(A_,B_)
e.step(0,2600)           # title + story scroll attract mode
start_game(e)
random.seed(int(sys.argv[4])); dirs=[UP,DOWN,LEFT,RIGHT]
for k in range(int(sys.argv[3])):
    if k%25==0: d=random.choice(dirs)
    b=d|(A if random.random()<0.2 else 0)
    e.step(b)
ib=B_.L.nes_stat_interp_instructions(B_.n); ia=A_.L.nes_stat_interp_instructions(A_.n)
print('frames',e.frame,'mismatches',e.bad,'interp fallback %d of %d instrs (%.3f%%)'%(ib,ia,100*ib/ia))
open('out/diff2_misses.txt','w').write(B_.misses())
