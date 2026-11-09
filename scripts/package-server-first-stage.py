#!/usr/bin/env python3
"""Build one fixed-source Linux server and ARM64 Mac online candidate.

No installation, personal configuration, real library or global hook changes.
Build verification is recorded separately from subsequent workflow acceptance.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def capture(command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def clean_source(expected=None):
    subprocess.run(['git', 'diff', '--quiet'], cwd=ROOT, check=True)
    subprocess.run(['git', 'diff', '--cached', '--quiet'], cwd=ROOT, check=True)
    if capture(['git', 'ls-files', '--others', '--exclude-standard']):
        raise RuntimeError('Commit all source files before building')
    commit = capture(['git', 'rev-parse', 'HEAD'])
    if expected is not None and commit != expected:
        raise RuntimeError('Source changed during packaging')
    return commit


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(part)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path,
                        help='New directory under build/macos-adaptation/')
    args = parser.parse_args()
    out = args.output.resolve()
    out.relative_to(ROOT / 'build/macos-adaptation')
    commit = clean_source()
    out.mkdir(parents=True, exist_ok=False)
    logs = out / 'logs'
    logs.mkdir()
    server = out / 'server'
    server.mkdir()
    tag = 'chiyo-server:candidate-' + commit[:12]
    result = {'sourceCommit': commit, 'buildComplete': False,
              'acceptanceComplete': False, 'phases': [], 'serverTag': tag}

    def run(name, command):
        print(name + ': started', flush=True)
        with (logs / (name + '.log')).open('wb') as log:
            completed = subprocess.run(command, cwd=ROOT, stdout=log,
                                       stderr=subprocess.STDOUT)
        result['phases'].append({'name': name, 'exit': completed.returncode})
        print(name + ': ' + str(completed.returncode), flush=True)
        completed.check_returncode()
        clean_source(commit)

    def archive(command, destination):
        with destination.open('wb') as target:
            with gzip.GzipFile(filename='', fileobj=target, mode='wb', mtime=0) as compressed:
                process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE)
                try:
                    shutil.copyfileobj(process.stdout, compressed, 1024 * 1024)
                finally:
                    process.stdout.close()
                    code = process.wait()
        if code:
            raise RuntimeError('Archive export failed')

    try:
        run('macos-package', [sys.executable, str(ROOT / 'scripts/qa/package-macos-isolated.py'),
                              str(out / 'macos')])
        run('server-image', ['docker', 'build', '--platform', 'linux/arm64',
                            '-f', 'apps/server/Dockerfile', '--target', 'runtime',
                            '--build-arg', 'SOURCE_COMMIT=' + commit, '-t', tag, '.'])
        image = json.loads(capture(['docker', 'image', 'inspect', tag]))[0]
        if (image['Architecture'] != 'arm64' or image['Os'] != 'linux'
                or image['Config']['Labels']['org.opencontainers.image.revision'] != commit):
            raise RuntimeError('Server image does not match the fixed source')
        run('compiled-container-recreation', [sys.executable,
            str(ROOT / 'scripts/qa/check-server-container.py'), '--image', tag, '--compiled'])
        archive(['docker', 'save', tag], server / 'image.tar.gz')
        # Rebuild the service without relying on this checkout's ignored cache.
        archive(['git', 'archive', '--format=tar', '--prefix=source/', commit,
                 '.dockerignore', 'apps/server', 'packages/info_core',
                 'packages/info_storage', 'packages/info_workspace',
                 'packages/info_remote', 'packages/info_cli', 'integrations/codex',
                 'third_party/SQLCipher-LICENSE.md', 'scripts/qa/check-server-container.py'],
                server / 'source.tar.gz')
        for name in ['README.md', 'OPERATIONS.md']:
            content = (ROOT / 'apps/server' / name).read_text()
            content = content.replace('](../../',
                '](https://github.com/ShiJiJS/chiyo/blob/' + commit + '/')
            (server / name).write_text(content)
        mac = json.loads((out / 'macos/chiyo/manifest.json').read_text())
        verified = json.loads((out / 'macos/verification.json').read_text())
        if mac['sourceCommit'] != commit or not verified['complete']:
            raise RuntimeError('Mac payload is not the same fixed source')
        (out / 'README.md').write_text(
            '# 知予联网开发候选\n\n'
            f'源码：`{commit}`。Linux ARM64服务、Mac ARM64 App、CLI、worker和说明来自同一提交。\n\n'
            '- `macos/chiyo/README.md`：App连接与使用；同目录包含App、CLI和接入说明。\n'
            '- `server/README.md`、`server/OPERATIONS.md`：服务部署、密钥及维护。\n'
            f'- `docker load --input server/image.tar.gz` 导入镜像 `{tag}`；部署说明中的镜像名换成此名称。\n'
            '- `server/source.tar.gz`：可复现服务构建的源码与锁文件，解压后从source目录按服务说明构建。\n'
            '- `candidate.json`：同源信息、镜像ID和交付文件摘要。\n\n'
            '构建与容器检查不等于完整试用。最终以独立验收记录为准；本包不自动安装、读取日常配置或迁移真实资料。'
            '系统原生人工检查、正式安装迁移、Windows及跨电脑审批未在此声明完成。\n')
        paths = [Path('README.md'), Path('server/image.tar.gz'), Path('server/source.tar.gz'),
                 Path('server/README.md'), Path('server/OPERATIONS.md'),
                 Path('macos/chiyo/manifest.json'), Path('macos') / verified['archive'],
                 Path('macos') / verified['diskImage']]
        result.update(buildComplete=True, serverImageId=image['Id'], architecture='linux-arm64+macos-arm64',
                      macRelease=mac['release'], files=[{
                          'path': p.as_posix(), 'bytes': (out / p).stat().st_size,
                          'sha256': digest(out / p)} for p in paths])
        clean_source(commit)
    finally:
        (out / 'candidate.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print('Matched candidate built: ' + str(out), flush=True)


if __name__ == '__main__':
    main()
