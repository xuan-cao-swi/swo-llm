# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'
require 'json'

require_relative '../../../../../lib/swo/llm/ruby_llm/opentelemetry/instrumentation/ruby_llm/patches/utils'

describe OpenTelemetry::Instrumentation::RubyLLM::Patches::Utils do
  let(:utils_class) do
    Class.new do
      include OpenTelemetry::Instrumentation::RubyLLM::Patches::Utils
    end.new
  end

  describe '#get_property_value' do
    it 'retrieves value from hash with string key' do
      obj = { 'name' => 'test' }
      _(utils_class.get_property_value(obj, 'name')).must_equal 'test'
    end

    it 'retrieves value from hash with symbol key' do
      obj = { name: 'test' }
      _(utils_class.get_property_value(obj, :name)).must_equal 'test'
    end

    it 'retrieves value from object with method' do
      obj = Struct.new(:name).new('test')
      _(utils_class.get_property_value(obj, :name)).must_equal 'test'
    end

    it 'returns nil for non-existent property in hash' do
      obj = { name: 'test' }
      _(utils_class.get_property_value(obj, 'missing')).must_be_nil
    end

    it 'returns nil for non-existent method in object' do
      obj = Struct.new(:name).new('test')
      _(utils_class.get_property_value(obj, :missing)).must_be_nil
    end
  end

  describe '#extract_tool_calls' do
    it 'returns nil when tool_calls is not present' do
      message = { role: 'assistant', content: 'Hello' }
      _(utils_class.extract_tool_calls(message, true)).must_be_nil
    end

    it 'returns nil when tool_calls is empty' do
      message = { tool_calls: {} }
      _(utils_class.extract_tool_calls(message, true)).must_be_nil
    end

    it 'extracts tool calls from hash structure' do
      message = {
        tool_calls: {
          'call_123' => {
            name: 'get_weather',
            arguments: { location: 'NYC' }
          }
        }
      }

      result = utils_class.extract_tool_calls(message, true)
      _(result).wont_be_nil
      _(result.length).must_equal 1
      _(result[0][:id]).must_equal 'call_123'
      _(result[0][:name]).must_equal 'get_weather'
      _(result[0][:arguments]).must_include 'location'
    end

    it 'omits arguments when capture_content is false' do
      message = {
        tool_calls: {
          'call_123' => {
            name: 'get_weather',
            arguments: { location: 'NYC' }
          }
        }
      }

      result = utils_class.extract_tool_calls(message, false)
      _(result[0][:arguments]).must_be_nil
    end

    it 'extracts multiple tool calls' do
      message = {
        tool_calls: {
          'call_1' => { name: 'get_weather', arguments: { loc: 'NYC' } },
          'call_2' => { name: 'get_time', arguments: { tz: 'EST' } }
        }
      }

      result = utils_class.extract_tool_calls(message, true)
      _(result.length).must_equal 2
    end
  end

  describe '#extract_content_text' do
    it 'returns string content directly' do
      _(utils_class.extract_content_text('Hello world')).must_equal 'Hello world'
    end

    it 'extracts text from hash with text key' do
      content = { text: 'Hello from hash' }
      _(utils_class.extract_content_text(content)).must_equal 'Hello from hash'
    end

    it 'converts other types to string' do
      _(utils_class.extract_content_text(123)).must_equal '123'
    end
  end

  describe '#message_to_log_event' do
    it 'creates event for user message' do
      message = Struct.new(:role, :content).new('user', 'Hello!')

      event = utils_class.message_to_log_event(message, capture_content: true)

      _(event[:event_name]).must_equal 'gen_ai.user.message'
      _(event[:attributes]['gen_ai.provider.name']).must_equal 'ruby_llm'
      _(event[:body][:content]).must_equal 'Hello!'
    end

    it 'creates event for assistant message with tool calls' do
      message = Struct.new(:role, :content, :tool_calls).new(
        'assistant',
        'Let me check that.',
        { 'call_1' => { name: 'search', arguments: { q: 'test' } } }
      )

      event = utils_class.message_to_log_event(message, capture_content: true)

      _(event[:event_name]).must_equal 'gen_ai.assistant.message'
      _(event[:body][:content]).must_equal 'Let me check that.'
      _(event[:body][:tool_calls]).wont_be_nil
    end

    it 'creates event for tool message with tool_call_id' do
      message = Struct.new(:role, :content, :tool_call_id).new(
        'tool',
        'Result data',
        'call_123'
      )

      event = utils_class.message_to_log_event(message, capture_content: true)

      _(event[:event_name]).must_equal 'gen_ai.tool.message'
      _(event[:body][:tool_call_id]).must_equal 'call_123'
    end

    it 'omits content when capture_content is false' do
      message = Struct.new(:role, :content).new('user', 'Secret message')

      event = utils_class.message_to_log_event(message, capture_content: false)

      _(event[:body]).must_be_nil
    end
  end

  describe '#response_to_log_event' do
    it 'creates event from response' do
      response = Struct.new(:role, :content).new('assistant', 'Hello! How can I help?')

      event = utils_class.response_to_log_event(response, capture_content: true)

      _(event[:event_name]).must_equal 'gen_ai.assistant.message'
      _(event[:body][:role]).must_equal 'assistant'
      _(event[:body][:content]).must_equal 'Hello! How can I help?'
    end

    it 'includes tool calls in response event' do
      response = Struct.new(:role, :content, :tool_calls).new(
        'assistant',
        nil,
        { 'tc_1' => { name: 'get_weather', arguments: '{}' } }
      )

      event = utils_class.response_to_log_event(response, capture_content: true)

      _(event[:body][:tool_calls]).wont_be_nil
      _(event[:body][:tool_calls].first[:name]).must_equal 'get_weather'
    end
  end

  describe '#extract_provider_name' do
    it 'extracts slug from provider' do
      provider = Struct.new(:slug).new('openai')
      _(utils_class.extract_provider_name(provider)).must_equal 'openai'
    end

    it 'extracts name from provider if no slug' do
      provider = Struct.new(:name).new('Anthropic')
      _(utils_class.extract_provider_name(provider)).must_equal 'anthropic'
    end

    it 'returns unknown for nil provider' do
      _(utils_class.extract_provider_name(nil)).must_equal 'unknown'
    end

    it 'uses class name as fallback' do
      # Create a simple class without slug or name methods
      provider = Object.new
      result = utils_class.extract_provider_name(provider)
      _(result).must_equal 'object'
    end
  end

  describe '#log_structured_event' do
    it 'logs event as JSON' do
      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      event = {
        event_name: 'gen_ai.user.message',
        attributes: { 'gen_ai.provider.name' => 'ruby_llm' },
        body: { content: 'Hello' }
      }

      utils_class.log_structured_event(event)

      OpenTelemetry.logger = original_logger

      logged = logger_output.string
      _(logged).must_include 'gen_ai.user.message'
      _(logged).must_include 'ruby_llm'
      _(logged).must_include 'Hello'
    end
  end
end
