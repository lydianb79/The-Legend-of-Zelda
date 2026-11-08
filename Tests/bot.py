import ctypes, sys, os
ROM_PATH = os.environ.get('ZELDA_ROM', 'zelda.nes')   # path to your own ROM dump
from PIL import Image
PAL=[0x666666,0x002A88,0x1412A7,0x3B00A4,0x5C007E,0x6E0040,0x6C0600,0x561D00,0x333500,0x0B4800,0x005200,0x004F08,0x00404D,0,0,0,
0xADADAD,0x155FD9,0x4240FF,0x7527FE,0xA01ACC,0xB71E7B,0xB53120,0x994E00,0x6B6D00,0x388700,0x0C9300,0x008F32,0x007C8D,0,0,0,
0xFFFEFF,0x64B0FF,0x9290FF,0xC676FF,0xF36AFF,0xFE6ECC,0xFE8170,0xEA9E22,0xBCBE00,0x88D800,0x5CE430,0x45E082,0x48CDDE,0x4F4F4F,0,0,
0xFFFEFF,0xC0DFFF,0xD3D2FF,0xE8C8FF,0xFBC2FF,0xFEC4EA,0xFECCC5,0xF7D8A5,0xE4E594,0xCFEF96,0xBDF4AB,0xB3F3CC,0xB5EBF2,0xB8B8B8,0,0]
A,B,SEL,START,UP,DOWN,LEFT,RIGHT=1,2,4,8,16,32,64,128
class Emu:
    def __init__(s, lib, rom, interp=False):
        s.L=ctypes.CDLL(lib); L=s.L
        L.nes_create.restype=ctypes.c_void_p; L.nes_create.argtypes=[ctypes.c_char_p,ctypes.c_size_t,ctypes.c_void_p]
        for f in ('nes_run_frame',): getattr(L,f).argtypes=[ctypes.c_void_p]
        L.nes_set_buttons.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_uint8]
        L.nes_cpu_ram.restype=ctypes.POINTER(ctypes.c_uint8); L.nes_cpu_ram.argtypes=[ctypes.c_void_p]
        L.nes_framebuffer.restype=ctypes.POINTER(ctypes.c_uint32); L.nes_framebuffer.argtypes=[ctypes.c_void_p]
        L.nes_set_force_interpreter.argtypes=[ctypes.c_void_p,ctypes.c_int]
        L.nes_state_size.restype=ctypes.c_size_t
        L.nes_save_state.argtypes=[ctypes.c_void_p,ctypes.c_void_p]; L.nes_load_state.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t]
        L.nes_dump_misses.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_size_t]; L.nes_dump_misses.restype=ctypes.c_size_t
        for f in ('nes_stat_recomp_instructions','nes_stat_interp_instructions'):
            getattr(L,f).restype=ctypes.c_uint64; getattr(L,f).argtypes=[ctypes.c_void_p]
        d=open(rom,'rb').read(); s.n=L.nes_create(d,len(d),None)
        L.nes_set_force_interpreter(s.n, 1 if interp else 0)
        s.frame=0
    def ram(s,a): return s.L.nes_cpu_ram(s.n)[a]
    def step(s,btn=0,k=1):
        for _ in range(k):
            s.L.nes_set_buttons(s.n,0,btn); s.L.nes_run_frame(s.n); s.frame+=1
    def press(s,btn,hold=3,after=10): s.step(btn,hold); s.step(0,after)
    def shot(s,path):
        fb=s.L.nes_framebuffer(s.n); im=Image.new('RGB',(256,240)); px=im.load()
        for i in range(256*240):
            c=PAL[fb[i]&63]; px[i%256,i//256]=((c>>16)&255,(c>>8)&255,c&255)
        im.save(path); return im
    def save(s):
        b=ctypes.create_string_buffer(s.L.nes_state_size()); s.L.nes_save_state(s.n,b); return b
    def load(s,b): assert s.L.nes_load_state(s.n,b,len(b))
    def pos(s): return s.ram(0x70), s.ram(0x84)
    def walk_to(s,x,y,maxf=600):
        for _ in range(maxf):
            px,py=s.pos()
            if abs(px-x)<=1 and abs(py-y)<=1: return True
            b=0
            if abs(px-x)>1: b = RIGHT if x>px else LEFT
            elif abs(py-y)>1: b = DOWN if y>py else UP
            s.step(b)
        return False
    def misses(s):
        buf=ctypes.create_string_buffer(1<<22); k=s.L.nes_dump_misses(s.n,buf,len(buf)); return buf.raw[:k].decode()

def start_game(e):
    e.step(0,300); e.press(START); e.step(0,90); e.press(START)   # file select -> register
    e.step(0,70); e.press(A); e.press(A)
    for _ in range(3): e.press(SEL)
    e.press(START,after=90); e.press(START); e.step(0,150)       # pick file 1
