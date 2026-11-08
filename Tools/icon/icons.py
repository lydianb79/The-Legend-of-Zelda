# Variant renderer for the Zelda Recomp app icon (original artwork; no Nintendo characters/marks).
import numpy as np, sys
from PIL import Image, ImageFilter
S=1024; SS=2; N=S*SS
yy,xx=np.mgrid[0:N,0:N].astype(np.float32)/SS

def smooth(e0,e1,x): t=np.clip((x-e0)/(e1-e0),0,1); return t*t*(3-2*t)
def over(dst,rgb,a): a=a[...,None]; return dst*(1-a)+rgb*a
def blur(a,r):
    im=Image.fromarray((np.clip(a,0,1)*255).astype(np.uint8)).resize((256,256),Image.BILINEAR).filter(ImageFilter.GaussianBlur(r))
    return np.asarray(im.resize((N,N),Image.BILINEAR)).astype(np.float32)/255
PAL=np.array([[0.99,0.80,0.30],[0.80,0.55,0.16],[0.55,0.33,0.10],[0.42,0.22,0.12],[0.26,0.13,0.08],
              [0.20,0.75,0.95],[0.70,0.72,0.78],[0.95,0.96,1.0],[0.85,0.15,0.20],[0.45,0.05,0.10],[0.45,0.46,0.50],[0.28,0.29,0.33]],np.float32)
B=32*SS
def pixelate(rgb,a,thr=0.35,pal=None):
    h=N//B
    pr=(rgb*a[...,None]).reshape(h,B,h,B,3).mean((1,3)); pa=a.reshape(h,B,h,B).mean((1,3))
    pc=pr/np.maximum(pa[...,None],1e-4)
    P=PAL if pal is None else np.array(pal,np.float32)
    d=((pc[:,:,None,:]-P[None,None])**2).sum(-1); pc=P[d.argmin(-1)]
    pa=(pa>thr).astype(np.float32)
    return np.repeat(np.repeat(pc,B,0),B,1), np.repeat(np.repeat(pa,B,0),B,1)

def sword_layers(ox,oy,ang,K,gem_col=(0.12,0.7,0.95)):
    ca,sa=np.cos(ang),np.sin(ang); dx,dy=xx-ox,yy-oy
    s=dx*ca+dy*sa; w=-dx*sa+dy*ca
    L=380.0*K
    hw=np.where(s<L-80*K,(34-6*(s/(L-80*K)))*K,28*K*np.clip((L-s)/(80*K),0,1))
    bd=np.abs(w)-hw
    blade_a=np.where((s>30*K)&(s<L),1-smooth(-0.8,0.8,bd),0)
    side=w/np.maximum(hw,1)
    metal=0.62+0.30*np.clip(-side,0,1)**0.6-0.25*np.clip(side,0,1)
    metal=metal-0.22*np.exp(-(w/(6*K))**2)*(s<L-110*K)*(s>50*K)
    edge=np.exp(-((bd+3*K)/(2.2*K))**2)*(w<0)
    blade_rgb=np.stack([metal*0.88+edge*0.6,metal*0.95+edge*0.6,metal*1.06+edge*0.7],-1)
    GS,GH,GW,GR=14*K,16*K,105*K,13*K
    gdist=np.sqrt(np.maximum(np.abs(s-GS)-GH,0)**2+np.maximum(np.abs(w)-GW,0)**2)
    guard_a=np.where((np.abs(s-GS)<=GH+GR)&(np.abs(w)<=GW+GR),1-smooth(GR-2,GR+0.5,gdist),0)
    gshade=0.75+0.35*np.clip(-(s-GS)/(28*K),-1,1)
    gold=np.stack([1.0*gshade,0.76*gshade,0.28*gshade],-1)
    gem=np.sqrt((s-GS)**2+w**2); gem_a=1-smooth(17*K,19.5*K,gem)
    gc=np.array(gem_col)
    gem_rgb=gc*(1.05-gem[...,None]/(40*K))+np.clip(1-gem/(8*K),0,1)[...,None]*0.35
    grip_a=np.where((s<-2*K)&(s>-140*K),1-smooth(19*K,21.5*K,np.abs(w)),0)
    wrap=0.5+0.5*np.sin((s+w*0.9)*0.21/K)
    grip_rgb=np.stack([0.36+0.12*wrap,0.20+0.07*wrap,0.10+0.04*wrap],-1)*(1-0.4*(np.abs(w)/(21*K))**2)[...,None]
    pd=np.sqrt((s+160*K)**2+w**2); pom_a=1-smooth(28*K,31*K,pd); pom_rgb=gold*(1.15-pd[...,None]/(60*K))
    rgb=np.zeros((N,N,3),np.float32); a=np.zeros((N,N),np.float32)
    for c,al in ((blade_rgb,blade_a),(grip_rgb,grip_a),(pom_rgb,pom_a),(gold,guard_a),(gem_rgb,gem_a)):
        rgb=over(rgb,np.clip(c,0,1.4),al); a=a+al*(1-a)
    tip=(ox+L*ca,oy+L*sa)
    return rgb,a,blade_a,s,tip

