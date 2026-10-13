"""Offline ARM panel regression using real BB8 buffers; source images stay local."""
from pathlib import Path
from zipfile import ZipFile
import argparse
import hashlib
import io
import json
import subprocess
import stream_formats_contract
from PIL import Image

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--samples',type=Path,required=True)
    p.add_argument('--runtime-root',type=Path,required=True)
    p.add_argument('--support-runtime',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--report',type=Path,required=True)
    args=p.parse_args()
    repo=Path(__file__).resolve().parents[1]
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_bytes(b'{"passed":false}\n')
    before=stream_formats_contract.runtime_fingerprint(repo/'webdavmanga.koplugin')
    args.output.mkdir(parents=True,exist_ok=False)
    sample_dir=args.output/'samples';sample_dir.mkdir()
    manifest=[]
    def add(label,image,expected=None,threshold=None):
        name=f'{len(manifest):02d}.gray'
        image=image.convert('L');data=image.tobytes()
        (sample_dir/name).write_bytes(data)
        manifest.append(dict(label=label,file=name,width=image.width,height=image.height,
            expected=expected,threshold=threshold,sha256=hashlib.sha256(data).hexdigest()))
    for dark in (False,True):
        image=Image.new('L',(220,250),0 if dark else 255)
        pix=image.load()
        for y in range(250):
            for x in range(220):
                if any(((x-cx)/40)**2+((y-cy)/48)**2<=1 for cx,cy in ((55,65),(165,65),(55,185),(165,185))):pix[x,y]=255 if dark else 0
        add('borderless-dark' if dark else 'borderless-light',image,4)
    add('blank',Image.new('L',(800,1200),255),0)
    from PIL import ImageDraw
    faint=Image.new('L',(200,240),255);draw=ImageDraw.Draw(faint)
    for x,y,w,h in ((10,20,80,90),(110,20,80,90),(10,140,180,90)):draw.rectangle((x,y,x+w-1,y+h-1),outline=217,width=3)
    add('faint-default40',faint,0,40);add('faint-exact37',faint,3,37)
    for label,background,ink in [('auto-white-faint',255,217),('auto-gray-faint',180,150),('auto-black-white',0,255)]:
        image=Image.new('L',(200,240),background);draw=ImageDraw.Draw(image)
        for x,y,w,h in ((10,20,80,90),(110,20,80,90),(10,140,180,90)):
            draw.rectangle((x,y,x+w-1,y+h-1),outline=ink,width=3)
        add(label,image,{'intelligent-auto':3,'dynamic-auto':3,'web-strong':3})
    for source in [args.samples/'漫画测试11.zip',next(args.samples.glob('*.epub'))]:
        with ZipFile(source) as z:
            candidates=[]
            for name in sorted(z.namelist()):
                if not name.lower().endswith(('.jpg','.jpeg','.png','.webp')):continue
                image=Image.open(io.BytesIO(z.read(name)))
                if image.width>=400 and image.height>=400:candidates.append(name)
            n=len(candidates)
            for index in sorted(set((0,n//8,n//4,n//3,n//2,n*2//3,n*3//4,n-1))):
                image=Image.open(io.BytesIO(z.read(candidates[index])))
                image.thumbnail((1100,1500))
                add(f'{source.suffix}:{index}:{candidates[index]}',image)
    (sample_dir/'samples.json').write_bytes(json.dumps(manifest,ensure_ascii=False).encode())
    cmd=['docker','run','--rm','--platform','linux/arm/v7','--network','none']
    for source,target in [(repo/'webdavmanga.koplugin','/plugin'),(repo/'spec/contracts','/checks'),
            (args.runtime_root,'/native'),(args.support_runtime,'/runtime'),(sample_dir,'/samples'),(args.output,'/output')]:
        cmd+=['--mount',f'type=bind,source={source.resolve()},target={target}'+('' if target=='/output' else ',readonly')]
    cmd+=['-e','LUA_PATH=/plugin/?.lua;/native/?.lua;/native/?/init.lua;/runtime/?.lua;/runtime/?/init.lua;;',
        '-e','LUA_CPATH=/runtime/?.so;;','-e','LD_LIBRARY_PATH=/native/libs',
        'webdavmanga-kindlehf-offline:20260928','luajit','/checks/panel_analysis_native.lua']
    subprocess.run(cmd,check=True)
    for contract in ('dynamic_panel_native.lua','panel_profile_native.lua'):
        subprocess.run(cmd[:-1]+['/checks/'+contract],check=True)
    report=json.loads((args.output/'panel-native-result.json').read_text())
    report['dynamic_native']=json.loads((args.output/'dynamic-native-result.json').read_text())
    report['adaptive_native']=json.loads((args.output/'profile-native-result.json').read_text())
    if before!=stream_formats_contract.runtime_fingerprint(repo/'webdavmanga.koplugin'):
        raise ValueError('Runtime changed during native panel checks')
    report['source_runtime_sha256']=before
    report['passed']=True
    report['contract_sha256']={name:hashlib.sha256((repo/'spec/contracts'/name).read_bytes()).hexdigest()
        for name in ('panel_analysis_native.lua','dynamic_panel_native.lua','panel_profile_native.lua')}
    report.update(scope='ARM emulator: real KOReader BB8; synthetic counts are asserted, real-page visual accuracy still needs device acceptance',
        samples=manifest,module_sha256={name:hashlib.sha256((repo/'webdavmanga.koplugin/webdavmanga'/name).read_bytes()).hexdigest()
            for name in ('panel_detector.lua','panel_analysis.lua','panel_components.lua','panel_gutters.lua','panel_geometry.lua','dynamic_panel_zoom.lua','panel_detection_profile.lua','web_panel_zoom.lua','web_panel_analysis.lua','web_panel_components.lua','panel_session.lua')})
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_bytes((json.dumps(report,ensure_ascii=False,indent=2)+'\n').encode())
    print(json.dumps({'cases':len(report['cases']),'counts':[v['count'] for v in report['cases']],
        'max_seconds':max(v['seconds'] for v in report['cases'])}))

if __name__=='__main__':main()
