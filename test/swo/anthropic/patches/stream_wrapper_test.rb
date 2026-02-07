# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'

require_relative '../../../../../lib/swo/llm/anthropic/opentelemetry/instrumentation'
require_relative '../../../../../lib/swo/llm/anthropic/opentelemetry/instrumentation/anthropic/patches/stream_wrapper'

describe OpenTelemetry::Instrumentation::Anthropic::Patches::StreamWrapper do
  let(:instrumentation) { OpenTelemetry::Instrumentation::Anthropic::Instrumentation.instance }

  describe 'ContentBlockBuffer' do
    let(:buffer_class) { OpenTelemetry::Instrumentation::Anthropic::Patches::StreamWrapper::ContentBlockBuffer }

    describe '#initialize' do
      it 'initializes with index' do
        buffer = buffer_class.new(0)
        _(buffer.index).must_equal 0
        _(buffer.type).must_be_nil
        _(buffer.text_content).must_be_empty
        _(buffer.input_content).must_be_empty
      end
    end

    describe '#append_text' do
      it 'appends text content' do
        buffer = buffer_class.new(0)
        buffer.append_text('Hello')
        buffer.append_text(' world')

        _(buffer.text_content).must_equal ['Hello', ' world']
      end

      it 'ignores nil text' do
        buffer = buffer_class.new(0)
        buffer.append_text(nil)

        _(buffer.text_content).must_be_empty
      end
    end

    describe '#append_input' do
      it 'appends input content for tool_use' do
        buffer = buffer_class.new(0)
        buffer.append_input('{"loc')
        buffer.append_input('ation":"NYC"}')

        _(buffer.input_content).must_equal ['{"loc', 'ation":"NYC"}']
      end
    end

    describe '#to_log_event' do
      it 'creates log event for text block' do
        buffer = buffer_class.new(0)
        buffer.type = 'text'
        buffer.append_text('Hello ')
        buffer.append_text('world')

        event = buffer.to_log_event

        _(event[:event_name]).must_equal 'gen_ai.content_block'
        _(event[:attributes]['gen_ai.provider.name']).must_equal 'anthropic'
        _(event[:body][:index]).must_equal 0
        _(event[:body][:type]).must_equal 'text'
        _(event[:body][:text]).must_equal 'Hello world'
      end

      it 'creates log event for tool_use block' do
        buffer = buffer_class.new(1)
        buffer.type = 'tool_use'
        buffer.id = 'toolu_123'
        buffer.name = 'get_weather'
        buffer.append_input('{"location":"NYC"}')

        event = buffer.to_log_event

        _(event[:body][:type]).must_equal 'tool_use'
        _(event[:body][:id]).must_equal 'toolu_123'
        _(event[:body][:name]).must_equal 'get_weather'
        _(event[:body][:input]).must_equal '{"location":"NYC"}'
      end

      it 'defaults type to text when nil' do
        buffer = buffer_class.new(0)
        event = buffer.to_log_event

        _(event[:body][:type]).must_equal 'text'
      end
    end
  end

  describe 'StreamWrapper' do
    let(:wrapper_class) { OpenTelemetry::Instrumentation::Anthropic::Patches::StreamWrapper }

    # Mock span for testing
    let(:mock_span) do
      Struct.new(:attributes, :recording, :finished, :status) do
        def initialize
          super({}, true, false, nil)
        end

        def recording?
          recording
        end

        def add_attributes(attrs)
          attributes.merge!(attrs)
        end

        def set_attribute(key, value)
          attributes[key] = value
        end

        def record_exception(_error); end

        def finish
          self.finished = true
        end
      end.new
    end

    describe '#initialize' do
      it 'initializes with stream, span and capture_content flag' do
        stream = []
        wrapper = wrapper_class.new(stream, mock_span, true)

        _(wrapper.stream).must_equal stream
        _(wrapper.span).must_equal mock_span
        _(wrapper.capture_content).must_equal true
      end
    end

    describe 'event processing' do
      it 'processes message_start event' do
        message_start_event = Struct.new(:type, :message).new(
          'message_start',
          Struct.new(:id, :model, :usage).new(
            'msg_123',
            'claude-3-opus-20240229',
            Struct.new(:input_tokens).new(10)
          )
        )

        stream = [message_start_event]
        wrapper = wrapper_class.new(stream, mock_span, false)

        # Consume the stream
        wrapper.each { |_e| }

        _(mock_span.attributes['gen_ai.response.id']).must_equal 'msg_123'
        _(mock_span.attributes['gen_ai.response.model']).must_equal 'claude-3-opus-20240229'
        _(mock_span.attributes['gen_ai.usage.input_tokens']).must_equal 10
      end

      it 'processes content_block_start and content_block_delta events' do
        events = [
          Struct.new(:type, :index, :content_block).new(
            'content_block_start',
            0,
            Struct.new(:type).new('text')
          ),
          Struct.new(:type, :index, :delta).new(
            'content_block_delta',
            0,
            Struct.new(:type, :text).new('text_delta', 'Hello')
          ),
          Struct.new(:type, :index, :delta).new(
            'content_block_delta',
            0,
            Struct.new(:type, :text).new('text_delta', ' world')
          ),
          Struct.new(:type).new('content_block_stop')
        ]

        logger_output = StringIO.new
        original_logger = OpenTelemetry.logger
        OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

        stream = events
        wrapper = wrapper_class.new(stream, mock_span, true)
        wrapper.each { |_e| }

        OpenTelemetry.logger = original_logger

        logged = logger_output.string
        _(logged).must_include 'gen_ai.content_block'
        _(logged).must_include 'Hello world'
      end

      it 'processes message_delta event for stop_reason and output_tokens' do
        events = [
          Struct.new(:type, :delta, :usage).new(
            'message_delta',
            Struct.new(:stop_reason).new('end_turn'),
            Struct.new(:output_tokens).new(25)
          ),
          Struct.new(:type).new('message_stop')
        ]

        stream = events
        wrapper = wrapper_class.new(stream, mock_span, false)
        wrapper.each { |_e| }

        _(mock_span.attributes['gen_ai.usage.output_tokens']).must_equal 25
        _(mock_span.attributes['gen_ai.response.finish_reasons']).must_equal ['end_turn']
      end

      it 'processes tool_use streaming events' do
        events = [
          Struct.new(:type, :index, :content_block).new(
            'content_block_start',
            0,
            Struct.new(:type, :id, :name).new('tool_use', 'toolu_123', 'get_weather')
          ),
          Struct.new(:type, :index, :delta).new(
            'content_block_delta',
            0,
            Struct.new(:type, :partial_json).new('input_json_delta', '{"loc')
          ),
          Struct.new(:type, :index, :delta).new(
            'content_block_delta',
            0,
            Struct.new(:type, :partial_json).new('input_json_delta', 'ation":"NYC"}')
          ),
          Struct.new(:type).new('content_block_stop')
        ]

        logger_output = StringIO.new
        original_logger = OpenTelemetry.logger
        OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

        stream = events
        wrapper = wrapper_class.new(stream, mock_span, true)
        wrapper.each { |_e| }

        OpenTelemetry.logger = original_logger

        logged = logger_output.string
        _(logged).must_include 'tool_use'
        _(logged).must_include 'toolu_123'
        _(logged).must_include 'get_weather'
        _(logged).must_include '{"location":"NYC"}'
      end
    end

    describe 'error handling' do
      it 'handles errors during streaming' do
        error_stream = Enumerator.new do |yielder|
          yielder << Struct.new(:type).new('message_start')
          raise StandardError, 'Stream error'
        end

        wrapper = wrapper_class.new(error_stream, mock_span, false)

        assert_raises(StandardError) do
          wrapper.each { |_e| }
        end

        _(mock_span.attributes['error.type']).must_equal 'StandardError'
        _(mock_span.finished).must_equal true
      end
    end

    describe 'cleanup' do
      it 'finishes span after stream completion' do
        stream = []
        wrapper = wrapper_class.new(stream, mock_span, false)
        wrapper.each { |_e| }

        _(mock_span.finished).must_equal true
      end
    end
  end
end
