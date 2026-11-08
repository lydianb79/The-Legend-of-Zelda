import re,sys
gen=open(sys.argv[1]).read()
have=set()
for m in re.finditer(r'static const recomp_fn T_(\d+)_(\d+)\[16384\] = \{(.*?)\};', gen, re.S):
    b,w=int(m.group(1)),int(m.group(2))
    for a in re.findall(r'\[0x([0-9A-F]+)\]', m.group(3)): have.add((b,w,int(a,16)+0x8000+w*0x4000))
cov=[tuple(int(x,16) if i==2 else int(x) for i,x in enumerate(l.split())) for l in open(sys.argv[2])]
hit=sum(1 for c in cov if c in have); print('static covers %d / %d of bot-observed instructions (%.1f%%)'%(hit,len(cov),100*hit/len(cov)))
miss=[c for c in cov if c not in have]
from collections import Counter
print(Counter((b,w) for b,w,a in miss))
