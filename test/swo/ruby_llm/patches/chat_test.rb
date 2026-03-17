# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'
require 'json'

require_relative '../../../../lib/swo/llm/ruby_llm/opentelemetry/instrumentation/ruby_llm'
require_relative '../../../../lib/swo/llm/ruby_llm/opentelemetry/instrumentation/ruby_llm/patches/chat'

# Mock RubyLLM module and classes for testing
# (ruby_llm gem requires Ruby 3.3+)
unless defined?(RubyLLM::Chat)
  module RubyLLM
    VERSION = '1.3.0' unless defined?(VERSION)

    def self.config
      @config ||= Config.new
    end

    def self.configure
      yield(config)
    end

    class Config
      attr_accessor :default_model, :default_embedding_model, :openai_api_key

      def initialize
        @default_model = 'gpt-4'
        @default_embedding_model = 'text-embedding-ada-002'
      end
    end

    class Content
      attr_reader :text, :attachments

      def initialize(text, attachments = nil)
        @text = text
        @attachments = attachments
      end
    end

    class Message
      attr_reader :role, :content, :tool_calls, :tool_call_id, :id, :model_id, :input_tokens, :output_tokens

      def initialize(attrs = {})
        @role = attrs[:role]
        @content = attrs[:content]
        @tool_calls = attrs[:tool_calls]
        @tool_call_id = attrs[:tool_call_id]
        @id = attrs[:id]
        @model_id = attrs[:model_id]
        @input_tokens = attrs[:input_tokens]
        @output_tokens = attrs[:output_tokens]
      end

      def tool_call?
        @tool_calls && !@tool_calls.empty?
      end
    end

    class Model
      attr_reader :id

      def initialize(id)
        @id = id
      end
    end

    class Provider
      attr_reader :slug

      def initialize(slug)
        @slug = slug
      end

      def complete(_messages, tools:, temperature:, model:, params:, headers:, schema:, thinking:, &block)
        response = Message.new(
          role: :assistant,
          content: 'Hello! How can I help you?',
          id: 'msg_123',
          model_id: model.id,
          input_tokens: 10,
          output_tokens: 15
        )

        if block
          block.call(Message.new(content: 'Hello'))
          block.call(Message.new(content: '! How can I help you?'))
        end

        response
      end
    end

    class Chat
      attr_reader :model, :messages, :tools, :params, :headers, :schema

      def initialize(model: nil, provider: nil, assume_model_exists: false, context: nil)
        @config = RubyLLM.config
        @model = Model.new(model || @config.default_model)
        @provider = Provider.new(provider || 'openai')
        @temperature = nil
        @messages = []
        @tools = {}
        @params = {}
        @headers = {}
        @schema = nil
        @thinking = nil
        @on = {}
      end

      def ask(message = nil, with: nil, &block)
        add_message role: :user, content: message
        complete(&block)
      end

      def with_instructions(instructions, replace: false)
        @messages = @messages.reject { |msg| msg.role == :system } if replace
        add_message role: :system, content: instructions
        self
      end

      def with_temperature(temperature)
        @temperature = temperature
        self
      end

      def complete(&block)
        response = @provider.complete(
          messages,
          tools: @tools,
          temperature: @temperature,
          model: @model,
          params: @params,
          headers: @headers,
          schema: @schema,
          thinking: @thinking,
          &block
        )

        add_message response
        response
      end

      def add_message(message_or_attributes)
        message = message_or_attributes.is_a?(Message) ? message_or_attributes : Message.new(message_or_attributes)
        messages << message
        message
      end
    end
  end
end

