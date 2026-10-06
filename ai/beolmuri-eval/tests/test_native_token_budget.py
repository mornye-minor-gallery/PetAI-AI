import unittest
from unittest.mock import Mock, PropertyMock

from beolmuri_eval.native_worker import NativeRuntime


class NativeTokenBudgetTests(unittest.TestCase):
    def runtime(self):
        runtime = NativeRuntime.__new__(NativeRuntime)
        runtime.max_num_tokens = 100
        runtime.reserved_output_tokens = 30
        runtime.engine = Mock()
        runtime.engine.tokenize.return_value = [1] * 60
        runtime.conversation = Mock(token_count=10)
        runtime.conversation.render_message_to_string.return_value = '<native template>'
        runtime.conversation.send_message_async.return_value = iter([])
        return runtime

    def test_full_reservation_checked_before_generation_and_again_for_retry(self):
        runtime = self.runtime()
        self.assertEqual(runtime.generate('question')['input_tokens'], 70)
        runtime.conversation.token_count = 11
        runtime.conversation.send_message_async.reset_mock()
        with self.assertRaisesRegex(ValueError, 'reserved output 30'):
            runtime.generate('retry')
        runtime.conversation.send_message_async.assert_not_called()

    def test_probe_uses_requested_settings_without_changing_live_conversation(self):
        runtime = self.runtime()
        active = runtime.conversation
        probe = Mock(token_count=5)
        probe.render_message_to_string.return_value = '<thinking-specific template>'
        runtime._create_conversation = Mock(return_value=probe)
        settings = {'thinking': True, 'max_output_tokens': 30}
        self.assertEqual(runtime.measure_prompt('system', 'user', settings)['input_tokens'], 65)
        runtime._create_conversation.assert_called_once_with('system', settings, seed=0)
        self.assertIs(runtime.conversation, active)
        probe.close.assert_called_once()
        active.close.assert_not_called()
        probe.send_message_async.assert_not_called()

    def test_probe_is_closed_on_failure_and_null_text_never_reaches_c_api(self):
        runtime = self.runtime()
        probe = Mock(token_count=5)
        probe.render_message_to_string.side_effect = RuntimeError('render failed')
        runtime._create_conversation = Mock(return_value=probe)
        with self.assertRaisesRegex(RuntimeError, 'render failed'):
            runtime.measure_prompt('system', 'user', {})
        probe.close.assert_called_once()
        with self.assertRaisesRegex(ValueError, 'embedded nulls'):
            runtime.count_tokens('before\0after')
        runtime.engine.tokenize.assert_not_called()

    def test_measurement_rejects_mutated_kv(self):
        runtime = self.runtime()
        type(runtime.conversation).token_count = PropertyMock(side_effect=[10, 11])
        with self.assertRaisesRegex(RuntimeError, 'changed native token state'):
            runtime.measure('question')

    def test_ordered_probe_preserves_later_system_and_live_state(self):
        runtime = self.runtime()
        active = runtime.conversation
        probe = Mock(token_count=0)
        probe.render_message_to_string.return_value = '<ordered template>'
        runtime._create_conversation = Mock(return_value=probe)
        prefix = [{'role': 'system', 'text': 'fixed'}, {'role': 'user', 'text': 'history'},
                  {'role': 'system', 'text': 'dynamic'}]
        model_input = {'messages': prefix + [{'role': 'user', 'text': 'current'}]}
        settings = {'thinking': False, 'max_output_tokens': 30}
        self.assertEqual(runtime.measure_input(model_input, settings)['input_tokens'], 60)
        runtime._create_conversation.assert_called_once_with(None, settings, seed=0, initial_messages=prefix)
        probe.render_message_to_string.assert_called_once_with('current')
        probe.close.assert_called_once()
        active.close.assert_not_called()
        self.assertIs(runtime.conversation, active)

    def test_invalid_ordered_input_is_rejected_before_replacing_live_state(self):
        runtime = self.runtime()
        runtime._create_conversation = Mock()
        for messages in [[], [{'role': 'system', 'text': 'no current input'}],
                         [{'role': 'tool', 'text': 'unsupported'}, {'role': 'user', 'text': 'current'}]]:
            with self.subTest(messages=messages), self.assertRaises(ValueError):
                runtime.start_input({'messages': messages}, {}, seed=1)
        runtime._create_conversation.assert_not_called()
        runtime.conversation.close.assert_not_called()
