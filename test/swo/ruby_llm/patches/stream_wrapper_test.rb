# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'

require_relative '../../../../../lib/swo/llm/ruby_llm/opentelemetry/instrumentation'
require_relative '../../../../../lib/swo/llm/ruby_llm/opentelemetry/instrumentation/ruby_llm/patches/stream_wrapper'

describe OpenTelemetry::Instrumentation::RubyLLM::Patches::StreamWrapper do
  let(:wrapper_class) { OpenTelemetry::Instrumentation::RubyLLM::Patches::StreamWrapper }

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
    it 'initializes with span, capture_content, and provider_name' do
      wrapper = wrapper_class.new(mock_span, true, 'openai')

      _(wrapper.span).must_equal mock_span
      _(wrapper.capture_content).must_equal true
      _(wrapper.provider_name).must_equal 'openai'
    end
  end

  describe '#wrap_block' do
    it 'returns a proc that processes chunks' do
      wrapper = wrapper_class.new(mock_span, true, 'openai')
      chunks_received = []

      wrapped = wrapper.wrap_block do |chunk|
        chunks_received << chunk
      end

      _(wrapped).must_be_instance_of Proc

      # Simulate chunks
      wrapped.call(Struct.new(:content).new('Hello'))
      wrapped.call(Struct.new(:content).new(' world'))

      _(chunks_received.length).must_equal 2
    end

    it 'processes chunk and calls user block' do
      wrapper = wrapper_class.new(mock_span, true, 'openai')
      user_received = nil

      wrapped = wrapper.wrap_block do |chunk|
        user_received = chunk
      end

      chunk = Struct.new(:content, :model_id).new('Test', 'gpt-4')
      wrapped.call(chunk)

      _(user_received).must_equal chunk
    end
  end

  describe '#process_chunk' do
    it 'captures model from chunk' do
      wrapper = wrapper_class.new(mock_span, true, 'openai')

      chunk = Struct.new(:model_id, :content).new('gpt-4', 'Hello')
      wrapper.process_chunk(chunk)

      wrapper.finalize
      _(mock_span.attributes['gen_ai.response.model']).must_equal 'gpt-4'
    end

    it 'captures response id from chunk' do
      wrapper = wrapper_class.new(mock_span, true, 'openai')

      chunk = Struct.new(:id, :content).new('resp_123', 'Hello')
      wrapper.process_chunk(chunk)

      wrapper.finalize
      _(mock_span.attributes['gen_ai.response.id']).must_equal 'resp_123'
    end

    it 'captures token usage from chunk' do
      wrapper = wrapper_class.new(mock_span, true, 'openai')

      chunk = Struct.new(:input_tokens, :output_tokens, :content).new(10, 20, 'Hello')
      wrapper.process_chunk(chunk)

      wrapper.finalize
      _(mock_span.attributes['gen_ai.usage.input_tokens']).must_equal 10
      _(mock_span.attributes['gen_ai.usage.output_tokens']).must_equal 20
    end

    it 'accumulates content when capture_content is true' do
      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      wrapper = wrapper_class.new(mock_span, true, 'openai')

      wrapper.process_chunk(Struct.new(:content).new('Hello'))
      wrapper.process_chunk(Struct.new(:content).new(' world'))
      wrapper.finalize

      OpenTelemetry.logger = original_logger

      logged = logger_output.string
      _(logged).must_include 'Hello world'
    end

    it 'processes tool calls from chunk' do
      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      wrapper = wrapper_class.new(mock_span, true, 'openai')

      chunk = Struct.new(:tool_calls, :content).new(
        { 'tc_1' => Struct.new(:name, :arguments).new('search', '{"q":"test"}') },
        nil
      )
      wrapper.process_chunk(chunk)
      wrapper.finalize

      OpenTelemetry.logger = original_logger

      logged = logger_output.string
      _(logged).must_include 'search'
      _(logged).must_include 'tc_1'
    end
  end

  describe '#finalize' do
    it 'extracts data from final response' do
      wrapper = wrapper_class.new(mock_span, false, 'openai')

      response = Struct.new(:model_id, :id, :input_tokens, :output_tokens, :tool_call?).new(
        'gpt-4',
        'resp_456',
        15,
        25,
        false
      )

      wrapper.finalize(response)

      _(mock_span.attributes['gen_ai.response.model']).must_equal 'gpt-4'
      _(mock_span.attributes['gen_ai.response.id']).must_equal 'resp_456'
      _(mock_span.attributes['gen_ai.usage.input_tokens']).must_equal 15
      _(mock_span.attributes['gen_ai.usage.output_tokens']).must_equal 25
      _(mock_span.attributes['gen_ai.response.finish_reasons']).must_equal ['stop']
    end

    it 'sets tool_use finish reason when response has tool calls' do
      wrapper = wrapper_class.new(mock_span, false, 'openai')

      response = Struct.new(:tool_call?).new(true)
      wrapper.finalize(response)

      _(mock_span.attributes['gen_ai.response.finish_reasons']).must_equal ['tool_use']
    end
  end

  describe '#handle_error' do
    it 'sets error attributes on span' do
      wrapper = wrapper_class.new(mock_span, false, 'openai')

      error = StandardError.new('Something went wrong')
      wrapper.handle_error(error)

      _(mock_span.attributes['error.type']).must_equal 'StandardError'
    end
  end

  describe '#finish_span' do
    it 'finishes the span' do
      wrapper = wrapper_class.new(mock_span, false, 'openai')

      _(mock_span.finished).must_equal false
      wrapper.finish_span
      _(mock_span.finished).must_equal true
    end
  end
end
