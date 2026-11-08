import numpy as np
from PIL import Image, ImageFilter
S=1024; SS=2; N=S*SS
yy,xx=np.mgrid[0:N,0:N].astype(np.float32)/SS   # pixel coords in 1024 space

def smooth(e0,e1,x): t=np.clip((x-e0)/(e1-e0),0,1); return t*t*(3-2*t)
def over(dst,rgb,a):
    a=a[...,None]; return dst*(1-a)+rgb*a

# --- squircle body (Apple grid: 824 px body, centred) -----------------------------
cx=cy=512; half=412
u=np.abs(xx-cx)/half; v=np.abs(yy-cy)/half
sq=(u**5+v**5)**(1/5)
aa=1.5/half
body=1-smooth(1-aa,1+aa,sq)

# --- background: deep forest night -> emerald glow ---------------------------------
r=np.sqrt(((xx-560)/520)**2+((yy-430)/560)**2)
c_in=np.array([0.10,0.62,0.45]); c_mid=np.array([0.03,0.30,0.25]); c_out=np.array([0.01,0.08,0.10])
t=np.clip(r,0,1.4)[...,None]
bg=np.where(t<0.6, c_in*(1-t/0.6)+c_mid*(t/0.6), c_mid*(1-(t-0.6)/0.8)+c_out*((t-0.6)/0.8))
# warm sun bloom top-right behind the tip
g=np.exp(-(((xx-720)**2+(yy-290)**2)/(2*190**2)))[...,None]
bg=bg+g*np.array([1.0,0.82,0.45])*0.55
# faint pixel grid in the lower-left (the 8-bit world) fading out
grid=((np.floor(xx/32)+np.floor(yy/32))%2)[...,None]
gm=smooth(700,300,xx+ (1024-yy))[...,None]*0.07
bg=bg*(1-gm*grid)+gm*grid*np.array([0.2,0.5,0.4])
img=bg.astype(np.float32)

# --- sword in sword-local coordinates ------------------------------------------------
ang=np.deg2rad(-45)   # tip to upper right
K=1.38
ox,oy=428,606          # guard centre
dx,dy=xx-ox,yy-oy
ca,sa=np.cos(ang),np.sin(ang)
s= dx*ca - dy*sa*-1    # along axis (positive towards tip)
s= dx*np.cos(ang)+dy*np.sin(ang)
w=-dx*np.sin(ang)+dy*np.cos(ang)   # across axis
# blade: from s=40 to tip at s=380, half width 34 tapering, tip point
L=380.0*K
hw=np.where(s<L-80*K, (34-6*(s/(L-80*K)))*K, 28*K*np.clip((L-s)/(80*K),0,1))
blade=(s>30*K)&(s<L)
bd=np.abs(w)-hw
blade_a=np.where(blade,1-smooth(-0.8,0.8,bd),0)
# metallic shading: bright edge on one side, fuller groove in the middle
side=w/np.maximum(hw,1)
metal=0.62+0.30*np.clip(-side,0,1)**0.6-0.25*np.clip(side,0,1)
fuller=np.exp(-(w/(6*K))**2)*(s<L-110*K)*(s>50*K)
metal=metal-0.22*fuller
edge=np.exp(-((bd+3*K)/(2.2*K))**2)*(w<0)
blade_rgb=np.stack([metal*0.88+edge*0.6, metal*0.95+edge*0.6, metal*1.06+edge*0.7],-1)
# guard: gold bar across, rounded ends
GS=14*K; GH=16*K; GW=105*K; GR=13*K
guard_core=(np.abs(s-GS)<=GH+GR)&(np.abs(w)<=GW+GR)
gdist=np.sqrt(np.maximum(np.abs(s-GS)-GH,0)**2+np.maximum(np.abs(w)-GW,0)**2)
guard_a=np.where(guard_core,1-smooth(GR-2,GR+0.5,gdist),0)
gshade=0.75+0.35*np.clip(-(s-GS)/(28*K),-1,1)
gold=np.stack([1.0*gshade,0.76*gshade,0.28*gshade],-1)
# gem in guard centre
gem=np.sqrt((s-GS)**2+w**2)
gem_a=1-smooth(17*K,19.5*K,gem)
gem_rgb=np.stack([0.12+0.25*np.clip(1-gem/(10*K),0,1),0.7-gem/(60*K)+0.25*np.clip(1-gem/(8*K),0,1),0.95-gem/(80*K)],-1)
# grip
grip=(s<-2*K)&(s>-140*K)
grip_a=np.where(grip,1-smooth(19*K,21.5*K,np.abs(w)),0)
wrap=0.5+0.5*np.sin((s+w*0.9)*0.21/K)
grip_rgb=np.stack([0.36+0.12*wrap,0.20+0.07*wrap,0.10+0.04*wrap],-1)*(1-0.4*(np.abs(w)/(21*K))**2)[...,None]
# pommel
pd=np.sqrt((s+160*K)**2+w**2)
pom_a=1-smooth(28*K,31*K,pd)
pom_rgb=gold*(1.15-pd[...,None]/(60*K))

sword=np.zeros((N,N,3),np.float32); sa_=np.zeros((N,N),np.float32)
for rgb,a in ((blade_rgb,blade_a),(grip_rgb,grip_a),(pom_rgb,pom_a),(gold,guard_a),(gem_rgb,gem_a)):
    sword=over(sword,np.clip(rgb,0,1.4),a); sa_=sa_+a*(1-sa_)