def squircle(half=412):
    u=np.abs(xx-512)/half; v=np.abs(yy-512)/half
    sq=(u**5+v**5)**(1/5); return sq, 1-smooth(1-1.5/half,1+1.5/half,sq)

def background(c_in,c_mid,c_out,center=(560,430),glow=None,grid_col=None,grid_amt=0.07):
    r=np.sqrt(((xx-center[0])/520)**2+((yy-center[1])/560)**2)
    t=np.clip(r,0,1.4)[...,None]
    c_in,c_mid,c_out=map(np.array,(c_in,c_mid,c_out))
    bg=np.where(t<0.6,c_in*(1-t/0.6)+c_mid*(t/0.6),c_mid*(1-(t-0.6)/0.8)+c_out*((t-0.6)/0.8))
    if glow:
        (gx,gy,gr,gc,gi)=glow
        bg=bg+np.exp(-(((xx-gx)**2+(yy-gy)**2)/(2*gr**2)))[...,None]*np.array(gc)*gi
    if grid_col is not None:
        grid=((np.floor(xx/32)+np.floor(yy/32))%2)[...,None]
        gm=smooth(700,300,xx+(1024-yy))[...,None]*grid_amt
        bg=bg*(1-gm*grid)+gm*grid*np.array(grid_col)
    return bg.astype(np.float32)

def sparkles(img,rng,box,col,n=30,size=(2,4.5)):
    for i in range(n):
        px=rng.uniform(box[0],box[2]); py=rng.uniform(box[1],box[3]); rr=rng.uniform(*size)
        img=img+np.exp(-((xx-px)**2+(yy-py)**2)/(2*rr**2))[...,None]*np.array(col)*rng.uniform(0.6,1.2)
    return img

def glint(img,tx,ty,col=(1,0.97,0.9),k=1.0):
    st=1.2*np.exp(-((xx-tx)**2+(yy-ty)**2)/(2*10**2))+0.9*np.exp(-np.abs(yy-ty)/2.0-((xx-tx)/55)**2)+0.9*np.exp(-np.abs(xx-tx)/2.0-((yy-ty)/55)**2)
    return img+st[...,None]*np.array(col)*k

def bits(img,rng,ox,oy,ang,K,cols,n=14):
    for i in range(n):
        tt=rng.uniform(20,170)*K; off=rng.choice([-1,1])*rng.uniform(70,130)*K*(1-tt/(260*K))
        px=ox+tt*np.cos(ang)-off*np.sin(ang); py=oy+tt*np.sin(ang)+off*np.cos(ang)
        sz=rng.uniform(6,13)*(1.15-tt/(200*K)); fade=np.clip(1.2-tt/(170*K),0.25,1)
        m=((np.abs(xx-px)<sz)&(np.abs(yy-py)<sz)).astype(np.float32)*fade
        col=np.array(cols[rng.integers(len(cols))])
        img=img*(1-m[...,None])+(img*0.2+col*0.9)*m[...,None]
    return img