describe OpenTelemetry::Instrumentation::RubyLLM::Patches::Chat do
  let(:instrumentation) { OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance }
  let(:exporter) { EXPORTER }
  let(:spans) { exporter.finished_spans }
  let(:client_span) { spans.first }

  before do
    exporter.reset
    # Apply the patch to our mock Chat class
    unless RubyLLM::Chat.ancestors.include?(OpenTelemetry::Instrumentation::RubyLLM::Patches::Chat)
      RubyLLM::Chat.prepend(OpenTelemetry::Instrumentation::RubyLLM::Patches::Chat)
    end
    # Install instrumentation to populate config with defaults
    instrumentation.instance_variable_set(:@config, nil)
    instrumentation.instance_variable_set(:@installed, false)
    instrumentation.install({})
  end

  after do
    instrumentation.instance_variable_set(:@config, nil)
    instrumentation.instance_variable_set(:@installed, false)
  end

  describe 'chat.ask (non-streaming)' do
    it 'creates span with basic attributes' do
      chat = RubyLLM::Chat.new(model: 'gpt-4', provider: 'openai')
      chat.ask('Hello!')

      _(client_span).wont_be_nil
      _(client_span.name).must_include 'chat'
      _(client_span.name).must_include 'gpt-4'
      _(client_span.kind).must_equal :client

      _(client_span.attributes['gen_ai.operation.name']).must_equal 'chat'
      _(client_span.attributes['gen_ai.provider.name']).must_equal 'openai'
      _(client_span.attributes['gen_ai.request.model']).must_equal 'gpt-4'
      _(client_span.attributes['gen_ai.output.type']).must_equal 'text'
    end

    it 'captures response attributes' do
      chat = RubyLLM::Chat.new(model: 'gpt-4', provider: 'openai')
      chat.ask('Hello!')

      _(client_span.attributes['gen_ai.response.model']).must_equal 'gpt-4'
      _(client_span.attributes['gen_ai.response.id']).must_equal 'msg_123'
      _(client_span.attributes['gen_ai.usage.input_tokens']).must_equal 10
      _(client_span.attributes['gen_ai.usage.output_tokens']).must_equal 15
      _(client_span.attributes['gen_ai.response.finish_reasons']).must_equal ['stop']
    end

    it 'captures message content when enabled' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      chat = RubyLLM::Chat.new(model: 'gpt-4', provider: 'openai')
      chat.ask('What is Ruby?')

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      logged = logger_output.string
      _(logged).must_include 'gen_ai.user.message'
      _(logged).must_include 'What is Ruby?'
      _(logged).must_include 'gen_ai.assistant.message'
    end

    it 'captures system instructions when present' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      chat = RubyLLM::Chat.new(model: 'gpt-4', provider: 'openai')
      chat.with_instructions('You are a helpful assistant.')
      chat.ask('Hello!')

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      logged = logger_output.string
      _(logged).must_include 'gen_ai.system.message'
      _(logged).must_include 'You are a helpful assistant.'
    end

    it 'includes temperature when set' do
      chat = RubyLLM::Chat.new(model: 'gpt-4', provider: 'openai')
      chat.with_temperature(0.7)
      chat.ask('Hello!')

      _(client_span.attributes['gen_ai.request.temperature']).must_equal 0.7
    end
  end

  describe 'chat.ask (streaming)' do
    it 'creates span for streaming requests' do
      chat = RubyLLM::Chat.new(model: 'gpt-4', provider: 'openai')
      chunks = []

      chat.ask('Tell me a story') do |chunk|
        chunks << chunk
      end

      _(client_span).wont_be_nil
      _(client_span.name).must_include 'chat'
      _(client_span.attributes['gen_ai.operation.name']).must_equal 'chat'
    end

    it 'captures streaming chunks' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      chat = RubyLLM::Chat.new(model: 'gpt-4', provider: 'openai')
      chat.ask('Hello!') do |_chunk|
        # Consume chunks
      end

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      _(client_span).wont_be_nil
      _(client_span.attributes['gen_ai.response.finish_reasons']).must_equal ['stop']
    end

    it 'yields chunks to user block' do
      chat = RubyLLM::Chat.new(model: 'gpt-4', provider: 'openai')
      received_chunks = []

      chat.ask('Hello!') do |chunk|
        received_chunks << chunk
      end

      _(received_chunks.length).must_equal 2
    end
  end

  describe 'error handling' do
    it 'handles errors and records exception' do
      # Create a provider that raises an error
      error_provider = Class.new(RubyLLM::Provider) do
        def complete(*)
          raise StandardError, 'API Error'
        end
      end

      chat = RubyLLM::Chat.new(model: 'gpt-4')
      chat.instance_variable_set(:@provider, error_provider.new('error_provider'))

      assert_raises(StandardError) do
        chat.ask('Hello!')
      end

      _(client_span).wont_be_nil
      _(client_span.attributes['error.type']).must_equal 'StandardError'
    end
  end

  describe 'non-instrumented operations' do
    it 'does not instrument when chat not in allowed_operation' do
      original_allowed = instrumentation.config[:allowed_operation].dup
      instrumentation.config[:allowed_operation] = ['embeddings']

      chat = RubyLLM::Chat.new(model: 'gpt-4', provider: 'openai')
      chat.ask('Hello!')

      instrumentation.config[:allowed_operation] = original_allowed

      _(spans).must_be_empty
    end
  end
end
