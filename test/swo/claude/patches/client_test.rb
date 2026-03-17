# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'
require 'webmock/minitest'
require 'json'

require_relative '../../../../lib/swo/llm/claude/opentelemetry/instrumentation'
require_relative '../../../../lib/swo/llm/claude/opentelemetry/instrumentation/claude/patches/client'

# Define a minimal Anthropic module for the instrumentation's `present` check
# The instrumentation expects ::Anthropic to be defined with a VERSION constant
module Anthropic
  VERSION = '1.0.0' unless defined?(VERSION)
end

# Mock Anthropic Client that simulates the official SDK's API structure
# The instrumentation patch expects a `request(req)` method
# The instrumentation patches (in patches/client.rb) are designed to
# intercept a low-level request(req) method that takes a hash with keys like:
# But the real gems don't expose this method in their public API.
module MockAnthropic
  VERSION = '1.0.0'

  class Client
    def initialize(api_key:)
      @api_key = api_key
      @messages = Messages.new(self)
    end

    attr_reader :messages

    # The request method that the patch intercepts
    # In the real SDK, req[:path] is "v1/messages" and base_url handles the rest
    def request(req)
      uri = URI.parse("https://api.anthropic.com/#{req[:path]}")
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

  class Messages
    def initialize(client)
      @client = client
    end

    def create(model:, max_tokens:, messages:, **options)
      body = { model: model, max_tokens: max_tokens, messages: messages }.merge(options)
      @client.request(
        method: :post,
        path: 'v1/messages',
        body: body,
        stream: options[:stream]
      )
    end
  end

  module Errors
    class APIError < StandardError; end
  end
end