# --- pixelate the hilt half, dissolving into HD towards the tip ----------------------
B=32*SS
def pixelate(rgb,a):
    h=N//B
    pr=(rgb*a[...,None]).reshape(h,B,h,B,3).mean((1,3)); pa=a.reshape(h,B,h,B).mean((1,3))
    pc=pr/np.maximum(pa[...,None],1e-4)
    pa=(pa>0.35).astype(np.float32)
    PAL=np.array([[0.99,0.80,0.30],[0.80,0.55,0.16],[0.55,0.33,0.10],[0.42,0.22,0.12],[0.26,0.13,0.08],
                  [0.20,0.75,0.95],[0.70,0.72,0.78],[0.95,0.96,1.0]],np.float32)   # gold, amber, bronze, leather x2, gem, steel, white
    d=((pc[:,:,None,:]-PAL[None,None])**2).sum(-1)
    pc=PAL[d.argmin(-1)]
    return np.repeat(np.repeat(pc,B,0),B,1), np.repeat(np.repeat(pa,B,0),B,1)
prgb,pa=pixelate(sword,sa_)
# block-wise dissolve threshold along the axis
rng=np.random.default_rng(7)
noise=np.repeat(np.repeat(rng.random((N//B,N//B)),B,0),B,1).astype(np.float32)
mix=np.clip((s-(10*K)+(noise-0.5)*110)/30,0,1)   # 0 = pixel, 1 = HD
mix=smooth(0,1,mix)
sw_rgb=prgb*(1-mix[...,None])+sword*mix[...,None]
sw_a=pa*(1-mix)+sa_*mix

# glow behind blade (bloom)
glow_src=Image.fromarray((np.clip(blade_a*mix,0,1)*255).astype(np.uint8)).resize((256,256),Image.BILINEAR).filter(ImageFilter.GaussianBlur(14))
glow=np.asarray(glow_src.resize((N,N),Image.BILINEAR)).astype(np.float32)/255
img=img+glow[...,None]*np.array([0.55,1.0,0.85])*0.75

# drop shadow of sword
sh=Image.fromarray((sw_a*255).astype(np.uint8)).resize((256,256),Image.BILINEAR).filter(ImageFilter.GaussianBlur(6))
sh=np.asarray(sh.resize((N,N),Image.BILINEAR)).astype(np.float32)/255
sh=np.roll(np.roll(sh,int(18*SS),0),int(10*SS),1)
img=img*(1-0.45*sh[...,None])
img=over(img,sw_rgb,sw_a)

# pixel bits breaking away from the transition zone, drifting toward the tip and fading
for i in range(14):
    tt=rng.uniform(20,170)*K; off=rng.choice([-1,1])*rng.uniform(70,130)*K*(1-tt/(260*K))
    px=ox+tt*np.cos(ang)-off*np.sin(ang); py=oy+tt*np.sin(ang)+off*np.cos(ang)
    sz=rng.uniform(6,13)*(1.15-tt/(200*K))
    fade=np.clip(1.2-tt/(170*K),0.25,1)
    m=((np.abs(xx-px)<sz)&(np.abs(yy-py)<sz)).astype(np.float32)*fade
    col=np.array([0.6,1.0,0.82]) if rng.random()<0.55 else np.array([1.0,0.82,0.4])
    img=img*(1-m[...,None])+(img*0.2+col*0.9)*m[...,None]
for i in range(30):
    px=rng.uniform(600,880); py=rng.uniform(150,430); rr=rng.uniform(2,4.5)
    d2=(xx-px)**2+(yy-py)**2
    img=img+np.exp(-d2/(2*rr**2))[...,None]*np.array([1.0,0.85,0.5])*rng.uniform(0.6,1.2)
# star glint on the tip
tx,ty=ox+L*np.cos(ang)-4, oy+L*np.sin(ang)+4
st=1.2*np.exp(-((xx-tx)**2+(yy-ty)**2)/(2*10**2))+0.9*np.exp(-np.abs(yy-ty)/2.0-((xx-tx)/55)**2)+0.9*np.exp(-np.abs(xx-tx)/2.0-((yy-ty)/55)**2)
img=img+st[...,None]*np.array([1,0.97,0.9])

# inner rim light + bottom shade for depth
rim=smooth(0.965,1.0,sq)*body
img=img*(1-0.35*smooth(0.75,1.0,(yy-cy)/half)[...,None]*(sq<1)[...,None])+rim[...,None]*np.array([0.5,0.9,0.75])*0.18
# tone map
img=1-np.exp(-img*1.15)
img=np.clip(img*1.08,0,1)

rgba=np.concatenate([img,body[...,None]],-1)
# outer soft shadow (macOS style)
shadow=Image.fromarray((body*255).astype(np.uint8)).resize((256,256),Image.BILINEAR).filter(ImageFilter.GaussianBlur(5))
shadow=np.asarray(shadow.resize((N,N),Image.BILINEAR)).astype(np.float32)/255
shadow=np.roll(shadow,int(10*SS),0)*0.4
alpha=body+shadow*(1-body)
col=(rgba[...,:3]*body[...,None])/np.maximum(alpha[...,None],1e-4)
out=np.concatenate([col,alpha[...,None]],-1)
im=Image.fromarray((out*255+0.5).astype(np.uint8),'RGBA').resize((S,S),Image.LANCZOS)
im.save('icon_1024.png')
prev=Image.new('RGBA',(1024+256+128+64,1024),(236,236,236,255)); prev.alpha_composite(im,(0,0))
for k,sz in enumerate((256,128,64)):
    prev.alpha_composite(im.resize((sz,sz),Image.LANCZOS),(1024+[0,256,384][k],0))
prev.save('preview.png')
