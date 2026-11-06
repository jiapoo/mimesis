import os, subprocess
H=os.path.dirname(os.path.abspath(__file__)); O=os.path.join(H,"fade"); os.makedirs(O,exist_ok=True)
M="M 250 760 L 250 290 L 512 600 L 774 290 L 774 760"
def S(w=96): return f'fill="none" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"'
GRAD='<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#EC3A55"/><stop offset="1" stop-color="#A3102D"/></linearGradient>'
FLAT='<rect width="1024" height="1024" fill="#DD1B3F"/>'
BGG='<rect width="1024" height="1024" fill="url(#bg)"/>'
def fadegrad(id,dx,dy,a0,a1):  # opacity fade top -> bottom along the echo
    return f'<linearGradient id="{id}" gradientUnits="userSpaceOnUse" x1="0" y1="{280+dy}" x2="0" y2="{780+dy}"><stop offset="0" stop-color="#FFFFFF" stop-opacity="{a0}"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="{a1}"/></linearGradient>'
def echo(dx,dy,stroke,w=96): return f'<path d="{M}" transform="translate({dx} {dy})" {S(w)} stroke="{stroke}"/>'
def front(w=96): return f'<path d="{M}" {S(w)} stroke="#FFFFFF"/>'
V=[
 ("7 as before", GRAD, BGG, echo(48,48,"#FFB3BF")),
 ("Faded echo", GRAD+fadegrad("f",48,48,0.7,0.05), BGG, echo(48,48,"url(#f)")),
 ("Trail ×3", GRAD, BGG, echo(108,108,"rgba(255,255,255,0.12)")+echo(72,72,"rgba(255,255,255,0.24)")+echo(36,36,"rgba(255,255,255,0.45)")),
 ("Trail ×3, faded", GRAD+fadegrad("a",108,108,0.25,0)+fadegrad("b",72,72,0.4,0.02)+fadegrad("c",36,36,0.65,0.05), BGG, echo(108,108,"url(#a)")+echo(72,72,"url(#b)")+echo(36,36,"url(#c)")),
 ("Faded, flat bg", fadegrad("f",48,48,0.7,0.05), FLAT, echo(48,48,"url(#f)")),
 ("Trail, flat, slim", fadegrad("a",90,90,0.25,0)+fadegrad("b",60,60,0.4,0.02)+fadegrad("c",30,30,0.65,0.05), FLAT, "SLIM"),
]
items=[]
for i,(n,defs,bg,echoes) in enumerate(V):
    if echoes=="SLIM":
        g='<g transform="translate(512 512) scale(0.84) translate(-512 -540)">'+echo(90,90,"url(#a)",76)+echo(60,60,"url(#b)",76)+echo(30,30,"url(#c)",76)+front(76)+'</g>'
    else: g=echoes+front()
    svg=os.path.join(O,f"v{i}.svg"); png=os.path.join(O,f"v{i}.png")
    open(svg,"w").write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"><defs>{defs}</defs>{bg}{g}</svg>')
    subprocess.run(["cairosvg",svg,"-W","400","-H","400","-o",png],check=True); items.append((n,png))
tiles=[]
for i,(n,png) in enumerate(items):
    x=40+(i%3)*450; y=40+(i//3)*620
    tiles.append(f'<g transform="translate({x} {y})"><g clip-path="url(#sq)"><image width="400" height="400" xlink:href="file://{png}"/></g><g transform="translate(162 440)" clip-path="url(#sm)"><image width="76" height="76" xlink:href="file://{png}"/></g><text x="200" y="575">{n}</text></g>')
sh=os.path.join(O,"sheet.svg")
open(sh,"w").write('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1390 1240" width="1390" height="1240"><rect width="1390" height="1240" fill="#F2F2F5"/><defs><clipPath id="sq"><rect width="400" height="400" rx="90"/></clipPath><clipPath id="sm"><rect width="76" height="76" rx="17"/></clipPath></defs><g font-family="Helvetica" font-size="34" font-weight="bold" fill="#222" text-anchor="middle">'+"".join(tiles)+'</g></svg>')
subprocess.run(["cairosvg","--unsafe",sh,"-o",os.path.join(H,"echo-m-fade.png")],check=True)