describe OpenTelemetry::Instrumentation::Claude::Patches::Client do
  let(:instrumentation) { OpenTelemetry::Instrumentation::Claude::Instrumentation.instance }
  let(:exporter) { EXPORTER }
  let(:spans) { exporter.finished_spans }
  let(:client_span) { spans.first }

  before do
    exporter.reset
    # Apply the patch to mock client
    unless MockAnthropic::Client.ancestors.include?(OpenTelemetry::Instrumentation::Claude::Patches::Client)
      MockAnthropic::Client.prepend(OpenTelemetry::Instrumentation::Claude::Patches::Client)
    end
    # Set config directly instead of calling install (which tries to patch the real Anthropic::Client)
    instrumentation.instance_variable_set(:@config, {
      capture_content: false,
      allowed_operation: %w[messages completions]
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

  describe 'messages.create' do
    let(:model) { 'claude-3-opus-20240229' }
    let(:messages) { [{ role: 'user', content: 'Hello, Claude!' }] }
    let(:response_body) do
      {
        id: 'msg_123abc',
        type: 'message',
        role: 'assistant',
        content: [
          {
            type: 'text',
            text: 'Hello! How can I assist you today?'
          }
        ],
        model: 'claude-3-opus-20240229',
        stop_reason: 'end_turn',
        usage: {
          input_tokens: 12,
          output_tokens: 15
        }
      }
    end

    before do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return(status: 200, body: response_body.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'creates span with basic attributes for messages request' do
      client = MockAnthropic::Client.new(api_key: 'test-token')
      client.messages.create(
        model: model,
        max_tokens: 1024,
        messages: messages
      )

      _(client_span).wont_be_nil
      _(client_span.name).must_include 'messages'
      _(client_span.name).must_include model
      _(client_span.kind).must_equal :client

      _(client_span.attributes['gen_ai.operation.name']).must_equal 'messages'
      _(client_span.attributes['gen_ai.provider.name']).must_equal 'anthropic'
      _(client_span.attributes['gen_ai.request.model']).must_equal model
      _(client_span.attributes['gen_ai.response.model']).must_equal 'claude-3-opus-20240229'
      _(client_span.attributes['gen_ai.response.id']).must_equal 'msg_123abc'
      _(client_span.attributes['gen_ai.response.finish_reasons']).must_equal ['end_turn']
      _(client_span.attributes['gen_ai.usage.input_tokens']).must_equal 12
      _(client_span.attributes['gen_ai.usage.output_tokens']).must_equal 15
    end

    it 'sets optional parameters as attributes' do
      client = MockAnthropic::Client.new(api_key: 'test-token')
      client.messages.create(
        model: model,
        max_tokens: 2048,
        messages: messages,
        temperature: 0.7,
        top_p: 0.9,
        top_k: 40,
        stop_sequences: ['END', 'STOP']
      )

      _(client_span.attributes['gen_ai.request.max_tokens']).must_equal 2048
      _(client_span.attributes['gen_ai.request.temperature']).must_equal 0.7
      _(client_span.attributes['gen_ai.request.top_p']).must_equal 0.9
      _(client_span.attributes['gen_ai.request.top_k']).must_equal 40
      _(client_span.attributes['gen_ai.request.stop_sequences']).must_equal ['END', 'STOP']
    end

    it 'captures message content when enabled' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      client = MockAnthropic::Client.new(api_key: 'test-token')
      client.messages.create(
        model: model,
        max_tokens: 1024,
        messages: messages
      )

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      _(client_span).wont_be_nil
      logged_message = logger_output.string
      _(logged_message).must_include 'gen_ai.user.message'
      _(logged_message).must_include 'Hello, Claude!'
    end

    it 'captures system message when present' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      client = MockAnthropic::Client.new(api_key: 'test-token')
      client.messages.create(
        model: model,
        max_tokens: 1024,
        messages: messages,
        system: 'You are a helpful assistant.'
      )

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      _(client_span).wont_be_nil
      logged_message = logger_output.string
      _(logged_message).must_include 'gen_ai.system.message'
      _(logged_message).must_include 'You are a helpful assistant.'
    end
  end

  describe 'tool use response' do
    let(:model) { 'claude-3-opus-20240229' }
    let(:messages) { [{ role: 'user', content: 'What is the weather in NYC?' }] }
    let(:response_body) do
      {
        id: 'msg_tool123',
        type: 'message',
        role: 'assistant',
        content: [
          {
            type: 'tool_use',
            id: 'toolu_01XYZ',
            name: 'get_weather',
            input: { location: 'NYC' }
          }
        ],
        model: 'claude-3-opus-20240229',
        stop_reason: 'tool_use',
        usage: {
          input_tokens: 20,
          output_tokens: 25
        }
      }
    end

    before do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return(status: 200, body: response_body.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'captures tool_use in response' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      client = MockAnthropic::Client.new(api_key: 'test-token')
      client.messages.create(
        model: model,
        max_tokens: 1024,
        messages: messages
      )

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      _(client_span).wont_be_nil
      _(client_span.attributes['gen_ai.response.finish_reasons']).must_equal ['tool_use']
    end
  end

  describe 'error handling' do
    before do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return(status: 500, body: { error: { message: 'Internal Server Error' } }.to_json)
    end

    it 'handles API errors and records exception' do
      client = MockAnthropic::Client.new(api_key: 'test-token')

      begin
        client.messages.create(
          model: 'claude-3-opus-20240229',
          max_tokens: 1024,
          messages: [{ role: 'user', content: 'Hello' }]
        )
      rescue StandardError
        # Expected
      end

      _(client_span).wont_be_nil
      _(client_span.attributes['gen_ai.operation.name']).must_equal 'messages'
    end
  end

  describe 'non-instrumented operations' do
    it 'does not instrument operations not in allowed_operation' do
      # Temporarily modify allowed_operation to exclude 'messages'
      original_allowed = instrumentation.config[:allowed_operation].dup
      instrumentation.config[:allowed_operation] = ['completions']

      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return(status: 200, body: { id: 'msg_123' }.to_json, headers: { 'Content-Type' => 'application/json' })

      client = MockAnthropic::Client.new(api_key: 'test-token')
      client.messages.create(
        model: 'claude-3-opus-20240229',
        max_tokens: 1024,
        messages: [{ role: 'user', content: 'Hello' }]
      )

      # Restore
      instrumentation.config[:allowed_operation] = original_allowed

      # No span should be created for non-allowed operations
      _(spans).must_be_empty
    end
  end
end
