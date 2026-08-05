#!/usr/bin/env python3
"""Aggregate the HTTP end-to-end results (same methodology as aggregate-driver.py).

Lê os CSVs http_<stack>_<endpoint>_<topo>_c<vcpu>_s<sessao>.csv (colunas
stack,endpoint,topology,vcpu,session,rep,rps,p50_us,p75_us,p90_us,p99_us).
Unit of inference = mean rps per SESSION (mean of its reps). N sessions -> CI95
Student-t, CV%, Welch + Mann-Whitney nos pares adjacentes de stacks por
(endpoint,topologia,vcpu).

Uso: python3 aggregate-http.py <outdir>
Escreve: <outdir>/agg_http_stats.csv, agg_http_significance.csv (+ resumo).
"""
import sys, os, csv, math, statistics

T = {1:12.706,2:4.303,3:3.182,4:2.776,5:2.571,6:2.447,7:2.365,8:2.306,9:2.262,10:2.228}
def tcrit(df): return T.get(df,1.96) if df>0 else float('nan')
def _betacf(a,b,x):
    MAXIT,EPS,FP=200,3e-12,1e-300; qab,qap,qam=a+b,a+1,a-1; c=1.0; d=1-qab*x/qap
    if abs(d)<FP: d=FP
    d=1/d; h=d
    for m in range(1,MAXIT+1):
        m2=2*m; aa=m*(b-m)*x/((qam+m2)*(a+m2)); d=1+aa*d
        if abs(d)<FP: d=FP
        c=1+aa/c
        if abs(c)<FP: c=FP
        d=1/d; h*=d*c; aa=-(a+m)*(qab+m)*x/((a+m2)*(qap+m2)); d=1+aa*d
        if abs(d)<FP: d=FP
        c=1+aa/c
        if abs(c)<FP: c=FP
        d=1/d; de=d*c; h*=de
        if abs(de-1)<EPS: break
    return h
def betai(a,b,x):
    if x<=0: return 0.0
    if x>=1: return 1.0
    bt=math.exp(math.lgamma(a+b)-math.lgamma(a)-math.lgamma(b)+a*math.log(x)+b*math.log(1-x))
    return bt*_betacf(a,b,x)/a if x<(a+1)/(a+b+2) else 1-bt*_betacf(b,a,1-x)/b
def welch(a,b):
    n1,n2=len(a),len(b)
    if n1<2 or n2<2: return (float('nan'),float('nan'),float('nan'))
    m1,m2=statistics.mean(a),statistics.mean(b); v1,v2=statistics.variance(a),statistics.variance(b)
    se2=v1/n1+v2/n2
    if se2==0: return (float('inf'),float('nan'),0.0)
    t=(m1-m2)/math.sqrt(se2); df=se2**2/((v1/n1)**2/(n1-1)+(v2/n2)**2/(n2-1))
    return (t,df,betai(df/2,0.5,df/(df+t*t)))
def mw(a,b):
    n1,n2=len(a),len(b); N=n1+n2
    if n1==0 or n2==0: return float('nan')
    lab=sorted([(v,0) for v in a]+[(v,1) for v in b]); ranks=[0.0]*N; i=0
    while i<N:
        j=i
        while j+1<N and lab[j+1][0]==lab[i][0]: j+=1
        r=(i+j)/2+1
        for k in range(i,j+1): ranks[k]=r
        i=j+1
    R1=sum(ranks[k] for k in range(N) if lab[k][1]==0); U1=R1-n1*(n1+1)/2; U=min(U1,n1*n2-U1)
    mu=n1*n2/2; sd=math.sqrt(n1*n2*(N+1)/12)
    return math.erfc((abs(U-mu)-0.5)/sd/math.sqrt(2)) if sd else float('nan')
def stats(v):
    n=len(v); m=statistics.mean(v); sd=statistics.stdev(v) if n>1 else 0.0
    cv=100*sd/m if m else 0.0; h=tcrit(n-1)*sd/math.sqrt(n) if n>1 else 0.0
    return n,m,sd,cv,m-h,m+h

def main():
    outdir=sys.argv[1]
    # combo -> {session -> {'rps':[...], 'p99':[...]}}
    data={}
    for fn in os.listdir(outdir):
        if not (fn.startswith("http_") and fn.endswith(".csv")): continue
        if fn.startswith("agg_"): continue
        for r in csv.DictReader(open(os.path.join(outdir,fn))):
            try:
                rps=float(r["rps"]); p99=float(r["p99_us"])
            except (ValueError,KeyError): continue
            k=(r["stack"],r["endpoint"],r["topology"],r["vcpu"]); s=r["session"]
            d=data.setdefault(k,{}).setdefault(s,{"rps":[],"p99":[]})
            d["rps"].append(rps); d["p99"].append(p99)
    rows=[]
    combo_sessions={}
    for k,byses in data.items():
        svals=[statistics.mean(v["rps"]) for _,v in sorted(byses.items()) if v["rps"]]
        p99s=[statistics.mean(v["p99"]) for _,v in sorted(byses.items()) if v["p99"]]
        if not svals: continue
        combo_sessions[k]=svals
        n,m,sd,cv,lo,hi=stats(svals)
        mean_p99=statistics.mean(p99s) if p99s else float('nan')
        rows.append((*k,n,m,sd,cv,lo,hi,mean_p99))
    sp=os.path.join(outdir,"agg_http_stats.csv")
    with open(sp,"w") as f:
        f.write("stack,endpoint,topology,vcpu,n_sessions,mean_rps,sd,cv_pct,ci95_lo,ci95_hi,mean_p99_us\n")
        for r in sorted(rows,key=lambda x:(x[3],x[1],x[2],-x[5])):
            f.write(f"{r[0]},{r[1]},{r[2]},{r[3]},{r[4]},{r[5]:.1f},{r[6]:.1f},{r[7]:.2f},{r[8]:.1f},{r[9]:.1f},{r[10]:.1f}\n")
    # significância: por (endpoint,topo,vcpu), rankear stacks
    groups={}
    for r in rows: groups.setdefault((r[1],r[2],r[3]),[]).append(r)
    sig=[]
    for g,rs in groups.items():
        rs=sorted(rs,key=lambda x:-x[5])
        for i in range(len(rs)-1):
            a=combo_sessions[(rs[i][0],g[0],g[1],g[2])]; b=combo_sessions[(rs[i+1][0],g[0],g[1],g[2])]
            ma,mb=statistics.mean(a),statistics.mean(b); dp=100*(ma-mb)/mb if mb else float('nan')
            _,_,wp=welch(a,b); mwp=mw(a,b)
            verd="distinguível" if (wp==wp and wp<0.05) else "inconclusivo"
            sig.append((g,f"{rs[i][0]} vs {rs[i+1][0]}",ma,mb,dp,wp,mwp,verd))
    sgp=os.path.join(outdir,"agg_http_significance.csv")
    with open(sgp,"w") as f:
        f.write("endpoint,topology,vcpu,pair,rps_a,rps_b,delta_pct,welch_p,mw_p,verdict\n")
        for g,pair,ma,mb,d,wp,mwp,v in sig:
            f.write(f"{g[0]},{g[1]},{g[2]},{pair},{ma:.1f},{mb:.1f},{d:+.1f},{wp:.4g},{mwp:.4g},{v}\n")
    print(f"=== HTTP - rps per session (+/-CI95). combos={len(rows)}, sig-pairs={len(sig)} ===")
    print(f"[ok] {sp}\n[ok] {sgp}")

if __name__=="__main__":
    main()
