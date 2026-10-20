"""Prepare a new, unopened Codex acceptance workspace from a reviewed bundle.

Copies only project-local configuration and the shipped Skill. Does not start
Codex, run a hook, grant trust, create a chat, or modify any existing project.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import shutil


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(delivery, bundle, workspace):
    delivery = delivery.resolve(strict=True)
    bundle = bundle.resolve(strict=True)
    workspace = workspace.absolute()
    if workspace.exists() or workspace.is_symlink():
        raise ValueError('Workspace exists; choose a new directory.')
    workspace.parent.resolve(strict=True)
    manifest = json.loads((delivery / 'manifest.json').read_text(encoding='utf-8-sig'))
    architecture = manifest.get('architecture')
    targets = {
        'windows-x64': ('.exe', 'Windows', 'app/info_desktop.exe'),
        'macos-arm64': ('', 'macOS ARM64', 'app/info_desktop.app'),
    }
    if architecture not in targets:
        raise ValueError('Unsupported delivery architecture.')
    suffix, platform_name, app_relative = targets[architecture]
    entries = {entry['path'].replace('\\', '/'): entry for entry in manifest['files']}

    def shipped(relative):
        path = delivery / relative
        entry = entries[relative]
        if path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
            raise ValueError('Delivery no longer matches its manifest.')
        return path

    binaries = [name + suffix for name in
                ['info-codex', 'info-codex-hook', 'info-runtime-worker']]
    for name in binaries:
        if digest(bundle / name) != digest(shipped('cli/' + name)):
            raise ValueError('Bundle binary differs from the delivered version.')
    references = ['credential-use.md', 'information-files.md']
    skill = bundle / 'skills/agent-info-access'
    for name in references:
        if digest(skill / 'references' / name) != digest(shipped('cli/template/references/' + name)):
            raise ValueError('Bundle reference differs from the delivered version.')
    original_skill = shipped('cli/template/SKILL.md').read_text(encoding='utf-8')
    expected_skill = f'{original_skill}\nBundle executable: `{bundle.as_posix()}/info-codex{suffix}`.\n'
    if (skill / 'SKILL.md').read_text(encoding='utf-8') != expected_skill:
        raise ValueError('Unexpected Skill contents or executable path.')
    hooks_path = bundle / 'hooks.json'
    configuration = json.loads(hooks_path.read_text(encoding='utf-8'))
    if set(configuration) != {'description', 'hooks'}:
        raise ValueError('Unexpected hook configuration fields.')
    hooks = configuration['hooks']
    if set(hooks) != {'SessionStart', 'SubagentStart', 'SessionEnd'}:
        raise ValueError('Unexpected hook events.')
    for event, timeout in [('SessionStart', 15), ('SubagentStart', 5), ('SessionEnd', 3)]:
        groups = hooks[event]
        if len(groups) != 1 or len(groups[0]['hooks']) != 1:
            raise ValueError('Unexpected hook count.')
        expected_group_keys = {'hooks', 'matcher'} if event == 'SessionStart' else {'hooks'}
        if set(groups[0]) != expected_group_keys:
            raise ValueError('Unexpected hook matcher settings.')
        if event == 'SessionStart' and groups[0]['matcher'] != '^(startup|resume|clear|compact|fork)$':
            raise ValueError('Unexpected SessionStart matcher.')
        hook = groups[0]['hooks'][0]
        if set(hook) != {'type', 'command', 'commandWindows', 'timeout', 'additionalContextLimit'}:
            raise ValueError('Unexpected hook handler fields.')
        hook_path = f'{bundle.as_posix()}/info-codex-hook{suffix}'
        quoted_posix = "'" + hook_path.replace("'", "'\"'\"'") + "'"
        if hook['command'] != quoted_posix:
            raise ValueError('Unexpected POSIX hook target.')
        encoded = hook['commandWindows'].split()
        if len(encoded) != 5 or encoded[:4] != ['powershell.exe', '-NoProfile', '-NonInteractive', '-EncodedCommand']:
            raise ValueError('Unexpected Windows command wrapper.')
        command = base64.b64decode(encoded[4], validate=True).decode('utf-16-le')
        if command != "& '" + hook_path.replace("'", "''") + "'":
            raise ValueError('Unexpected Windows hook target.')
        if hook['timeout'] != timeout or hook['type'] != 'command' or hook['additionalContextLimit'] != 0:
            raise ValueError('Unexpected hook execution settings.')

    workspace.mkdir()
    copies = {'.codex/hooks.json': hooks_path, '.agents/skills/agent-info-access/SKILL.md': skill / 'SKILL.md'}
    copies.update({f'.agents/skills/agent-info-access/references/{name}': skill / 'references' / name for name in references})
    for relative, source in copies.items():
        target = workspace / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if digest(target) != digest(source):
            raise ValueError('Prepared project copy differs from the reviewed source.')
    cases = [
        ('client-trust', '正式客户端识别项目Skill和准确hook定义，用户审查并信任'),
        ('private-stdin', '真实执行工具经独立stdin传递私密关联，父shell/argv/普通日志不含能力引用'),
        ('partial-approval', '聊天A申请两个字段，只批一个；已批读取成功，未批拒绝'),
        ('multiple-cli-calls', '同一聊天多个CLI进程复用已批范围，不重复审批、不续期'),
        ('chat-isolation', '独立聊天B只拿A的公开ID时不能获得A的权限'),
        ('revoke-and-resume', '手动撤销后恢复聊天不能复活权限'),
        ('session-end', '真实根聊天结束使其所有启动代际和已委托许可失效'),
        ('application-restart', '应用退出/重启后旧关联失效，须新连接和新申请'),
        ('same-root-sharing', '主子共享真人场景由用户另行安排，本脚本不启动子Agent'),
        ('context-lifecycle', '真实compact/resume保留有效上下文但不续期，fork/clear不继承旧授权；缺失引用明确重新连接'),
        ('non-root-events', '真实Stop/Interrupt/子结束不结束根会话，记录实际事件与顺序'),
        ('credential-reuse', '同一次凭据批准后多次操作及原操作重查，不重复审批或重放'),
        ('ordinary-file-delivery', '普通附件部分批准、领取、同机实际消费与释放，旧关联被拒绝'),
    ]
    (workspace / 'acceptance-cases.json').write_text(
        json.dumps([dict(id=key, expected=expected, state='not_run') for key, expected in cases], ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    readme = f'''Codex / {platform_name} 同版本实机验收项目

软件来源：{manifest['sourceCommit']}，版本：{manifest['release']}
独立项目：{workspace.as_posix()}
被引用的SDK-free材料：{bundle.as_posix()}
桌面程序：{(delivery / app_relative).as_posix()}

这只是尚未在Codex打开、注册或信任的项目材料，不是实机验收通过记录。
没有修改当前项目、用户级hook、个人Skill或信任配置；没有启动聊天或子Agent。
保留上述bundle位置；移动后须重新生成、重新审查准确的hook定义。

开始之前先在原开发会话说明可以配合。由开发会话启动独立虚构资料库的应用，
确认服务可用后，再由用户把本目录作为项目打开，并通过客户端正式入口审查与信任
.codex/hooks.json；CLI官方入口为/hooks，桌面入口需以实际客户端提供的界面为准。
若入口不存在或hook未受信任，保留现象，不绕过信任，也不手动伪造事件冒充客户端。
不要在尚无测试服务时先开启测试聊天，不访问真实资料库。

按acceptance-cases.json逐项留证。聊天A可使用以下提示：
“使用agent-info-access，发现虚构资料的公开目录，申请服务器地址和用户名。
等待我审批，不要因等待超时重复提交；批准后用多个独立CLI进程读取获准字段，
核对有效期不变，再核对未批准字段被拒绝。不要输出私密关联、token或文件内容。”

聊天B必须由用户另开，只提供A的公开请求ID/聊天ID，不把A的私密关联交给B。
真实结束/恢复也由用户操作；主子共享按用户允许的真人场景另行安排。
普通字段、凭据命令、普通附件和焦点填充保持独立流程；能力以实际capabilities为准。
Mac 当前没有焦点填充，不把 Windows 专用说明当作 Mac 可用能力。
记录客户端版本、实际信任入口、公开请求ID和截止时间；所有测试只用虚构资料。

参考官方文档：
https://learn.chatgpt.com/docs/hooks
https://learn.chatgpt.com/docs/build-skills
'''
    (workspace / 'README.txt').write_text(readme, encoding='utf-8')
    proof = dict(
        release=manifest['release'], productSource=manifest['sourceCommit'],
        architecture=architecture,
        bundle=str(bundle), workspace=str(workspace), projectLayoutPrepared=True,
        existingProjectsModified=False, registeredByThisScript=False,
        clientActivationVerified=False, trusted=False, realClientAcceptance=False,
        casesRun=0, files=[dict(path=p.relative_to(workspace).as_posix(), bytes=p.stat().st_size, sha256=digest(p))
                          for p in sorted(workspace.rglob('*')) if p.is_file()],
    )
    (workspace / 'preparation.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--delivery', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    args = parser.parse_args()
    proof = prepare(args.delivery, args.bundle, args.workspace)
    print(json.dumps(dict(workspace=proof['workspace'], prepared=True, clientAcceptance=False), ensure_ascii=False))
