import subprocess,os,json
from pathlib import Path
root=Path(__file__).parent
env=os.environ.copy();env['TMPDIR']=str(root/'tmp')
cases=['persisted-owner-identity','independent-owner-reader','owner-boot-offset','actual-stale-birth']
results=[]
for case in cases:
 cmd=['Rscript','--vanilla','tests/funding-service/test-process-rss.R','/home/grauk/.local/share/relm/phase8/R-library','--case',case]
 with (root/(case+'.log')).open('w') as f:r=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
 results.append({'case':case,'command':cmd,'returncode':r.returncode})
 print(case,r.returncode,flush=True)
(root/'affected-results.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(x['returncode']==0 for x in results)
