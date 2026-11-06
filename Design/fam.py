import os, subprocess
H=os.path.dirname(os.path.abspath(__file__)); O=os.path.join(H,"fam"); os.makedirs(O,exist_ok=True)
M="M 250 760 L 250 290 L 512 600 L 774 290 L 774 760"
S='fill="none" stroke-width="96" stroke-linecap="round" stroke-linejoin="round"'
V=[("Soft white echo",f'<path d="{M}" transform="translate(48 48)" {S} stroke="#FFFFFF" stroke-opacity="0.38"/>'),
   ("Deep crimson echo",f'<path d="{M}" transform="translate(48 48)" {S} stroke="#8E0E26"/>'),
   ("Outline echo",f'<path d="{M}" transform="translate(48 48)" fill="none" stroke-width="96" stroke-linecap="round" stroke-linejoin="round" stroke="#FFFFFF"/><path d="{M}" transform="translate(48 48)" fill="none" stroke-width="56" stroke-linecap="round" stroke-linejoin="round" stroke="#DD1B3F"/>')]
tiles=[]
refs=[("Arete","/Volumes/APPS/work/arete-full-stack/arete-apple/Arete/Resources/Assets.xcassets/AppIcon.appiconset/1024.png"),("Imago","/Volumes/APPS/work/imago/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png")]
items=[]
for i,(n,echo) in enumerate(V):
    svg=os.path.join(O,f"v{i}.svg"); png=os.path.join(O,f"v{i}.png")
    open(svg,"w").write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"><rect width="1024" height="1024" fill="#DD1B3F"/>{echo}<path d="{M}" {S} stroke="#FFFFFF"/></svg>')
    subprocess.run(["cairosvg",svg,"-W","400","-H","400","-o",png],check=True); items.append((n,png))
items+=refs
for i,(n,png) in enumerate(items):
    x=40+i*450
    tiles.append(f'<g transform="translate({x} 40)"><g clip-path="url(#sq)"><image width="400" height="400" xlink:href="file://{png}"/></g><g transform="translate(162 440)" clip-path="url(#sm)"><image width="76" height="76" xlink:href="file://{png}"/></g><text x="200" y="575">{n}</text></g>')
sh=os.path.join(O,"sheet.svg")
open(sh,"w").write('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 2290 620" width="2290" height="620"><rect width="2290" height="620" fill="#F2F2F5"/><line x1="1365" y1="30" x2="1365" y2="590" stroke="#C8C8D0" stroke-width="4" stroke-dasharray="12 12"/><defs><clipPath id="sq"><rect width="400" height="400" rx="90"/></clipPath><clipPath id="sm"><rect width="76" height="76" rx="17"/></clipPath></defs><g font-family="Helvetica" font-size="34" font-weight="bold" fill="#222" text-anchor="middle">'+"".join(tiles)+'</g></svg>')
subprocess.run(["cairosvg","--unsafe",sh,"-o",os.path.join(H,"echo-m-family.png")],check=True)
