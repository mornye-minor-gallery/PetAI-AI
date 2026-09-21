"""Scenario data only. Session clocks and World Info transitions belong to Swift."""
import json


def load_scenarios(text):
    # Local import avoids a cycle with the plan loader.
    from .evaluation import unique_fields, validate, schema_path
    schema = json.loads(schema_path('scenario.schema.json').read_text())
    scenarios, seen = [], set()
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line, object_pairs_hook=unique_fields)
        validate(row, schema, f'scenario line {number}')
        if row['id'] in seen:
            raise ValueError('duplicate scenario id')
        seen.add(row['id'])
        turns = set()
        if not row['character_name'].strip():
            raise ValueError('character_name must not be blank')
        for turn in row['turns']:
            if turn['id'] in turns:
                raise ValueError('duplicate turn id')
            turns.add(turn['id'])
            if not turn['user_message'].strip():
                raise ValueError('user_message must not be blank')
            kind = turn.setdefault('kind', 'dialogue')
            if kind != 'dialogue':
                name = turn.get('called_name', '')
                if not name.strip() or (name == row['character_name']) != (kind == 'correct_name'):
                    raise ValueError('called_name conflicts with case kind')
            elif 'called_name' in turn:
                raise ValueError('dialogue warmup must not declare called_name')
        scenarios.append(row)
    if not scenarios:
        raise ValueError('scenario dataset is empty')
    flatten_scenarios(scenarios)  # Composite IDs must also be unique.
    return scenarios


def flatten_scenarios(scenarios):
    cases, seen = [], set()
    for scenario in scenarios:
        for index, turn in enumerate(scenario['turns']):
            identifier = scenario['id'] + '--' + turn['id']
            if identifier in seen:
                raise ValueError('duplicate composite case id')
            seen.add(identifier)
            cases.append({**turn, 'id': identifier, 'turn_id': turn['id'],
                          'scenario_id': scenario['id'], 'turn_index': index,
                          'pair_id': scenario.get('pair_id', scenario['id']),
                          'character_name': scenario['character_name']})
    return cases


def execution_groups(cases):
    """Flat legacy cases are each their own session, including paired controls."""
    groups, seen = [], set()
    for case in cases:
        scenario = case.get('scenario_id', case['id'])
        if not groups or groups[-1][0] != scenario:
            if scenario in seen:
                raise ValueError('scenario turns must be contiguous')
            seen.add(scenario)
            groups.append((scenario, []))
        groups[-1][1].append(case)
    return groups
