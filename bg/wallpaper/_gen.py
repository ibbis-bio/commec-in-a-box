import random
W,H=3840,2160
NAVY="#232a58"; ORANGE="#f05023"; TEAL="#419bb9"
random.seed(42)
bases="ACGT"
def codons(n): return " ".join("".join(random.choice(bases) for _ in range(3)) for _ in range(n))
# faint codon readout lines
rows=[]
y=300
mono='font-family="Andale Mono, Menlo, monospace"'
while y < H-260:
    op = 0.05
    # occasional brighter "flagged" line
    rows.append(f'<text x="120" y="{y}" {mono} font-size="40" letter-spacing="6" fill="#9fb4d8" fill-opacity="{op}">{codons(70)}</text>')
    y += 150

ibis="/tmp/ibbis_brand/ibis_ghost.png"
lockup="/tmp/ibbis_brand/commec_horiz_reversed.png"
# lockup native 1431x222 -> scale to width 1560
lw=1560; lh=int(222*lw/1431)
lx=(W-lw)//2; ly=980
# tagline
tag="SAFEGUARDING MODERN BIOSCIENCE AND BIOTECHNOLOGY"
ty=ly+lh+150
svg=f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<defs>
 <radialGradient id="g" cx="50%" cy="34%" r="85%">
  <stop offset="0%" stop-color="#2c3567"/>
  <stop offset="55%" stop-color="{NAVY}"/>
  <stop offset="100%" stop-color="#181d42"/>
 </radialGradient>
</defs>
<rect width="{W}" height="{H}" fill="url(#g)"/>
{chr(10).join(rows)}
<image xlink:href="{ibis}" x="2230" y="150" width="1480" height="{int(1480*692/827)}" opacity="0.09"/>
<image xlink:href="{lockup}" x="{lx}" y="{ly}" width="{lw}" height="{lh}"/>
<text x="{W//2}" y="{ty}" text-anchor="middle" font-family="Helvetica Neue, Helvetica, Arial, sans-serif" font-size="40" letter-spacing="14" fill="#ffffff" fill-opacity="0.62" font-weight="300">{tag}</text>
</svg>'''
open("wallpaper.svg","w").write(svg)
print("svg written, lockup",lw,"x",lh,"at",lx,ly)