def place_sword(img,rng,ox,oy,ang,K,glow_col,bits_cols,mix_offset=10,gem=(0.12,0.7,0.95),shadow=(10,18)):
    rgb,a,blade_a,s,tip=sword_layers(ox,oy,ang,K,gem)
    prgb,pa=pixelate(rgb,a)
    noise=np.repeat(np.repeat(rng.random((N//B,N//B)),B,0),B,1).astype(np.float32)
    mix=smooth(0,1,np.clip((s-mix_offset*K+(noise-0.5)*110)/30,0,1))
    sw_rgb=prgb*(1-mix[...,None])+rgb*mix[...,None]; sw_a=pa*(1-mix)+a*mix
    img=img+blur(blade_a*mix,14)[...,None]*np.array(glow_col)*0.75
    sh=blur(sw_a,6); sh=np.roll(np.roll(sh,int(shadow[1]*SS),0),int(shadow[0]*SS),1)
    img=img*(1-0.45*sh[...,None]); img=over(img,sw_rgb,sw_a)
    img=bits(img,rng,ox,oy,ang,K,bits_cols)
    return img,tip,sw_a

def heart_shape(cx,cy,r):
    x=(xx-cx)/r; y=-(yy-cy)/r
    f=(x*x+y*y-1)**3-x*x*y**3
    return f

def finish(img,sq,body,rim_col=(0.5,0.9,0.75),rim=0.18,exposure=1.15):
    img=img*(1-0.35*smooth(0.75,1.0,(yy-512)/412)[...,None]*(sq<1)[...,None])+(smooth(0.965,1.0,sq)*body)[...,None]*np.array(rim_col)*rim
    img=1-np.exp(-img*exposure); img=np.clip(img*1.08,0,1)
    sh=blur(body,5); sh=np.roll(sh,int(10*SS),0)*0.4
    alpha=body+sh*(1-body)
    col=(img*body[...,None])/np.maximum(alpha[...,None],1e-4)
    out=np.concatenate([col,alpha[...,None]],-1)
    return Image.fromarray((out*255+0.5).astype(np.uint8),'RGBA').resize((S,S),Image.LANCZOS)

ANG=np.deg2rad(-45)

def v_emerald():
    rng=np.random.default_rng(7); sq,body=squircle()
    img=background((0.10,0.62,0.45),(0.03,0.30,0.25),(0.01,0.08,0.10),glow=(720,290,190,(1.0,0.82,0.45),0.55),grid_col=(0.2,0.5,0.4))
    img,tip,_=place_sword(img,rng,428,606,ANG,1.38,(0.55,1.0,0.85),[(0.6,1.0,0.82),(1.0,0.82,0.4)])
    img=sparkles(img,rng,(600,150,880,430),(1.0,0.85,0.5)); img=glint(img,tip[0]-4,tip[1]+4)
    return finish(img,sq,body)

def v_dungeon():
    rng=np.random.default_rng(11); sq,body=squircle()
    img=background((0.24,0.12,0.42),(0.09,0.05,0.20),(0.02,0.01,0.05),center=(520,560),glow=(700,300,200,(1.0,0.45,0.15),0.7),grid_col=(0.35,0.2,0.55),grid_amt=0.09)
    # torch-lit stone wall hint: soft brick rows
    rows=np.abs(np.sin(yy/44*np.pi))**12; cols=np.abs(np.sin((xx+ (np.floor(yy/88)%2)*44)/88*np.pi))**12
    img=img*(1-0.10*np.maximum(rows,cols)[...,None])
    img,tip,_=place_sword(img,rng,428,606,ANG,1.38,(1.0,0.55,0.25),[(1.0,0.55,0.2),(0.7,0.45,1.0)],gem=(0.85,0.15,0.25))
    img=sparkles(img,rng,(560,140,890,470),(1.0,0.5,0.15),n=40,size=(2,5)); img=glint(img,tip[0]-4,tip[1]+4,(1,0.85,0.7))
    return finish(img,sq,body,rim_col=(0.7,0.45,1.0))

def v_golden():
    rng=np.random.default_rng(3); sq,body=squircle()
    img=background((1.0,0.62,0.30),(0.62,0.20,0.32),(0.16,0.05,0.18),center=(600,380),glow=(740,270,200,(1.0,0.9,0.6),0.6),grid_col=(0.9,0.5,0.4),grid_amt=0.06)
    img,tip,_=place_sword(img,rng,428,606,ANG,1.38,(1.0,0.85,0.6),[(1.0,0.85,0.5),(1.0,0.5,0.6)],gem=(0.15,0.85,0.6))
    img=sparkles(img,rng,(590,150,880,430),(1.0,0.95,0.7)); img=glint(img,tip[0]-4,tip[1]+4)
    return finish(img,sq,body,rim_col=(1.0,0.7,0.5))

def v_stone():
    rng=np.random.default_rng(5); sq,body=squircle()
    img=background((0.20,0.45,0.62),(0.06,0.17,0.30),(0.01,0.04,0.09),center=(512,330),glow=(512,180,150,(0.9,0.95,1.0),0.5),grid_col=(0.3,0.45,0.6))
    # god-ray from above
    ray=np.exp(-((xx-512)/(90+ (yy*0.25)))**2)*smooth(900,100,yy)
    img=img+ray[...,None]*np.array([0.7,0.85,1.0])*0.35
    # stone: lumpy ellipse at the bottom
    ang_n=np.arctan2(yy-775,xx-512)
    rad=np.sqrt(((xx-512)/245)**2+((yy-775)/135)**2)*(1+0.06*np.sin(ang_n*5)+0.04*np.sin(ang_n*11+1))
    stone_a=1-smooth(0.98,1.02,rad)
    shade=0.62+0.28*np.clip(-(yy-740)/140,-1,1)-0.08*np.clip((xx-512)/250,-1,1)
    shade=shade+0.25*np.exp(-((xx-470)**2+(yy-700)**2)/(2*90**2))   # light from the shaft above
    stone_rgb=np.stack([shade*0.55,shade*0.57,shade*0.62],-1)
    # sword vertical, tip down into stone
    img,tip,sw_a=place_sword(img,rng,512,430,np.deg2rad(90),1.2,(0.7,0.9,1.0),[(0.7,0.9,1.0),(1.0,0.85,0.45)],mix_offset=10)
    # stone: pixel left half, HD right half
    prgb,pa=pixelate(stone_rgb,stone_a,0.5,pal=[[0.52,0.54,0.58],[0.40,0.42,0.46],[0.29,0.30,0.34],[0.19,0.20,0.23],[0.12,0.12,0.15]])
    sm=smooth(500,540,xx)
    img=over(img,prgb*(1-sm[...,None])+stone_rgb*sm[...,None],pa*(1-sm)+stone_a*sm)
    # moss
    moss=stone_a*smooth(0.75,0.95,rad)*(yy<775)*(0.5+0.5*np.sin(xx*0.05))
    img=over(img,np.array([0.25,0.55,0.25]),moss*0.5*sm)
    img=sparkles(img,rng,(380,180,650,560),(0.85,0.95,1.0),n=26)
    return finish(img,sq,body,rim_col=(0.6,0.8,1.0))

def v_hearts():
    rng=np.random.default_rng(9); sq,body=squircle()
    img=background((0.10,0.62,0.45),(0.03,0.30,0.25),(0.01,0.08,0.10),glow=(720,290,190,(1.0,0.82,0.45),0.45),grid_col=(0.2,0.5,0.4))
    img,tip,_=place_sword(img,rng,450,640,ANG,1.22,(0.55,1.0,0.85),[(0.6,1.0,0.82),(1.0,0.82,0.4)])
    # three hearts top-left: 8-bit -> half -> glossy HD
    HEART=["0110001100",
           "1111011110",
           "1111111111",
           "1111111111",
           "0111111110",
           "0011111100",
           "0001111000",
           "0000110000"]
    HL=   ["0000000000",
           "0100001000",
           "0000000000",
           "0000000000",
           "0000000000",
           "0000000000",
           "0000000000",
           "0000000000"]
    cell=11
    def pixel_heart(x0,y0):
        rgb=np.zeros((N,N,3),np.float32); al=np.zeros((N,N),np.float32)
        for r,row in enumerate(HEART):
            for c,ch in enumerate(row):
                if ch!='1': continue
                m=((xx>=x0+c*cell)&(xx<x0+(c+1)*cell)&(yy>=y0+r*cell)&(yy<y0+(r+1)*cell)).astype(np.float32)
                col=(1.0,0.95,0.95) if HL[r][c]=='1' else ((0.95,0.15,0.22) if r<5 else (0.72,0.08,0.15))
                rgb=rgb*(1-m[...,None])+np.array(col)*m[...,None]; al=np.maximum(al,m)
        return rgb,al
    def hd_heart(cx,cy,r):
        f=heart_shape(cx,cy,r); ha=1-smooth(-0.03,0.03,f)
        hy_n=(yy-cy)/r; hx_n=(xx-cx)/r
        hrgb=np.stack([0.98-0.30*hy_n,0.14+0.03*hy_n,0.22+0.02*hy_n],-1)
        hl=np.exp(-((hx_n+0.45)**2+(hy_n+0.35)**2)/0.05)
        return hrgb+hl[...,None]*0.9, ha
    hx0,hy0=190,205
    pr,pa=pixel_heart(hx0,hy0); img=over(img,pr,pa)
    pr,pa=pixel_heart(hx0+130,hy0); hr,ha=hd_heart(hx0+130+55,hy0+40,48)
    m=smooth(hx0+130+45,hx0+130+65,xx)
    img=over(img,pr*(1-m[...,None])+hr*m[...,None],pa*(1-m)+ha*m)
    hr,ha=hd_heart(hx0+260+55,hy0+40,48)
    img=img+blur(ha,10)[...,None]*np.array([1.0,0.3,0.4])*0.6
    img=over(img,hr,ha)
    img=sparkles(img,rng,(620,180,880,450),(1.0,0.85,0.5),n=22); img=glint(img,tip[0]-4,tip[1]+4)
    return finish(img,sq,body)

def v_crt():
    rng=np.random.default_rng(13); sq,body=squircle()
    img=background((0.16,0.17,0.20),(0.08,0.08,0.10),(0.02,0.02,0.03),center=(512,420))
    # CRT bezel
    u=np.abs(xx-512)/300; v=np.abs(yy-500)/270
    scr=(u**4+v**4)**0.25
    bez=1-smooth(1.16,1.18,scr); screen=1-smooth(0.995,1.005,scr)
    img=over(img,np.array([0.20,0.21,0.24])*(1.1-0.3*(yy/1024))[...,None],bez)
    img=img*(1-0.5*(bez*(1-screen)*smooth(1.0,1.16,scr))[...,None])
    inside=np.zeros((N,N,3),np.float32)+np.array([0.02,0.08,0.06])
    inside=inside+np.exp(-(((xx-512)**2+(yy-480)**2)/(2*220**2)))[...,None]*np.array([0.05,0.25,0.18])
    rgb,a,blade_a,s,tip=sword_layers(470,560,ANG,1.05)
    pr,pa=pixelate(rgb,a)
    phos=np.stack([pr[...,0]*0.35,pr[...,1]*1.0+0.15,pr[...,2]*0.5],-1)
    inside=over(inside,phos,pa)
    inside=inside*(0.72+0.28*np.cos(yy/8*np.pi)**2)[...,None]   # scanlines
    inside=inside+blur(pa,8)[...,None]*np.array([0.2,1.0,0.6])*0.35
    img=over(img,inside,screen)
    # glass reflection
    refl=screen*smooth(0.3,0.0,(yy-260)/260+(xx-300)/700)*0.18
    img=img+refl[...,None]
    # power LED
    led=np.exp(-((xx-760)**2+(yy-800)**2)/(2*7**2)); img=img+led[...,None]*np.array([0.3,1.0,0.5])*1.5
    return finish(img,sq,body,rim_col=(0.6,0.65,0.7),rim=0.12)

VARIANTS={'1_emerald':v_emerald,'2_dungeon':v_dungeon,'3_golden_hour':v_golden,'4_sword_in_stone':v_stone,'5_hearts':v_hearts,'6_retro_crt':v_crt}
if __name__=='__main__':
    import os; os.makedirs('variants',exist_ok=True)
    names=sys.argv[1:] or list(VARIANTS)
    for n in names:
        VARIANTS[n]().save(f'variants/{n}.png'); print('ok',n)
