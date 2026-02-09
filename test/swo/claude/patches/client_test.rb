# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'
require 'webmock/minitest'
require 'json'

require_relative '../../../../../lib/swo/llm/claude/opentelemetry/instrumentation'
require_relative '../../../../../lib/swo/llm/claude/opentelemetry/instrumentation/claude/patches/client'

# Mock Anthropic module and classes for testing without the actual gem
module Anthropic
  VERSION = '1.17.0'

  class Client
    def initialize(api_key: nil, base_url: nil, **_options)
      @api_key = api_key || ENV['ANTHROPIC_API_KEY']
      @base_url = base_url || 'https://api.anthropic.com'
    end

    def request(req)
      # This would be the actual HTTP request in the real gem
      # For testing, we'll simulate responses
      uri = URI.parse("#{@base_url}/#{req[:path]}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri.path)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = @api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = req[:body].to_json if req[:body]

      response = http.request(request)
      JSON.parse(response.body, symbolize_names: true)
    end

    def messages
      @messages ||= Messages.new(self)
    end
  end

  class Messages
    def initialize(client)
      @client = client
    end

    def create(params)
      body = {
        model: params[:model],
        max_tokens: params[:max_tokens],
        messages: params[:messages],
        temperature: params[:temperature],
        top_p: params[:top_p],
        top_k: params[:top_k],
        stop_sequences: params[:stop_sequences],
        system: params[:system]
      }.compact

      result = @client.request(
        method: :post,
        path: 'v1/messages',
        body: body
      )

      # Convert to struct-like object
      MessageResponse.new(result)
    end
  end

  class MessageResponse
    attr_reader :id, :model, :stop_reason, :content, :usage

    def initialize(data)
      @id = data[:id]
      @model = data[:model]
      @stop_reason = data[:stop_reason]
      @content = data[:content]&.map { |c| ContentBlock.new(c) }
      @usage = Usage.new(data[:usage]) if data[:usage]
    end
  end

  class ContentBlock
    attr_reader :type, :text, :id, :name, :input

    def initialize(data)
      @type = data[:type]
      @text = data[:text]
      @id = data[:id]
      @name = data[:name]
      @input = data[:input]
    end
  end

  class Usage
    attr_reader :input_tokens, :output_tokens

    def initialize(data)
      @input_tokens = data[:input_tokens]
      @output_tokens = data[:output_tokens]
    end
  end
end

describe OpenTelemetry::Instrumentation::Claude::Patches::Client do
  let(:instrumentation) { OpenTelemetry::Instrumentation::Claude::Instrumentation.instance }
  let(:exporter) { EXPORTER }
  let(:spans) { exporter.finished_spans }
  let(:client_span) { spans.first }

  before do
    exporter.reset
    # Apply the patch to our mock client
    unless Anthropic::Client.ancestors.include?(OpenTelemetry::Instrumentation::Claude::Patches::Client)
      Anthropic::Client.prepend(OpenTelemetry::Instrumentation::Claude::Patches::Client)
    end
    instrumentation.instance_variable_set(:@installed, true)
  end

  after do
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
      client = Anthropic::Client.new(api_key: 'test-token')
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
      _(client_span.attributes['server.address']).must_equal 'api.anthropic.com'
      _(client_span.attributes['server.port']).must_equal 443
      _(client_span.attributes['http.request.method']).must_equal 'POST'
      _(client_span.attributes['url.path']).must_equal 'v1/messages'
      _(client_span.attributes['gen_ai.response.model']).must_equal 'claude-3-opus-20240229'
      _(client_span.attributes['gen_ai.response.id']).must_equal 'msg_123abc'
      _(client_span.attributes['gen_ai.response.finish_reasons']).must_equal ['end_turn']
      _(client_span.attributes['gen_ai.usage.input_tokens']).must_equal 12
      _(client_span.attributes['gen_ai.usage.output_tokens']).must_equal 15
    end

    it 'sets optional parameters as attributes' do
      client = Anthropic::Client.new(api_key: 'test-token')
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

      client = Anthropic::Client.new(api_key: 'test-token')
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
      _(logged_message).must_include 'gen_ai.assistant.message'
      _(logged_message).must_include 'Hello! How can I assist you today?'
      _(logged_message).must_include 'anthropic'
    end

    it 'captures system message when present' do
      instrumentation.config[:capture_content] = true

      logger_output = StringIO.new
      original_logger = OpenTelemetry.logger
      OpenTelemetry.logger = Logger.new(logger_output, level: Logger::INFO)

      client = Anthropic::Client.new(api_key: 'test-token')
      client.messages.create(
        model: model,
        max_tokens: 1024,
        messages: messages,
        system: 'You are a helpful assistant.'
      )

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      logged_message = logger_output.string
      _(logged_message).must_include 'gen_ai.system.message'
      _(logged_message).must_include 'You are a helpful assistant.'
    end
  end

  describe 'tool use response' do
    let(:model) { 'claude-3-opus-20240229' }
    let(:messages) { [{ role: 'user', content: "What's the weather in NYC?" }] }
    let(:response_body) do
      {
        id: 'msg_456def',
        type: 'message',
        role: 'assistant',
        content: [
          {
            type: 'text',
            text: 'Let me check the weather for you.'
          },
          {
            type: 'tool_use',
            id: 'toolu_789',
            name: 'get_weather',
            input: { location: 'NYC' }
          }
        ],
        model: 'claude-3-opus-20240229',
        stop_reason: 'tool_use',
        usage: {
          input_tokens: 20,
          output_tokens: 35
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

      client = Anthropic::Client.new(api_key: 'test-token')
      client.messages.create(
        model: model,
        max_tokens: 1024,
        messages: messages
      )

      OpenTelemetry.logger = original_logger
      instrumentation.config[:capture_content] = false

      _(client_span.attributes['gen_ai.response.finish_reasons']).must_equal ['tool_use']

      logged_message = logger_output.string
      _(logged_message).must_include 'gen_ai.assistant.message'
      _(logged_message).must_include 'get_weather'
    end
  end

  describe 'error handling' do
    before do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return(status: 500, body: { error: { message: 'Internal Server Error' } }.to_json)
    end

    it 'handles API errors and records exception' do
      client = Anthropic::Client.new(api_key: 'test-token')

      # The mock client will raise an error on non-200 responses
      # or return the error body. Let's test the span is created.
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

      client = Anthropic::Client.new(api_key: 'test-token')
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
