import sys,re,statistics as st
rows={}
for l in open(sys.argv[1]):
    f=l.rstrip('\n').split('\t')
    if len(f)<10 or not f[1].startswith('VUS='): continue
    d={'b':f[0],'vus':int(f[1][4:]),'hold':f[2][5:],'ok':f[3]}
    for x in f[4:]:
        m=re.match(r'\(?(\w[\w/]*)[= ]([\d.]+)',x)
        if m: d[m.group(1)]=float(m.group(2))
    d['run']=f[-1]
    if ('shm' in d['run'])!=('shm' in sys.argv[2:]): continue
    rows.setdefault((d['b'],d['vus'],d['hold']),[]).append(d)
for k in sorted(rows,key=lambda k:(k[1],k[2],st.median(r['us/req'] for r in rows[k]))):
    r=rows[k]; us=[x['us/req'] for x in r]
    print(f"{k[0]:13} {k[1]:>7} {k[2]:>4} n={len(r)} {''.join(x['ok'][0] for x in r)} us/req med {st.median(us):5.2f} ({min(us):.2f}-{max(us):.2f}) user {st.median(x['user'] for x in r):.2f}"
          f" p95 {st.median(x['p95'] for x in r):7.1f} p99 {st.median(x['p99'] for x in r):7.1f} (max {max(x['p99'] for x in r):.1f}) rsspk {max(x['rsspk'] for x in r):.0f} cgpk {max(x['cgpeak'] for x in r):.0f} cpu {st.median(x['cpu'] for x in r):.0f}%")
