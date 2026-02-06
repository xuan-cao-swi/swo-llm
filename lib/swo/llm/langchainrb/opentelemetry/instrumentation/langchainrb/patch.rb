# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'opentelemetry/semconv/incubating/gen_ai'

module OpenTelemetry
  module Instrumentation
    module Langchainrb
      module Patches
        # Patch for Langchain::LLM::Base to instrument LLM operations
        # rubocop:disable Metrics/ModuleLength
        module LLMBase
          # Instrument chat method
          def chat(params = {}, &)
            operation_name = 'chat'
            model = extract_model(params)
            provider = determine_provider
            span_name = model.empty? ? operation_name : "#{operation_name} #{model}"
            attributes = build_request_attributes(operation_name, model, provider, params)

            instrument_llm_operation(
              span_name,
              attributes,
              ->(span) { log_chat_request(span, params) },
              ->(span, response) { handle_chat_response(span, response, provider) }
            ) { super }
          end

          # Instrument complete method
          def complete(prompt:, **params)
            operation_name = 'complete'
            model = extract_model(params)
            provider = determine_provider
            span_name = model.empty? ? operation_name : "#{operation_name} #{model}"
            attributes = build_request_attributes(operation_name, model, provider, params)

            instrument_llm_operation(
              span_name,
              attributes,
              ->(span) { log_prompt_request(span, prompt, provider) },
              ->(span, response) { handle_chat_response(span, response, provider) }
            ) { super }
          end

          # Instrument embed method
          def embed(text:, **params)
            operation_name = 'embeddings'
            model = params[:model] || defaults[:embeddings_model_name]
            provider = determine_provider
            span_name = model.to_s.empty? ? operation_name : "#{operation_name} #{model}"
            attributes = build_request_attributes(operation_name, model.to_s, provider, params)

            instrument_llm_operation(
              span_name,
              attributes,
              ->(span) { log_embed_request(span, text, provider) },
              ->(span, response) { handle_embed_response(span, response) }
            ) { super }
          end

          # Instrument summarize method
          def summarize(text:)
            operation_name = 'summarize'
            provider = determine_provider
            span_name = operation_name
            attributes = build_request_attributes(operation_name, '', provider, {})

            instrument_llm_operation(
              span_name,
              attributes,
              ->(span) { log_prompt_request(span, text, provider) },
              ->(span, response) { handle_chat_response(span, response, provider) }
            ) { super }
          end

          private

          def tracer
            Langchainrb::Instrumentation.instance.tracer
          end

          def config
            Langchainrb::Instrumentation.instance.config
          end

          # Generic instrumentation wrapper for LLM operations
          def instrument_llm_operation(span_name, attributes, log_request_proc, handle_response_proc)
            tracer.in_span(
              span_name,
              attributes: attributes,
              kind: :client
            ) do |span|
              log_request_proc.call(span) if config[:capture_content] && log_request_proc

              response = yield

              handle_response_proc&.call(span, response)

              response
            rescue StandardError => e
              handle_span_exception(span, e)
              raise
            end
          end

          # Determine the LLM provider from the class name
          def determine_provider
            class_name = self.class.name.to_s
            case class_name
            when /OpenAI/i
              'openai'
            when /Anthropic/i
              'anthropic'
            when /GoogleGemini/i, /GoogleVertexAI/i, /GooglePalm/i
              'google'
            when /Cohere/i
              'cohere'
            when /AI21/i
              'ai21'
            when /HuggingFace/i
              'huggingface'
            when /Ollama/i
              'ollama'
            when /Azure/i
              'azure'
            when /Replicate/i
              'replicate'
            when /LlamaCpp/i
              'llamacpp'
            when /MistralAI/i
              'mistralai'
            else
              'langchain'
            end
          end

          # Extract model from params
          def extract_model(params)
            model = params[:model] || params['model']
            model ||= defaults[:chat_completion_model_name] if respond_to?(:defaults) && defaults
            model.to_s
          end

          # Build request attributes following GenAI semantic conventions
          def build_request_attributes(operation_name, model, provider, params)
            attributes = {
              OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_OPERATION_NAME => operation_name,
              'gen_ai.provider.name' => provider,
              OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_REQUEST_MODEL => model,
              OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_OUTPUT_TYPE => get_output_type(operation_name)
            }.compact

            # Add chat-specific attributes
            if %w[chat complete].include?(operation_name)
              merge_chat_attributes!(attributes, params)
            elsif operation_name == 'embeddings'
              merge_embeddings_attributes!(attributes, params)
            end

            attributes
          end

          def get_output_type(operation_name)
            case operation_name
            when 'chat', 'complete', 'summarize'
              'text'
            when 'embeddings'
              'embedding'
            else
              'json'
            end
          end

          # Merge chat-specific attributes
          def merge_chat_attributes!(attributes, params)
            chat_attributes = {
              OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_REQUEST_TEMPERATURE => params[:temperature],
              OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_REQUEST_MAX_TOKENS => params[:max_tokens],
              OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_REQUEST_TOP_P => params[:top_p],
              OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_REQUEST_FREQUENCY_PENALTY => params[:frequency_penalty],
              OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_REQUEST_PRESENCE_PENALTY => params[:presence_penalty],
              OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_REQUEST_STOP_SEQUENCES => normalize_stop_sequences(params[:stop])
            }.compact

            attributes.merge!(chat_attributes)
          end

          def normalize_stop_sequences(stop)
            return nil unless stop

            stop.is_a?(Array) ? stop : [stop]
          end

          # Merge embeddings-specific attributes
          def merge_embeddings_attributes!(attributes, params)
            embeddings_attributes = {
              OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_REQUEST_ENCODING_FORMATS => params[:encoding_format] ? [params[:encoding_format].to_s] : nil,
              'gen_ai.request.dimensions' => params[:dimensions]
            }.compact

            attributes.merge!(embeddings_attributes)
          end

          # Log chat request content
          def log_chat_request(span, params)
            messages = params[:messages]
            return unless messages.is_a?(Array)

            provider = determine_provider
            messages.each do |message|
              event = message_to_log_event(message, provider)
              log_structured_event(event)
            end
          end

          # Log prompt request content
          def log_prompt_request(span, prompt, provider)
            event = {
              event_name: 'gen_ai.user.message',
              attributes: { 'gen_ai.provider.name' => provider },
              body: { content: prompt.to_s }
            }
            log_structured_event(event)
          end

          # Log embed request content
          def log_embed_request(span, text, provider)
            input_text = text.is_a?(Array) ? text.join(', ') : text.to_s
            event = {
              event_name: 'gen_ai.user.message',
              attributes: { 'gen_ai.provider.name' => provider },
              body: { content: input_text }
            }
            log_structured_event(event)
          end

          # Convert message to log event
          def message_to_log_event(message, provider)
            role = get_property_value(message, :role)&.to_s
            content = get_property_value(message, :content)

            body = {}
            body[:content] = content.to_s if content

            if role == 'assistant'
              tool_calls = extract_tool_calls(message)
              body[:tool_calls] = tool_calls if tool_calls
            elsif role == 'tool'
              tool_call_id = get_property_value(message, :tool_call_id)
              body[:id] = tool_call_id if tool_call_id
            end

            {
              event_name: "gen_ai.#{role}.message",
              attributes: { 'gen_ai.provider.name' => provider },
              body: body.empty? ? nil : body
            }
          end

          # Extract tool calls from message
          def extract_tool_calls(message)
            tool_calls = get_property_value(message, :tool_calls)
            return nil unless tool_calls

            tool_calls.map do |tool_call|
              tool_call_dict = {}
              tool_call_dict[:id] = get_property_value(tool_call, :id) if get_property_value(tool_call, :id)
              tool_call_dict[:type] = get_property_value(tool_call, :type)&.to_s if get_property_value(tool_call, :type)

              func = get_property_value(tool_call, :function)
              if func
                tool_call_dict[:function] = {
                  name: get_property_value(func, :name),
                  arguments: get_property_value(func, :arguments)
                }.compact
              end

              tool_call_dict
            end
          end

          # Get property value from hash or object
          def get_property_value(obj, property_name)
            if obj.is_a?(Hash)
              obj[property_name] || obj[property_name.to_s]
            else
              obj.respond_to?(property_name) ? obj.public_send(property_name) : nil
            end
          end

          # Handle chat/complete response
          def handle_chat_response(span, response, provider)
            return unless span.recording?
            return unless response

            response_attributes = {}

            # Extract model from response
            response_attributes[OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_RESPONSE_MODEL] = response.model if response.respond_to?(:model) && response.model

            # Extract response ID if available
            if response.respond_to?(:raw_response)
              raw = response.raw_response
              response_attributes[OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_RESPONSE_ID] = raw['id'] if raw['id']
              response_attributes[OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_OPENAI_RESPONSE_SYSTEM_FINGERPRINT] = raw['system_fingerprint'] if raw['system_fingerprint']
              response_attributes[OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_OPENAI_RESPONSE_SERVICE_TIER] = raw['service_tier'] if raw['service_tier']
            end

            span.add_attributes(response_attributes.compact)

            # Set usage attributes
            set_usage_attributes(span, response)

            # Set finish reasons
            set_finish_reasons(span, response)

            # Log response content
            log_chat_response(response, provider) if config[:capture_content]
          end

          # Handle embed response
          def handle_embed_response(span, response)
            return unless span.recording?
            return unless response

            # Get embedding dimensions
            span.set_attribute('gen_ai.embeddings.dimension.count', response.embedding.size) if response.respond_to?(:embedding) && response.embedding

            # Set usage attributes
            set_usage_attributes(span, response)
          end

          # Set token usage attributes
          def set_usage_attributes(span, response)
            return unless response

            usage_attributes = {}

            usage_attributes[OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_USAGE_INPUT_TOKENS] = response.prompt_tokens if response.respond_to?(:prompt_tokens) && response.prompt_tokens

            usage_attributes[OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_USAGE_OUTPUT_TOKENS] = response.completion_tokens if response.respond_to?(:completion_tokens) && response.completion_tokens

            usage_attributes['gen_ai.usage.total_tokens'] = response.total_tokens if response.respond_to?(:total_tokens) && response.total_tokens

            span.add_attributes(usage_attributes) unless usage_attributes.empty?
          end

          # Set finish reasons from response
          def set_finish_reasons(span, response)
            return unless response.respond_to?(:raw_response) && response.raw_response

            choices = response.raw_response['choices']
            return unless choices.is_a?(Array) && choices.any?

            finish_reasons = choices.filter_map { |c| c['finish_reason'] }
            span.set_attribute(OpenTelemetry::SemConv::Incubating::GEN_AI::GEN_AI_RESPONSE_FINISH_REASONS, finish_reasons) if finish_reasons.any?
          end

          # Log chat response content
          def log_chat_response(response, provider)
            return unless response.respond_to?(:raw_response) && response.raw_response

            choices = response.raw_response['choices']
            return unless choices.is_a?(Array)

            choices.each_with_index do |choice, index|
              event = choice_to_log_event(choice, index, provider)
              log_structured_event(event)
            end
          end

          # Convert choice to log event
          def choice_to_log_event(choice, index, provider)
            body = {
              index: choice['index'] || index,
              finish_reason: choice['finish_reason'] || 'error'
            }

            message = choice['message']
            if message
              msg_body = { role: message['role'] }
              msg_body[:content] = message['content'] if message['content']

              if message['tool_calls']
                msg_body[:tool_calls] = message['tool_calls'].map do |tc|
                  {
                    id: tc['id'],
                    type: tc['type'],
                    function: {
                      name: tc.dig('function', 'name'),
                      arguments: tc.dig('function', 'arguments')
                    }.compact
                  }
                end
              end

              body[:message] = msg_body
            end

            {
              event_name: 'gen_ai.choice',
              attributes: { 'gen_ai.provider.name' => provider },
              body: body
            }
          end

          # Log structured event
          def log_structured_event(event)
            log_message = {
              event: event[:event_name],
              attributes: event[:attributes],
              body: event[:body]
            }.compact

            OpenTelemetry.logger.info(log_message.to_json)
          end

          # Handle span exception
          def handle_span_exception(span, error)
            span.set_attribute('error.type', error.class.name)
            span.record_exception(error)
            span.status = OpenTelemetry::Trace::Status.error(error.message)
          end
        end
        # rubocop:enable Metrics/ModuleLength
      end
    end
  end
end
