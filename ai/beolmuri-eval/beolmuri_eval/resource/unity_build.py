"""Export the real Unity player with opt-in diagnostics and compile it unsigned."""
from pathlib import Path
from ..config import repository
from ..storage import atomic_json
from .tools import run_tool


def build_unity_app(*, unity_editor, dialogue_content, progress=lambda **kw:None):
    root=repository();editor=Path(unity_editor).expanduser().resolve()
    content=Path(dialogue_content).expanduser().resolve()
    if not editor.is_file():raise ValueError('Unity executable missing')
    if not content.is_file() or content.name!='dialogue-content.json':raise ValueError('compiled dialogue-content.json required')
    out=root/'ios/.artifacts/unity-resource-benchmark';out.mkdir(parents=True,exist_ok=True)
    export=out/'UnityExport'
    # The existing builder includes authored scenes, native dependencies, and all companion retrieval assets.
    logs=run_tool(['/usr/bin/env','PETAI_DIALOGUE_CONTENT='+str(content),editor,'-batchmode','-nographics','-quit',
        '-acceptSoftwareTermsForThisRunOnly','-projectPath',root/'unity','-buildTarget','iOS',
        '-executeMethod','PetAI.Editor.PetAIProjectBuilder.BuildForCi','-customBuildPath',export,
        '-applicationIdentifier','com.byeolmuri.app','-devBuild','false','-resourceBench','true','-logFile','-'],
        out/'export-logs',timeout=1800,progress=progress)
    derived=out/'DerivedData'
    compile_logs=run_tool(['xcodebuild','-project',export/'Unity-iPhone.xcodeproj','-scheme','Unity-iPhone',
        '-configuration','Release','-sdk','iphoneos','-destination','generic/platform=iOS',
        '-derivedDataPath',derived,'CODE_SIGNING_ALLOWED=NO','build'],out/'compile-logs',timeout=1800,progress=progress)
    app=derived/'Build/Products/Release-iphoneos/ProductName.app'
    if not (app/'Info.plist').is_file():raise RuntimeError('compiled Unity app not found')
    result=dict(target='unity',profile='unity-memory',app=str(app),signed=False,
                device_verified=False,export_logs=str(logs),compile_logs=str(compile_logs))
    atomic_json(out/'build.json',result)
    return result
