# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'
require 'json'

require_relative '../../../../lib/swo/llm/claude/opentelemetry/instrumentation/claude/patches/utils'

describe OpenTelemetry::Instrumentation::Claude::Patches::Utils do
  let(:utils_class) do
    Class.new do
      include OpenTelemetry::Instrumentation::Claude::Patches::Utils
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

  describe '#extract_tool_use' do
    it 'returns nil when content is not present' do
      item = { role: 'assistant' }
      _(utils_class.extract_tool_use(item, true)).must_be_nil
    end

    it 'returns nil when content has no tool_use blocks' do
      item = {
        role: 'assistant',
        content: [
          { type: 'text', text: 'Hello' }
        ]
      }
      _(utils_class.extract_tool_use(item, true)).must_be_nil
    end

    it 'extracts tool_use with id and name' do
      item = {
        content: [
          {
            type: 'tool_use',
            id: 'toolu_123',
            name: 'get_weather',
            input: { location: 'NYC' }
          }
        ]
      }

      result = utils_class.extract_tool_use(item, true)
      _(result).wont_be_nil
      _(result.length).must_equal 1
      _(result[0][:id]).must_equal 'toolu_123'
      _(result[0][:type]).must_equal 'tool_use'
      _(result[0][:name]).must_equal 'get_weather'
      _(result[0][:input]).must_include 'location'
    end

    it 'omits input when capture_content is false' do
      item = {
        content: [
          {
            type: 'tool_use',
            id: 'toolu_123',
            name: 'get_weather',
            input: { location: 'NYC' }
          }
        ]
      }

      result = utils_class.extract_tool_use(item, false)
      _(result[0][:input]).must_be_nil
    end

    it 'extracts multiple tool_use blocks' do
      item = {
        content: [
          { type: 'text', text: 'Let me help you with that.' },
          {
            type: 'tool_use',
            id: 'toolu_1',
            name: 'get_weather',
            input: { location: 'NYC' }
          },
          {
            type: 'tool_use',
            id: 'toolu_2',
            name: 'get_time',
            input: { timezone: 'EST' }
          }
        ]
      }

      result = utils_class.extract_tool_use(item, true)
      _(result.length).must_equal 2
      _(result[0][:name]).must_equal 'get_weather'
      _(result[1][:name]).must_equal 'get_time'
    end
  end

  describe '#message_to_log_event' do
    it 'creates event for user message with string content' do
      message = { role: 'user', content: 'Hello Claude!' }

      event = utils_class.message_to_log_event(message, capture_content: true)

      _(event[:event_name]).must_equal 'gen_ai.user.message'
      _(event[:attributes]['gen_ai.provider.name']).must_equal 'anthropic'
      _(event[:body][:content]).must_equal 'Hello Claude!'
    end

    it 'creates event for user message with array content' do
      message = {
        role: 'user',
        content: [
          { type: 'text', text: 'What is this?' },
          { type: 'image', source: { type: 'base64', data: 'abc123' } }
        ]
      }

      event = utils_class.message_to_log_event(message, capture_content: true)

      _(event[:event_name]).must_equal 'gen_ai.user.message'
      _(event[:body][:content]).must_equal 'What is this?'
    end

    it 'creates event for assistant message with tool_use' do
      message = {
        role: 'assistant',
        content: [
          { type: 'text', text: 'Let me check the weather.' },
          {
            type: 'tool_use',
            id: 'toolu_123',
            name: 'get_weather',
            input: { location: 'NYC' }
          }
        ]
      }

      event = utils_class.message_to_log_event(message, capture_content: true)

      _(event[:event_name]).must_equal 'gen_ai.assistant.message'
      _(event[:body][:content]).must_equal 'Let me check the weather.'
      _(event[:body][:tool_use]).wont_be_nil
      _(event[:body][:tool_use][0][:name]).must_equal 'get_weather'
    end

    it 'handles tool_result in user message' do
      message = {
        role: 'user',
        content: [
          {
            type: 'tool_result',
            tool_use_id: 'toolu_123',
            content: 'The weather is sunny.'
          }
        ]
      }

      event = utils_class.message_to_log_event(message, capture_content: true)

      _(event[:event_name]).must_equal 'gen_ai.user.message'
      _(event[:body][:tool_use_id]).must_equal 'toolu_123'
    end

    it 'omits content when capture_content is false' do
      message = { role: 'user', content: 'Secret message' }

      event = utils_class.message_to_log_event(message, capture_content: false)

      # Body is nil or doesn't contain content when capture_content is false
      body = event[:body]
      _(body.nil? || body[:content].nil?).must_equal true
    end
  end

  describe '#content_block_to_log_event' do
    it 'creates event for text content block' do
      block = { type: 'text', text: 'Hello world' }

      event = utils_class.content_block_to_log_event(block, 0, capture_content: true)

      _(event[:event_name]).must_equal 'gen_ai.content_block'
      _(event[:attributes]['gen_ai.provider.name']).must_equal 'anthropic'
      _(event[:body][:index]).must_equal 0
      _(event[:body][:type]).must_equal 'text'
      _(event[:body][:text]).must_equal 'Hello world'
    end

    it 'creates event for tool_use content block' do
      block = {
        type: 'tool_use',
        id: 'toolu_123',
        name: 'get_weather',
        input: { location: 'NYC' }
      }

      event = utils_class.content_block_to_log_event(block, 1, capture_content: true)

      _(event[:body][:type]).must_equal 'tool_use'
      _(event[:body][:id]).must_equal 'toolu_123'
      _(event[:body][:name]).must_equal 'get_weather'
      _(event[:body][:input]).must_include 'location'
    end
  end

  describe '#response_to_log_event' do
    it 'creates event from response with text content' do
      response = Struct.new(:stop_reason, :content).new(
        'end_turn',
        [{ type: 'text', text: 'Hello! How can I help?' }]
      )

      event = utils_class.response_to_log_event(response, capture_content: true)

      _(event[:event_name]).must_equal 'gen_ai.assistant.message'
      _(event[:body][:stop_reason]).must_equal 'end_turn'
      _(event[:body][:role]).must_equal 'assistant'
      _(event[:body][:content]).must_equal 'Hello! How can I help?'
    end

    it 'creates event from response with tool_use content' do
      response = Struct.new(:stop_reason, :content).new(
        'tool_use',
        [
          { type: 'text', text: 'Let me check.' },
          { type: 'tool_use', id: 'toolu_123', name: 'search', input: { q: 'test' } }
        ]
      )

      event = utils_class.response_to_log_event(response, capture_content: true)

      _(event[:body][:stop_reason]).must_equal 'tool_use'
      _(event[:body][:content]).must_equal 'Let me check.'
      _(event[:body][:tool_use]).wont_be_nil
      _(event[:body][:tool_use][0][:name]).must_equal 'search'
    end

    it 'sets stop_reason to error when nil' do
      response = Struct.new(:stop_reason, :content).new(nil, [])

      event = utils_class.response_to_log_event(response, capture_content: true)

      _(event[:body][:stop_reason]).must_equal 'error'
    end
  end

  describe '#log_structured_event' do
    it 'logs event as JSON' do
      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      event = {
        event_name: 'gen_ai.user.message',
        attributes: { 'gen_ai.provider.name' => 'anthropic' },
        body: { content: 'Hello' }
      }

      utils_class.log_structured_event(event)

      OpenTelemetry.logger = original_logger

      logged = logger_output.string
      _(logged).must_include 'gen_ai.user.message'
      _(logged).must_include 'anthropic'
      _(logged).must_include 'Hello'
    end
  end
end
