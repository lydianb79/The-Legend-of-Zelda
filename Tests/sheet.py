import sys,glob,os
from PIL import Image
fs=sorted(glob.glob(os.path.join(sys.argv[1],'f*.png')))
if len(sys.argv)>3: fs=[f for f in fs if int(os.path.basename(f)[1:6]) >= int(sys.argv[3])]
fs=fs[:12]
cols=4; rows=(len(fs)+cols-1)//cols
W=Image.new('RGB',(256*cols,(240+12)*rows),(40,40,40))
from PIL import ImageDraw
d=ImageDraw.Draw(W)
for k,f in enumerate(fs):
    W.paste(Image.open(f),((k%cols)*256,(k//cols)*252+12)); d.text(((k%cols)*256+2,(k//cols)*252),os.path.basename(f),fill=(255,255,0))
W.save(sys.argv[2])
