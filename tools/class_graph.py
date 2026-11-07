import re,os,sys,collections
root=sys.argv[1]
files={}
for dp,dn,fn in os.walk(root,followlinks=True):
    dn[:]=[d for d in dn if not d.startswith('.') and d not in('tests','examples','docs')]
    for f in fn:
        if f.endswith('.gd'):
            p=os.path.join(dp,f); files['res://'+os.path.relpath(p,root)]=p
cls={}; src={}
for r,p in files.items():
    s=open(p,errors='ignore').read(); src[r]=s
    m=re.search(r'^class_name\s+(\w+)',s,re.M)
    if m: cls[m.group(1)]=r
# strip comments/strings crudely
tok=re.compile(r'\b[A-Z]\w*\b')
edges={}
for r,s in src.items():
    body=re.sub(r'#.*','',s)
    e=set()
    for m in re.finditer(r'(?:preload|load)\("(res://[^"]+\.gd)"\)',body):
        e.add((m.group(1),'preload' if m.group(0).startswith('preload') else 'load'))
    d=os.path.dirname(r)
    for m in re.finditer(r'(preload|load|extends)\s*\(?\s*"([^"]+\.gd)"',body):
        pth=m.group(2)
        if not pth.startswith('res://'): pth=os.path.normpath(os.path.join(d.replace('res://',''),pth)); pth='res://'+pth
        e.add((pth,'load' if m.group(1)=='load' else 'preload'))
    for t in set(tok.findall(re.sub(r'"[^"\n]*"','',body))):
        if t in cls and cls[t]!=r: e.add((cls[t],'class'))
    edges[r]=e
start='res://game/arena_client.gd'
# static closure: class refs + preload (not load)
def succ(n,kinds=('preload','class')):
    return [t for t,k in edges.get(n,()) if k in kinds and t in src]
seen={start};st=[start]
while st:
    n=st.pop()
    for t in succ(n):
        if t not in seen: seen.add(t);st.append(t)
size=lambda n:len(src[n])
print("closure",len(seen),"scripts", sum(map(size,seen))//1024,"KB")
# exclusive subtree per edge from direct deps of start: nodes reachable only via d
def reach(excl,roots):
    s=set(roots);st=list(roots)
    while st:
        n=st.pop()
        for t in succ(n):
            if t==excl or t in s: continue
            s.add(t);st.append(t)
    return s
# per node in closure: how many scripts become unreachable if node's incoming edges all cut = dominator size
res=[]
cand=[n for n in seen if n!=start]
for n in cand:
    r=reach(n,[start]) 
    lost=seen-r-{n}
    res.append((len(lost)+1,n))
res.sort(reverse=True)
for k,n in res[:45]:
    who=[p for p in seen if any(t==n for t,_ in edges[p] if _ in('preload','class'))]
    print(k,n,"<-",len(who),who[:3])
print("---- edge cuts")
def reach2(cut):
    s={start};st=[start]
    while st:
        n=st.pop()
        for t in succ(n):
            if (n,t)==cut or t in s: continue
            s.add(t);st.append(t)
    return s
out=[]
for a in seen:
    for t in set(succ(a)):
        if t==start: continue
        # only meaningful if t has few inbound; quick prefilter by dominator size
        lost=len(seen)-len(reach2((a,t)))
        if lost>=8: out.append((lost,a,t))
out.sort(reverse=True)
for l,a,t in out[:40]:
    kinds=[k for tt,k in edges[a] if tt==t]
    print(l,a.replace('res://',''),'->',t.replace('res://',''),kinds)
print("---- drop class edges of one file")
def closure_without(files_):
    s={start};st=[start]
    while st:
        n=st.pop()
        for t,k in edges.get(n,()):
            if t not in src or t in s: continue
            if k=='class' and n in files_: continue
            s.add(t);st.append(t)
    return s
base=len(seen)
res=[]
for f in seen:
    if f.startswith('res://game/') or f.startswith('res://maps/'):
        c=closure_without({f}); res.append((base-len(c),f))
res.sort(reverse=True)
for l,f in res[:25]: print(l,f)
chain=[f for f in seen if re.search(r'arena_client(_\w+)?\.gd$',f)]
print("all arena_client* class-edges dropped:",base-len(closure_without(set(chain))))
for S in (['presentation','client_extras','player_stack','vote.gd','horde','progress','browser'],['presentation','client_extras','player_stack','vote.gd','horde','progress','browser','hud','game.gd','player_part1','effects','avatars']):
    fs={f for f in seen if any(x in f for x in S) and f.startswith('res://game/')}
    print(len(fs),"files ->",base-len(closure_without(fs)),"scripts")
# also drop ALL class edges in game/ and maps
fs={f for f in seen if f.startswith('res://game/') or f.startswith('res://maps/')}
print("all game/maps class edges:",base-len(closure_without(fs)))
