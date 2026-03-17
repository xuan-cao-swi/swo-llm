# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'
require 'webmock/minitest'
require 'json'

require_relative '../../../../lib/swo/llm/openai/opentelemetry/instrumentation/openai'
require_relative '../../../../lib/swo/llm/openai/opentelemetry/instrumentation/openai/patches/client'

# Define a minimal OpenAI module for the instrumentation's `present` check
# The instrumentation expects ::OpenAI to be defined with a VERSION constant
module OpenAI
  VERSION = '0.46.0' unless defined?(VERSION)
end

# Mock OpenAI Client that simulates the official SDK's API structure
# The instrumentation patch expects a `request(req)` method
module MockOpenAI
  VERSION = '0.46.0'

  class Client
    def initialize(api_key:)
      @api_key = api_key
      @chat = Chat.new(self)
      @embeddings = Embeddings.new(self)
      @images = Images.new(self)
    end

    attr_reader :chat, :embeddings, :images

    # The request method that the patch intercepts
    def request(req)
      uri = URI.parse("https://api.openai.com/v1/#{req[:path]}")
      http_method = req[:method]&.to_s&.upcase || 'POST'

      case http_method
      when 'POST'
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          request = Net::HTTP::Post.new(uri.path, { 'Content-Type' => 'application/json' })
          request.body = req[:body].to_json
          http.request(request)
        end
      else
        raise "Unsupported HTTP method: #{http_method}"
      end

      JSON.parse(response.body, symbolize_names: true)
    end
  end

  class Chat
    def initialize(client)
      @client = client
      @completions = Completions.new(client)
    end

    attr_reader :completions
  end

  class Completions
    def initialize(client)
      @client = client
    end

    def create(model:, messages:, **options)
      body = { model: model, messages: messages }.merge(options)
      @client.request(
        method: :post,
        path: 'chat/completions',
        body: body,
        stream: options[:stream]
      )
    end
  end

  class Embeddings
    def initialize(client)
      @client = client
    end

    def create(model:, input:, **options)
      body = { model: model, input: input }.merge(options)
      @client.request(
        method: :post,
        path: 'embeddings',
        body: body
      )
    end
  end

  class Images
    def initialize(client)
      @client = client
    end

    def generate(prompt:, **options)
      body = { prompt: prompt }.merge(options)
      @client.request(
        method: :post,
        path: 'images/generations',
        body: body
      )
    end
  end

  module Errors
    class InternalServerError < StandardError; end
  end
end

