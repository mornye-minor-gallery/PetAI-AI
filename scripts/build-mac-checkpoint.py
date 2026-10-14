"""Build the same patched native core for Mac checkpoint integration tests."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

from litertlm_android_profile import prepare_source, download
from litertlm_prefix_cursor import REVISION, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output-base', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--bazel', default='bazel')
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    # Both CPU controls and GPU tests use the identical GPU-enabled build.
    prepare_source(source, 'gpu')
    output.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
    base = [args.bazel, '--output_base=' + str(args.output_base.resolve())]
    options = ['--config=macos_arm64', '--macos_sdk_version=' + sdk,
               '--macos_minimum_os=14.0', '--define=LITERT_LM_FST_CONSTRAINTS_DISABLED=1',
               '--define=litert_runtime_link_mode=dynamic']
    targets = ['//c:litert-lm', '@litert//litert/c:litert_runtime_c_api_dylib']
    lock = source / '.petai-product-build-lock'
    lock.mkdir()
    try:
        subprocess.run(base + ['build', *options, '--jobs=4', '--progress_report_interval=15', *targets],
                       cwd=source, check=True)
        root = Path(subprocess.check_output(base + ['info', 'execution_root'], cwd=source, text=True).strip())
        for target, name in zip(targets, ['libkvcheckpoint.dylib', 'libLiteRt.dylib']):
            paths = subprocess.check_output(base + ['cquery', *options, '--output=files', target],
                                            cwd=source, text=True).splitlines()
            if len(paths) != 1:
                raise ValueError('Expected one native library: ' + target)
            shutil.copyfile(root / paths[0], output / name)
        # Keep the existing Swift module's link name. Record the final binary
        # hash after the normal Mach-O install-name adjustment and ad-hoc signing.
        library = output / 'libkvcheckpoint.dylib'
        subprocess.run(['install_name_tool', '-id', '@rpath/libkvcheckpoint.dylib', str(library)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(library)], check=True)
        for name in ['libLiteRtMetalAccelerator.dylib', 'libLiteRtTopKMetalSampler.dylib']:
            pointer = (source / 'prebuilt/macos_arm64' / name).read_text()
            match = re.fullmatch(r'version https://git-lfs.github.com/spec/v1\noid sha256:([a-f0-9]{64})\nsize ([0-9]+)\n?', pointer)
            if not match:
                raise ValueError('Expected a verified source archive LFS pointer: ' + name)
            download(f'https://media.githubusercontent.com/media/mornye-minor-gallery/LiteRT-LM/{REVISION}/prebuilt/macos_arm64/{name}',
                     output / name, match[1])
        prepare_source(source, 'gpu')
        profile = json.loads((source / '.petai-android-profile.json').read_text())
        (output / 'provenance.json').write_text(json.dumps({
            'source_revision': REVISION, 'patches': profile['inputs'], 'platform': 'macos-arm64',
            'build_options': options, 'libraries': {p.name: sha(p) for p in output.glob('*.dylib')}
        }, indent=2))
    finally:
        lock.rmdir()


if __name__ == '__main__':
    main()
