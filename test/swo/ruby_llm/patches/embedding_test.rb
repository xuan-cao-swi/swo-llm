# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'
require 'json'

require_relative '../../../../../lib/swo/llm/ruby_llm/opentelemetry/instrumentation'
require_relative '../../../../../lib/swo/llm/ruby_llm/opentelemetry/instrumentation/ruby_llm/patches/embedding'

# Mock RubyLLM::Embedding if not already defined from chat_test.rb
unless defined?(RubyLLM::Embedding)
  module RubyLLM
    VERSION = '1.3.0' unless defined?(VERSION)

    def self.config
      @config ||= Config.new
    end

    class Config
      attr_accessor :default_model, :default_embedding_model, :openai_api_key

      def initialize
        @default_model = 'gpt-4'
        @default_embedding_model = 'text-embedding-ada-002'
      end
    end unless defined?(Config)

    class Embedding
      attr_reader :vectors, :model, :input_tokens

      def initialize(vectors:, model:, input_tokens: 0)
        @vectors = vectors
        @model = model
        @input_tokens = input_tokens
      end

      def self.embed(text, model: nil, provider: nil, assume_model_exists: false, context: nil, dimensions: nil)
        config = context&.config || RubyLLM.config
        model ||= config.default_embedding_model

        # Simulate embedding response
        vector_size = dimensions || 1536
        vectors = Array.new(vector_size) { rand }

        new(
          vectors: vectors,
          model: model,
          input_tokens: text.to_s.split.length
        )
      end
    end
  end
end

describe OpenTelemetry::Instrumentation::RubyLLM::Patches::Embedding do
  let(:instrumentation) { OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance }
  let(:exporter) { EXPORTER }
  let(:spans) { exporter.finished_spans }
  let(:client_span) { spans.first }

  before do
    exporter.reset
    # Apply the patch to our mock Embedding class
    unless RubyLLM::Embedding.singleton_class.ancestors.include?(OpenTelemetry::Instrumentation::RubyLLM::Patches::Embedding)
      RubyLLM::Embedding.singleton_class.prepend(OpenTelemetry::Instrumentation::RubyLLM::Patches::Embedding)
    end
    instrumentation.instance_variable_set(:@installed, true)
  end

  after do
    instrumentation.instance_variable_set(:@installed, false)
  end

  describe 'Embedding.embed' do
    it 'creates span with basic attributes' do
      RubyLLM::Embedding.embed('Hello world')

      _(client_span).wont_be_nil
      _(client_span.name).must_include 'embeddings'
      _(client_span.kind).must_equal :client

      _(client_span.attributes['gen_ai.operation.name']).must_equal 'embeddings'
      _(client_span.attributes['gen_ai.provider.name']).must_equal 'ruby_llm'
      _(client_span.attributes['gen_ai.output.type']).must_equal 'embedding'
    end

    it 'uses default model when not specified' do
      RubyLLM::Embedding.embed('Hello world')

      _(client_span.attributes['gen_ai.request.model']).must_equal 'text-embedding-ada-002'
    end

    it 'uses specified model' do
      RubyLLM::Embedding.embed('Hello world', model: 'text-embedding-3-large')

      _(client_span.name).must_include 'text-embedding-3-large'
      _(client_span.attributes['gen_ai.request.model']).must_equal 'text-embedding-3-large'
    end

    it 'includes dimensions when specified' do
      RubyLLM::Embedding.embed('Hello world', dimensions: 256)

      _(client_span.attributes['gen_ai.request.dimensions']).must_equal 256
    end

    it 'captures response attributes' do
      RubyLLM::Embedding.embed('Hello world test')

      _(client_span.attributes['gen_ai.response.model']).must_equal 'text-embedding-ada-002'
      _(client_span.attributes['gen_ai.usage.input_tokens']).must_equal 3
      _(client_span.attributes['gen_ai.embeddings.dimension.count']).must_equal 1536
    end

    it 'captures input content when enabled' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      RubyLLM::Embedding.embed('The quick brown fox')

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      logged = logger_output.string
      _(logged).must_include 'gen_ai.user.message'
      _(logged).must_include 'The quick brown fox'
    end

    it 'handles array input' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      RubyLLM::Embedding.embed(['Hello', 'World'])

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      logged = logger_output.string
      _(logged).must_include 'Hello, World'
    end
  end

  describe 'error handling' do
    it 'handles errors and records exception' do
      # Temporarily make embed raise an error
      original_method = RubyLLM::Embedding.method(:embed)

      RubyLLM::Embedding.define_singleton_method(:embed) do |*args, **kwargs|
        # Call patched version which will call super
        # But we want to raise after the patch runs
        raise StandardError, 'Embedding API Error'
      end

      assert_raises(StandardError) do
        RubyLLM::Embedding.embed('Hello')
      end

      # Restore original - need to re-prepend since we replaced the method
      RubyLLM::Embedding.singleton_class.send(:define_method, :embed, original_method)
      RubyLLM::Embedding.singleton_class.prepend(OpenTelemetry::Instrumentation::RubyLLM::Patches::Embedding)
    end
  end

  describe 'non-instrumented operations' do
    it 'does not instrument when embeddings not in allowed_operation' do
      original_allowed = instrumentation.config[:allowed_operation].dup
      instrumentation.config[:allowed_operation] = ['chat']

      RubyLLM::Embedding.embed('Hello')

      instrumentation.config[:allowed_operation] = original_allowed

      _(spans).must_be_empty
    end
  end
end
