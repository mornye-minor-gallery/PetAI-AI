"""Build an isolated benchmark app; normal configurations never enable the feature."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
from ..config import repository
from ..storage import atomic_json
from .tools import run_tool


def build_app(*, signed=False, progress=lambda **kw: None):
    root=repository()
    out=root/'ios/.artifacts/resource-benchmark'
    out.mkdir(parents=True,exist_ok=True)
    source_roots=['ios/ResourceBench/Sources','ios/EdgeLLMLab/EdgeLLMLab','ios/EdgeLLM/Sources',
                  'ios/ThirdParty/LiteRTLM/Sources']
    entries={}
    for source_root in source_roots:
        for path in sorted((root/source_root).rglob('*.swift')):
            entries[str(path.relative_to(root))]=hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ('CLiteRTLM.provenance','EmbeddingNative.provenance'):
        path=root/'ios/.artifacts'/name
        if not path.is_file(): raise ValueError('native dependency provenance missing: '+name)
        entries['native/'+name]=hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ('ios/EdgeLLMLab/EdgeLLMLab.xcodeproj/project.pbxproj', 'ios/EdgeLLMLab/EdgeLLMLab/Info.plist',
                 'ios/EdgeLLM/Package.swift', 'ios/ThirdParty/LiteRTLM/Package.swift'):
        entries[name]=hashlib.sha256((root/name).read_bytes()).hexdigest()
    for path in sorted((root/'ios/.artifacts/CLiteRTLM.xcframework').rglob('*')):
        if path.is_file():
            with path.open('rb') as handle:entries[str(path.relative_to(root))]=hashlib.file_digest(handle,'sha256').hexdigest()
    tool_version=subprocess.run(['xcodebuild','-version'],check=True,capture_output=True,text=True).stdout.strip()
    options=dict(configuration='Release',conditions='RESOURCE_BENCH',deployment_target='26.0',coverage=False)
    build_id=hashlib.sha256(json.dumps(dict(sources=entries,tool=tool_version,options=options),sort_keys=True).encode()).hexdigest()
    info=plistlib.loads((root/'ios/EdgeLLMLab/EdgeLLMLab/Info.plist').read_bytes())
    info['ResourceBenchBuildID']=build_id
    info['ResourceBenchProtocolVersion']=1
    info['CFBundleDisplayName']='별무리 측정'
    info_path=out/'Info.plist'; info_path.write_bytes(plistlib.dumps(info))
    argv=['xcodebuild','-project',root/'ios/EdgeLLMLab/EdgeLLMLab.xcodeproj','-scheme','EdgeLLMLab',
          '-configuration','Release','-sdk','iphoneos','-destination','generic/platform=iOS',
          '-derivedDataPath',out/'DerivedData',
          'SWIFT_ACTIVE_COMPILATION_CONDITIONS=RESOURCE_BENCH',
          'PRODUCT_BUNDLE_IDENTIFIER=com.mornye.EdgeLLMLab.resourcebench',
          'IPHONEOS_DEPLOYMENT_TARGET=26.0','CLANG_ENABLE_CODE_COVERAGE=NO',
          'INFOPLIST_FILE='+str(info_path)]
    if signed: argv+=['-allowProvisioningUpdates']
    else: argv+=['CODE_SIGNING_ALLOWED=NO']
    argv+=['build']
    logs=run_tool(argv,out/'builds',timeout=1800,progress=progress)
    app=out/'DerivedData/Build/Products/Release-iphoneos/EdgeLLMLab.app'
    built=plistlib.loads((app/'Info.plist').read_bytes())
    if built.get('ResourceBenchBuildID')!=build_id: raise RuntimeError('build identity missing from compiled app')
    metadata=dict(build_id=build_id,app=str(app),signed=signed,sources=entries,tool_version=tool_version,options=options,logs=str(logs),
                  executable_sha256=hashlib.sha256((app/built['CFBundleExecutable']).read_bytes()).hexdigest())
    atomic_json(out/'build.json',metadata)
    return metadata
