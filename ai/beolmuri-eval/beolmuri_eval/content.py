"""Convert two human-authored YAML files into the shared Swift input JSON."""
import argparse
import json
from pathlib import Path
import yaml
from .evaluation import StrictLoader


def compile_content(character, situation):
    def read(path, allowed):
        value = yaml.load(Path(path).read_text(encoding='utf-8'), Loader=StrictLoader)
        if not isinstance(value, dict) or set(value) - allowed:
            raise ValueError(f'{Path(path).name}: unsupported content fields')
        return value
    character = read(character, {'id', 'name', 'persona', 'examples'})
    situation = read(situation, {'situation', 'knowledge'})
    result = {**character, **situation}
    for key in ('id', 'name', 'persona'):
        if not isinstance(result.get(key), str) or not result[key].strip():
            raise ValueError(f'{key} must be nonempty text')
    for key in ('situation', 'knowledge'):
        result.setdefault(key, '')
        if not isinstance(result[key], str):
            raise ValueError(f'{key} must be text')
    result.setdefault('examples', [])
    if not isinstance(result['examples'], list):
        raise ValueError('examples must be a list')
    for example in result['examples']:
        if (not isinstance(example, dict) or set(example) != {'user', 'assistant'}
                or any(not isinstance(v, str) or not v.strip() for v in example.values())):
            raise ValueError('each example requires user and assistant text')
    return result


def main():
    parser = argparse.ArgumentParser(description='캐릭터 YAML과 상황 YAML을 앱용 JSON으로 변환')
    parser.add_argument('--character', required=True)
    parser.add_argument('--situation', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--retrieval', action='store_true', help='Enable sibling reaction index and approved lore resources')
    args = parser.parse_args()
    content = compile_content(args.character, args.situation)
    if args.retrieval:
        content['retrieval'] = {'reactions': True, 'worldLore': True}
    output = Path(args.output).expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(content, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'작성 완료: {output.name}')


if __name__ == '__main__':
    main()