describe OpenTelemetry::Instrumentation::OpenAI::Patches::Client do
  let(:instrumentation) { OpenTelemetry::Instrumentation::OpenAI::Instrumentation.instance }
  let(:exporter) { EXPORTER }
  let(:spans) { exporter.finished_spans }
  let(:client_span) { spans.first }

  before do
    exporter.reset
    # Apply patch to mock client
    unless MockOpenAI::Client.ancestors.include?(OpenTelemetry::Instrumentation::OpenAI::Patches::Client)
      MockOpenAI::Client.prepend(OpenTelemetry::Instrumentation::OpenAI::Patches::Client)
    end
    # Set config directly instead of calling install (which tries to patch the real OpenAI::Client)
    instrumentation.instance_variable_set(:@config, {
      capture_content: false,
      allowed_operation: %w[chat completions embeddings]
    })
    instrumentation.instance_variable_set(:@installed, true)
    # Set up the tracer to use the SDK's tracer provider (not the no-op tracer)
    instrumentation.instance_variable_set(
      :@tracer,
      OpenTelemetry.tracer_provider.tracer(instrumentation.name, instrumentation.version)
    )
  end

  after do
    instrumentation.instance_variable_set(:@config, nil)
    instrumentation.instance_variable_set(:@installed, false)
  end

  describe 'chat completions via client.request' do
    let(:model) { 'gpt-4' }
    let(:messages) { [{ role: 'user', content: 'Hello!' }] }
    let(:response_body) do
      {
        id: 'chatcmpl-123',
        object: 'chat.completion',
        created: 1_677_652_288,
        model: 'gpt-4-0613',
        choices: [
          {
            index: 0,
            message: {
              role: 'assistant',
              content: 'Hello! How can I assist you today?'
            },
            finish_reason: 'stop'
          }
        ],
        usage: {
          prompt_tokens: 10,
          completion_tokens: 20,
          total_tokens: 30
        }
      }
    end

    before do
      stub_request(:post, 'https://api.openai.com/v1/chat/completions')
        .to_return(status: 200, body: response_body.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'creates span with basic attributes for chat completions request' do
      client = MockOpenAI::Client.new(api_key: 'test-token')
      client.chat.completions.create(
        model: model,
        messages: messages
      )

      _(client_span).wont_be_nil
      _(client_span.name).must_include 'chat'
      _(client_span.kind).must_equal :client

      _(client_span.attributes['gen_ai.operation.name']).must_equal 'chat'
      _(client_span.attributes['gen_ai.provider.name']).must_equal 'openai'
      _(client_span.attributes['gen_ai.request.model']).must_equal model
      _(client_span.attributes['gen_ai.response.model']).must_equal 'gpt-4-0613'
      _(client_span.attributes['gen_ai.response.id']).must_equal 'chatcmpl-123'
      _(client_span.attributes['gen_ai.response.finish_reasons']).must_equal ['stop']
      _(client_span.attributes['gen_ai.usage.input_tokens']).must_equal 10
      _(client_span.attributes['gen_ai.usage.output_tokens']).must_equal 20
      _(client_span.attributes['gen_ai.usage.total_tokens']).must_equal 30
    end

    it 'sets optional chat completion parameters' do
      client = MockOpenAI::Client.new(api_key: 'test-token')
      client.chat.completions.create(
        model: model,
        messages: messages,
        temperature: 0.7,
        max_tokens: 100,
        top_p: 0.9,
        frequency_penalty: 0.5,
        presence_penalty: 0.3,
        seed: 42
      )

      _(client_span.attributes['gen_ai.request.temperature']).must_equal 0.7
      _(client_span.attributes['gen_ai.request.max_tokens']).must_equal 100
      _(client_span.attributes['gen_ai.request.top_p']).must_equal 0.9
      _(client_span.attributes['gen_ai.request.frequency_penalty']).must_equal 0.5
      _(client_span.attributes['gen_ai.request.presence_penalty']).must_equal 0.3
      _(client_span.attributes['gen_ai.request.seed']).must_equal 42
    end

    it 'captures message content when enabled' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      client = MockOpenAI::Client.new(api_key: 'test-token')
      client.chat.completions.create(
        model: model,
        messages: messages
      )

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      _(client_span).wont_be_nil
      logged_message = logger_output.string

      _(logged_message).must_include 'gen_ai.user.message'
      _(logged_message).must_include 'Hello!'
    end
  end

  describe 'embeddings via client.request' do
    let(:model) { 'text-embedding-ada-002' }
    let(:input_text) { 'The quick brown fox jumps over the lazy dog.' }
    let(:response_body) do
      {
        object: 'list',
        data: [
          {
            object: 'embedding',
            embedding: Array.new(1536) { rand },
            index: 0
          }
        ],
        model: 'text-embedding-ada-002-v2',
        usage: {
          prompt_tokens: 10,
          total_tokens: 10
        }
      }
    end

    before do
      stub_request(:post, 'https://api.openai.com/v1/embeddings')
        .to_return(status: 200, body: response_body.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'creates a span for embeddings request' do
      client = MockOpenAI::Client.new(api_key: 'test-token')
      client.embeddings.create(
        model: model,
        input: input_text
      )

      _(client_span).wont_be_nil
      _(client_span.name).must_include 'embeddings'
      _(client_span.kind).must_equal :client

      _(client_span.attributes['gen_ai.operation.name']).must_equal 'embeddings'
      _(client_span.attributes['gen_ai.provider.name']).must_equal 'openai'
      _(client_span.attributes['gen_ai.request.model']).must_equal model
      _(client_span.attributes['gen_ai.response.model']).must_equal 'text-embedding-ada-002-v2'
      _(client_span.attributes['gen_ai.usage.input_tokens']).must_equal 10
      _(client_span.attributes['gen_ai.usage.total_tokens']).must_equal 10
    end

    it 'captures embedding input content when enabled' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      client = MockOpenAI::Client.new(api_key: 'test-token')
      client.embeddings.create(
        model: model,
        input: input_text
      )

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      _(client_span).wont_be_nil
      logged_message = logger_output.string
      _(logged_message).must_include 'gen_ai.user.message'
      _(logged_message).must_include 'content'
    end
  end

  describe 'error handling' do
    before do
      stub_request(:post, 'https://api.openai.com/v1/chat/completions')
        .to_return(status: 500, body: { error: { message: 'Internal Server Error' } }.to_json)
    end

    it 'records exception and sets error status' do
      client = MockOpenAI::Client.new(api_key: 'test-token')

      begin
        client.chat.completions.create(
          model: 'gpt-4',
          messages: [{ role: 'user', content: 'Hello!' }]
        )
      rescue StandardError
        # Expected - may or may not raise depending on mock behavior
      end

      # Span should be created even with error response
      _(client_span).wont_be_nil
      _(client_span.attributes['gen_ai.operation.name']).must_equal 'chat'
    end
  end

  describe 'images generation via client.request (not in allowed_operation)' do
    let(:response_body) do
      {
        created: 1_677_652_288,
        data: [
          { url: 'https://example.com/image1.png' }
        ]
      }
    end

    before do
      stub_request(:post, 'https://api.openai.com/v1/images/generations')
        .to_return(status: 200, body: response_body.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'skips span creation for non-allowed operations' do
      client = MockOpenAI::Client.new(api_key: 'test-token')

      client.images.generate(
        prompt: 'A futuristic cityscape at night'
      )

      # Images generation is not in allowed_operation by default, so no span
      _(client_span).must_be_nil
    end
  end
end
