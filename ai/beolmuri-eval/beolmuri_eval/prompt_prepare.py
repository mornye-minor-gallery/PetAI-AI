"""Wire native measurements into Swift composition without reimplementing selection."""


def prepare_prompt(swift, native, *, configuration, case, history, memories,
                   max_num_tokens, prompt_budget=None, timeout=180, session_checkpoint=None, world_info_seed=None):
    payload = dict(configuration=configuration, characterName=case['character_name'],
                   userMessage=case['user_message'], history=history, memories=memories)
    retrieval = configuration.get('retrieval')
    def embed(request):
        result = native.call('embed_query', text=request['text'], timeout=timeout,
                             embedding_model=retrieval['model'], embedding_tokenizer=retrieval['tokenizer'])
        return {'vector': result['vector'], 'identity': result['identity']}
    if retrieval:
        # Assets stay external because model weights do not belong in run snapshots.
        # Their content identity is also checked against the index by shared Swift.
        payload['retrievalDirectory'] = retrieval['directory']
        payload['embedding_handler'] = embed
    if session_checkpoint is not None:
        payload['history'] = []
        payload['sessionCheckpoint'] = session_checkpoint
    context = dict(configuration.get('world_info_context', {}))
    context.update(case.get('world_info_context', {}))
    if world_info_seed is not None:
        context['randomSeed'] = world_info_seed
    if context:
        payload['worldInfoContext'] = context
    if configuration.get('worldInfo', {}).get('rules', {}).get('vector') is not None and 'vectorMatches' not in context:
        raise ValueError('vector retrieval requires explicit recorded vectorMatches for this turn')
    payload['exampleDialogue'] = case.get('example_dialogue', configuration.get('example_dialogue', ''))
    payload['memories'] = case.get('memories', memories)
    if prompt_budget is None:
        # Saved byte-budget experiments are an explicit reproducibility consumer.
        return swift.call('prepare', **payload)
    if prompt_budget['output_tokens'] >= max_num_tokens:
        raise ValueError('output reservation must be smaller than context capacity')

    def measure(request):
        remaining = min(timeout, request["remaining_seconds"])
        if request['measurement'] == 'count_tokens':
            return native.call('count_tokens', text=request['text'], timeout=remaining)['tokens']
        if request['measurement'] == 'measure_input':
            model_input = request['input']
            if model_input['format'] != 'systemAndUserText':
                raise ValueError('unsupported model input format')
            result = native.call('measure_prompt', system_prompt=model_input['systemPrompt'],
                                 message=model_input['userPrompt'], sampling=request['sampling'], timeout=remaining)
            if result['max_num_tokens'] != max_num_tokens:
                raise ValueError('loaded engine capacity differs from prompt budget')
            return result['input_tokens']
        raise ValueError('unsupported token measurement')

    return swift.call('prepare', **payload, timeout=timeout,
                      tokenBudget={'memoryTokens': prompt_budget['memory_tokens'],
                                   'contextTokens': max_num_tokens,
                                   'outputTokens': prompt_budget['output_tokens']},
                      measurerID='litert-lm-0.13.1-native-gpu', measurement_handler=measure)
