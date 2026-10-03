#!/usr/bin/env python3
"""Reproduce the embedded cat using only Python's standard library.

The source SVG expresses rectangular pixel art with coordinates rounded to
three decimals. Recover its intended 23-by-21 grid, preserving draw order and
colors; save a transparent indexed PNG and a standalone grid SVG.
Run from any directory: python3 /path/to/assets/compact_cat.py
"""
from pathlib import Path
import base64,re,xml.etree.ElementTree as ET,zlib,struct,hashlib
ASSETS = Path(__file__).resolve().parent
src = (ASSETS / 'reference-15845.svg').read_text()
root=ET.fromstring(src)
grid=[[0]*23 for _ in range(21)]
palette={'#ACBFAB':1,'#000':2,'#D5FBE6':3}
for e in root.iter():
 if not e.tag.endswith('path'):continue
 tokens=re.findall(r'[mMhHvVzZ]|[-+]?(?:\d*\.\d+|\d+)',e.attrib['d'])
 x=y=0.;points=[];i=0
 while i<len(tokens):
  c=tokens[i];i+=1
  if c.lower()=='m':
   dx=float(tokens[i]);dy=float(tokens[i+1]);i+=2
   if c=='M':x,y=dx,dy
   else:x,y=x+dx,y+dy
  elif c.lower()=='h':
   dx=float(tokens[i]);i+=1
   x=dx if c=='H' else x+dx
  elif c.lower()=='v':
   dy=float(tokens[i]);i+=1
   y=dy if c=='V' else y+dy
  elif c.lower()=='z':break
  else:raise Exception(c)
  points.append((x,y))
 x0=round((min(p[0] for p in points)-105)/(260/21));x1=round((max(p[0] for p in points)-105)/(260/21))
 y0=round((min(p[1] for p in points)-120)/(260/21));y1=round((max(p[1] for p in points)-120)/(260/21))
 for y in range(y0,y1):
  for x in range(x0,x1):grid[y][x]=palette[e.attrib['fill']]
# Rasterization of original rectangular pixel art on its integer 23x21 grid.
def chunk(kind,data):return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',23,21,8,3,0,0,0))+chunk(b'PLTE',bytes.fromhex('000000acbfab000000d5fbe6'))+chunk(b'tRNS',bytes([0,255,255,255]))+chunk(b'IDAT',zlib.compress(b''.join(bytes([0]+row) for row in grid),9))+chunk(b'IEND',b'')
(ASSETS / 'cat.png').write_bytes(png)
(ASSETS / 'cat.base64.txt').write_text(base64.b64encode(png).decode()+'\n')
# Merge vertical runs of matching horizontal intervals to minimize SVG paths.
paths=[]
for color,index in palette.items():
 runs=[]
 for y,row in enumerate(grid):
  x=0
  while x<23:
   if row[x]!=index:x+=1;continue
   start=x
   while x<23 and row[x]==index:x+=1
   match=next((r for r in runs if r[0]==start and r[2]==x-start and r[1]+r[3]==y),None)
   if match:match[3]+=1
   else:runs.append([start,y,x-start,1])
 paths.append('<path fill="'+color+'" d="'+''.join(f'M{x} {y}h{w}v{h}h-{w}z' for x,y,w,h in runs)+'"/>')
svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 23 21" shape-rendering="crispEdges">'+''.join(paths)+'</svg>\n'
(ASSETS / 'cat.svg').write_text(svg)
for name in ['cat.png', 'cat.base64.txt', 'cat.svg']:
 b = (ASSETS / name).read_bytes()
 print(name, len(b), hashlib.sha256(b).hexdigest())
