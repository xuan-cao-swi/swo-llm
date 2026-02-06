# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'
require_relative '../../../../lib/opentelemetry/instrumentation/langchainrb'
require_relative '../../../../lib/opentelemetry/instrumentation/langchainrb/patch'

describe OpenTelemetry::Instrumentation::Langchainrb::Patches::LLMBase do
  let(:instrumentation) { OpenTelemetry::Instrumentation::Langchainrb::Instrumentation.instance }
  let(:exporter) { EXPORTER }
  let(:spans) { exporter.finished_spans }
  let(:chat_span) { spans.find { |s| s.name.include?('chat') } }
  let(:embed_span) { spans.find { |s| s.name.include?('embeddings') } }
  let(:complete_span) { spans.find { |s| s.name.include?('complete') } }
  let(:summarize_span) { spans.find { |s| s.name == 'summarize' } }

  before do
    exporter.reset
    # Reset and install instrumentation to patch our mock classes
    instrumentation.instance_variable_set(:@installed, false)
    instrumentation.install({})
  end

  after do
  end

  describe 'basic setup' do
    it 'has a valid tracer' do
      tracer = OpenTelemetry::Instrumentation::Langchainrb::Instrumentation.instance.tracer
      _(tracer).wont_be_nil

      tracer.in_span('test') do |span|
        _(span).wont_be_nil
      end

      _(spans.length).must_equal 1
      _(spans.first.name).must_equal 'test'
    end
  end

  describe 'OpenAI instrumentation' do
    let(:llm) { Langchain::LLM::OpenAI.new(api_key: 'test-key') }

    describe '#chat' do
      it 'creates a span with correct attributes' do
        messages = [
          { role: 'system', content: 'You are a helpful assistant.' },
          { role: 'user', content: 'Which year is now?' }
        ]

        raw_response = {
          'id' => 'chatcmpl-123',
          'object' => 'chat.completion',
          'model' => 'gpt-4o-mini-2024-07-18',
          'choices' => [
            {
              'index' => 0,
              'message' => {
                'role' => 'assistant',
                'content' => 'The current year is 2024.'
              },
              'finish_reason' => 'stop'
            }
          ],
          'usage' => {
            'prompt_tokens' => 26,
            'completion_tokens' => 8,
            'total_tokens' => 34
          },
          'system_fingerprint' => 'fp_test123'
        }

        response = MockResponse.new(
          raw_response,
          model: 'gpt-4o-mini-2024-07-18',
          prompt_tokens: 26,
          completion_tokens: 8,
          total_tokens: 34
        )

        llm.mock_response(response)
        llm.chat(messages: messages, model: 'gpt-4o-mini', temperature: 0.7, max_tokens: 256)

        _(chat_span).wont_be_nil
        _(chat_span.name).must_equal 'chat gpt-4o-mini'
        _(chat_span.kind).must_equal :client
        _(chat_span.attributes['gen_ai.operation.name']).must_equal 'chat'
        _(chat_span.attributes['gen_ai.provider.name']).must_equal 'openai'
        _(chat_span.attributes['gen_ai.request.model']).must_equal 'gpt-4o-mini'
        _(chat_span.attributes['gen_ai.output.type']).must_equal 'text'
        _(chat_span.attributes['gen_ai.request.temperature']).must_equal 0.7
        _(chat_span.attributes['gen_ai.request.max_tokens']).must_equal 256
        _(chat_span.attributes['gen_ai.response.model']).must_equal 'gpt-4o-mini-2024-07-18'
        _(chat_span.attributes['gen_ai.usage.input_tokens']).must_equal 26
        _(chat_span.attributes['gen_ai.usage.output_tokens']).must_equal 8
        _(chat_span.attributes['gen_ai.usage.total_tokens']).must_equal 34
        _(chat_span.attributes['gen_ai.response.finish_reasons']).must_equal ['stop']
        _(chat_span.attributes['gen_ai.openai.response.system_fingerprint']).must_equal 'fp_test123'
      end

      it 'handles errors correctly' do
        # Set the mock to raise an error when methods are called
        llm.mock_response(StandardError.new('API Error'))

        _ { llm.chat(messages: [{ role: 'user', content: 'test' }]) }.must_raise StandardError

        _(chat_span).wont_be_nil
        _(chat_span.status.code).must_equal OpenTelemetry::Trace::Status::ERROR
        # NOTE: OpenTelemetry SDK sets the status description, not our code
        _(chat_span.attributes['error.type']).must_equal 'StandardError'
        _(chat_span.events.first.name).must_equal 'exception'
        _(chat_span.events.first.attributes['exception.message']).must_equal 'API Error'
      end
    end

    describe '#embed' do
      it 'creates a span with correct attributes' do
        raw_response = {
          'object' => 'list',
          'data' => [
            {
              'object' => 'embedding',
              'index' => 0,
              'embedding' => Array.new(1536) { rand }
            }
          ],
          'model' => 'text-embedding-3-small',
          'usage' => {
            'prompt_tokens' => 9,
            'total_tokens' => 9
          }
        }

        response = MockResponse.new(
          raw_response,
          model: 'text-embedding-3-small',
          prompt_tokens: 9,
          total_tokens: 9,
          embedding: raw_response['data'][0]['embedding']
        )

        llm.mock_response(response)
        llm.embed(text: 'The quick brown fox', model: 'text-embedding-3-small')

        _(embed_span).wont_be_nil
        _(embed_span.name).must_equal 'embeddings text-embedding-3-small'
        _(embed_span.kind).must_equal :client
        _(embed_span.attributes['gen_ai.operation.name']).must_equal 'embeddings'
        _(embed_span.attributes['gen_ai.provider.name']).must_equal 'openai'
        _(embed_span.attributes['gen_ai.request.model']).must_equal 'text-embedding-3-small'
        _(embed_span.attributes['gen_ai.output.type']).must_equal 'embedding'
        _(embed_span.attributes['gen_ai.embeddings.dimension.count']).must_equal 1536
        _(embed_span.attributes['gen_ai.usage.input_tokens']).must_equal 9
        _(embed_span.attributes['gen_ai.usage.total_tokens']).must_equal 9
      end
    end

    describe '#complete' do
      it 'creates a span with correct attributes' do
        raw_response = {
          'id' => 'chatcmpl-456',
          'model' => 'gpt-4o-mini-2024-07-18',
          'choices' => [
            {
              'index' => 0,
              'message' => {
                'role' => 'assistant',
                'content' => 'Paris'
              },
              'finish_reason' => 'stop'
            }
          ],
          'usage' => {
            'prompt_tokens' => 14,
            'completion_tokens' => 7,
            'total_tokens' => 21
          }
        }

        response = MockResponse.new(
          raw_response,
          model: 'gpt-4o-mini-2024-07-18',
          prompt_tokens: 14,
          completion_tokens: 7,
          total_tokens: 21
        )

        llm.mock_response(response)
        llm.complete(prompt: 'What is the capital of France?', model: 'gpt-4o-mini')

        _(complete_span).wont_be_nil
        _(complete_span.name).must_equal 'complete gpt-4o-mini'
        _(complete_span.attributes['gen_ai.operation.name']).must_equal 'complete'
        _(complete_span.attributes['gen_ai.provider.name']).must_equal 'openai'
        _(complete_span.attributes['gen_ai.usage.total_tokens']).must_equal 21
      end
    end

    describe '#summarize' do
      it 'creates a span with correct attributes' do
        raw_response = {
          'id' => 'chatcmpl-789',
          'model' => 'gpt-4o-mini-2024-07-18',
          'choices' => [
            {
              'index' => 0,
              'message' => {
                'role' => 'assistant',
                'content' => 'Summary of the text...'
              },
              'finish_reason' => 'stop'
            }
          ],
          'usage' => {
            'prompt_tokens' => 185,
            'completion_tokens' => 105,
            'total_tokens' => 290
          }
        }

        response = MockResponse.new(
          raw_response,
          prompt_tokens: 185,
          completion_tokens: 105,
          total_tokens: 290
        )

        llm.mock_response(response)
        llm.summarize(text: 'Long text to summarize...')

        _(summarize_span).wont_be_nil
        _(summarize_span.name).must_equal 'summarize'
        _(summarize_span.attributes['gen_ai.operation.name']).must_equal 'summarize'
        _(summarize_span.attributes['gen_ai.provider.name']).must_equal 'openai'
        _(summarize_span.attributes['gen_ai.output.type']).must_equal 'text'
      end
    end
  end

  describe 'Anthropic Claude instrumentation' do
    let(:llm) { Langchain::LLM::Anthropic.new(api_key: 'test-key') }

    describe '#chat' do
      it 'creates a span with correct attributes for Claude' do
        messages = [{ role: 'user', content: 'Which year is now?' }]

        raw_response = {
          'model' => 'claude-3-haiku-20240307',
          'id' => 'msg_01Utz9vFzDRDaCya4FTcpKgy',
          'type' => 'message',
          'role' => 'assistant',
          'content' => [
            {
              'type' => 'text',
              'text' => 'The current year is 2024.'
            }
          ],
          'stop_reason' => 'end_turn',
          'usage' => {
            'input_tokens' => 12,
            'output_tokens' => 11,
            'service_tier' => 'standard'
          }
        }

        response = MockResponse.new(
          raw_response,
          model: 'claude-3-haiku-20240307',
          prompt_tokens: 12,
          completion_tokens: 11,
          total_tokens: 23
        )

        llm.mock_response(response)
        llm.chat(messages: messages, model: 'claude-3-haiku-20240307', max_tokens: 256, temperature: 0.7)

        _(chat_span).wont_be_nil
        _(chat_span.name).must_equal 'chat claude-3-haiku-20240307'
        _(chat_span.attributes['gen_ai.operation.name']).must_equal 'chat'
        _(chat_span.attributes['gen_ai.provider.name']).must_equal 'anthropic'
        _(chat_span.attributes['gen_ai.request.model']).must_equal 'claude-3-haiku-20240307'
        _(chat_span.attributes['gen_ai.usage.input_tokens']).must_equal 12
        _(chat_span.attributes['gen_ai.usage.output_tokens']).must_equal 11
        _(chat_span.attributes['gen_ai.usage.total_tokens']).must_equal 23
      end
    end
  end

  describe 'Google Gemini instrumentation' do
    let(:llm) { Langchain::LLM::GoogleGemini.new(api_key: 'test-key') }

    describe '#chat' do
      it 'creates a span with correct attributes for Gemini' do
        messages = [{ role: 'user', parts: [{ text: 'Which year is now?' }] }]

        raw_response = {
          'candidates' => [
            {
              'content' => {
                'parts' => [
                  {
                    'text' => 'The current year is 2024.'
                  }
                ],
                'role' => 'model'
              },
              'finishReason' => 'STOP'
            }
          ],
          'usageMetadata' => {
            'promptTokenCount' => 5,
            'candidatesTokenCount' => 52,
            'totalTokenCount' => 57
          },
          'modelVersion' => 'gemini-2.0-flash-lite',
          'responseId' => 'test123'
        }

        response = MockResponse.new(
          raw_response,
          model: 'gemini-2.0-flash-lite',
          prompt_tokens: 5,
          completion_tokens: 52,
          total_tokens: 57
        )

        llm.mock_response(response)
        llm.chat(messages: messages, model: 'gemini-2.0-flash-lite')

        _(chat_span).wont_be_nil
        _(chat_span.name).must_equal 'chat gemini-2.0-flash-lite'
        _(chat_span.attributes['gen_ai.provider.name']).must_equal 'google'
        _(chat_span.attributes['gen_ai.request.model']).must_equal 'gemini-2.0-flash-lite'
        _(chat_span.attributes['gen_ai.usage.input_tokens']).must_equal 5
        _(chat_span.attributes['gen_ai.usage.output_tokens']).must_equal 52
        _(chat_span.attributes['gen_ai.usage.total_tokens']).must_equal 57
      end
    end

    describe '#embed' do
      it 'creates a span with correct attributes for Gemini embeddings' do
        raw_response = {
          'embedding' => {
            'values' => Array.new(768) { rand }
          }
        }

        response = MockResponse.new(
          raw_response,
          model: 'text-embedding-004',
          embedding: raw_response['embedding']['values']
        )

        llm.mock_response(response)
        llm.embed(text: 'The quick brown fox', model: 'text-embedding-004')

        _(embed_span).wont_be_nil
        _(embed_span.name).must_equal 'embeddings text-embedding-004'
        _(embed_span.attributes['gen_ai.provider.name']).must_equal 'google'
        _(embed_span.attributes['gen_ai.embeddings.dimension.count']).must_equal 768
      end
    end
  end

  describe 'MistralAI instrumentation' do
    let(:llm) { Langchain::LLM::MistralAI.new(api_key: 'test-key') }

    describe '#chat' do
      it 'creates a span with correct attributes for MistralAI' do
        messages = [{ role: 'user', content: 'Which year is now?' }]

        raw_response = {
          'id' => '9af3d7e2abc4420290dc638d5cef4538',
          'created' => 1_767_900_397,
          'model' => 'mistral-large-latest',
          'usage' => {
            'prompt_tokens' => 8,
            'total_tokens' => 64,
            'completion_tokens' => 56
          },
          'object' => 'chat.completion',
          'choices' => [
            {
              'index' => 0,
              'finish_reason' => 'stop',
              'message' => {
                'role' => 'assistant',
                'content' => 'The current year is 2024.'
              }
            }
          ]
        }

        response = MockResponse.new(
          raw_response,
          model: 'mistral-large-latest',
          prompt_tokens: 8,
          completion_tokens: 56,
          total_tokens: 64
        )

        llm.mock_response(response)
        llm.chat(messages: messages, model: 'mistral-large-latest')

        _(chat_span).wont_be_nil
        _(chat_span.name).must_equal 'chat mistral-large-latest'
        _(chat_span.attributes['gen_ai.provider.name']).must_equal 'mistralai'
        _(chat_span.attributes['gen_ai.request.model']).must_equal 'mistral-large-latest'
        _(chat_span.attributes['gen_ai.usage.input_tokens']).must_equal 8
        _(chat_span.attributes['gen_ai.usage.output_tokens']).must_equal 56
        _(chat_span.attributes['gen_ai.usage.total_tokens']).must_equal 64
      end
    end

    describe '#embed' do
      it 'creates a span with correct attributes for MistralAI embeddings' do
        raw_response = {
          'id' => '3e2efab942f646d5b465dc82bcb93bfd',
          'object' => 'list',
          'data' => [
            {
              'object' => 'embedding',
              'embedding' => Array.new(1024) { rand },
              'index' => 0
            }
          ],
          'model' => 'mistral-embed',
          'usage' => {
            'prompt_tokens' => 13,
            'total_tokens' => 13,
            'completion_tokens' => 0
          }
        }

        response = MockResponse.new(
          raw_response,
          model: 'mistral-embed',
          prompt_tokens: 13,
          total_tokens: 13,
          embedding: raw_response['data'][0]['embedding']
        )

        llm.mock_response(response)
        llm.embed(text: 'The quick brown fox', model: 'mistral-embed')

        _(embed_span).wont_be_nil
        _(embed_span.name).must_equal 'embeddings mistral-embed'
        _(embed_span.attributes['gen_ai.provider.name']).must_equal 'mistralai'
        _(embed_span.attributes['gen_ai.embeddings.dimension.count']).must_equal 1024
        _(embed_span.attributes['gen_ai.usage.input_tokens']).must_equal 13
      end
    end
  end

  describe 'provider detection' do
    it 'detects OpenAI provider' do
      llm = Langchain::LLM::OpenAI.new(api_key: 'test-key')
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [])
      _(chat_span.attributes['gen_ai.provider.name']).must_equal 'openai'
    end

    it 'detects Anthropic provider' do
      llm = Langchain::LLM::Anthropic.new(api_key: 'test-key')
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [])
      _(chat_span.attributes['gen_ai.provider.name']).must_equal 'anthropic'
    end

    it 'detects Google provider' do
      llm = Langchain::LLM::GoogleGemini.new(api_key: 'test-key')
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [])
      _(chat_span.attributes['gen_ai.provider.name']).must_equal 'google'
    end

    it 'detects MistralAI provider' do
      llm = Langchain::LLM::MistralAI.new(api_key: 'test-key')
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [])
      _(chat_span.attributes['gen_ai.provider.name']).must_equal 'mistralai'
    end
  end

  describe 'request parameters handling' do
    let(:llm) { Langchain::LLM::OpenAI.new(api_key: 'test-key') }

    it 'captures temperature parameter' do
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [], temperature: 0.5)
      _(chat_span.attributes['gen_ai.request.temperature']).must_equal 0.5
    end

    it 'captures max_tokens parameter' do
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [], max_tokens: 1024)
      _(chat_span.attributes['gen_ai.request.max_tokens']).must_equal 1024
    end

    it 'captures top_p parameter' do
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [], top_p: 0.9)
      _(chat_span.attributes['gen_ai.request.top_p']).must_equal 0.9
    end

    it 'captures frequency_penalty parameter' do
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [], frequency_penalty: 0.5)
      _(chat_span.attributes['gen_ai.request.frequency_penalty']).must_equal 0.5
    end

    it 'captures presence_penalty parameter' do
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [], presence_penalty: 0.3)
      _(chat_span.attributes['gen_ai.request.presence_penalty']).must_equal 0.3
    end

    it 'normalizes stop sequences as array' do
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [], stop: 'END')
      _(chat_span.attributes['gen_ai.request.stop_sequences']).must_equal ['END']
    end

    it 'keeps stop sequences as array' do
      llm.mock_response(MockResponse.new({}))
      llm.chat(messages: [], stop: %w[END STOP])
      _(chat_span.attributes['gen_ai.request.stop_sequences']).must_equal %w[END STOP]
    end
  end
end
