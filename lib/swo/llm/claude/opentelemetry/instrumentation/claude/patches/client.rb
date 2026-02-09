# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require_relative 'operation_name'
require_relative 'stream_wrapper'
require_relative 'utils'

module OpenTelemetry
  module Instrumentation
    module Claude
      module Patches
        # Anthropic Client Patch
        # Instruments the Anthropic::Client#request method to capture telemetry data
        # rubocop:disable  Metrics/ModuleLength
        module Client
          include OperationName
          include Utils

          def request(req)
            operation_name = determine_operation_name(req)

            # Only instrument implemented/tested Anthropic operations
            return super unless config[:allowed_operation].include?(operation_name)

            model = extract_model(req)
            span_name = model.to_s.empty? ? operation_name : "#{operation_name} #{model}"
            attributes = extract_request_attributes(req, operation_name, model)

            # For streaming, start span manually so it stays open during iteration
            if req[:stream]
              span = tracer.start_span(span_name, attributes: attributes, kind: :client)
              log_request_content(span, req) if config[:capture_content]

              response = super
              return StreamWrapper.new(response, span, config[:capture_content])
            end

            # Non-streaming path
            tracer.in_span(
              span_name,
              attributes: attributes,
              kind: :client
            ) do |span|
              log_request_content(span, req) if config[:capture_content]

              response = super
              handle_response(span, response, req)

              response
            rescue StandardError => e
              handle_span_exception(span, e)
              raise
            end
          end

          private

          def tracer
            Claude::Instrumentation.instance.tracer
          end

          def config
            Claude::Instrumentation.instance.config
          end

          def extract_model(req)
            body = req[:body]
            return nil unless body.is_a?(Hash)

            (body[:model] || body['model']).to_s
          end

          # Extract comprehensive request attributes following semantic conventions
          def extract_request_attributes(req, operation_name, model)
            uri = begin
              URI.parse(req[:url] || '')
            rescue StandardError
              nil
            end

            request_attributes = {
              'gen_ai.operation.name' => operation_name,
              'gen_ai.provider.name' => 'anthropic',
              'gen_ai.request.model' => model,
              'server.address' => uri&.host || 'api.anthropic.com',
              'server.port' => uri&.port || 443,
              'http.request.method' => req[:method].to_s.upcase,
              'url.path' => req[:path],
              'gen_ai.output.type' => get_output_type(operation_name)
            }.compact

            merge_body_attributes!(request_attributes, req[:body], operation_name)

            request_attributes
          end

          def get_output_type(operation_name)
            case operation_name
            when 'messages', 'completions'
              'text'
            when 'messages.count_tokens'
              'json'
            else
              'json'
            end
          end

          # Merge body attributes based on operation type
          def merge_body_attributes!(attributes, body, operation_name)
            return unless body.is_a?(Hash)

            case operation_name
            when 'messages'
              merge_messages_attributes!(attributes, body)
            when 'completions'
              merge_completions_attributes!(attributes, body)
            end
          end

          # Merge messages-specific attributes
          def merge_messages_attributes!(attributes, body)
            stop_sequences = body[:stop_sequences]

            messages_attributes = {
              'gen_ai.request.temperature' => body[:temperature],
              'gen_ai.request.max_tokens' => body[:max_tokens],
              'gen_ai.request.top_p' => body[:top_p],
              'gen_ai.request.top_k' => body[:top_k],
              'gen_ai.request.stop_sequences' => stop_sequences.is_a?(Array) ? stop_sequences : nil,
              'anthropic.request.thinking' => body[:thinking] ? true : nil
            }.compact

            attributes.merge!(messages_attributes)
          end

          # Merge completions-specific attributes (legacy API)
          def merge_completions_attributes!(attributes, body)
            stop_sequences = body[:stop_sequences]

            completions_attributes = {
              'gen_ai.request.temperature' => body[:temperature],
              'gen_ai.request.max_tokens' => body[:max_tokens_to_sample],
              'gen_ai.request.top_p' => body[:top_p],
              'gen_ai.request.top_k' => body[:top_k],
              'gen_ai.request.stop_sequences' => stop_sequences.is_a?(Array) ? stop_sequences : nil
            }.compact

            attributes.merge!(completions_attributes)
          end

          # Log request content for debugging/monitoring
          def log_request_content(span, req)
            body = req[:body]
            return unless body.is_a?(Hash)

            # Log system message if present
            if body[:system]
              system_content = body[:system]
              system_text = if system_content.is_a?(String)
                              system_content
                            elsif system_content.is_a?(Array)
                              system_content.map { |b| get_property_value(b, :text) }.compact.join
                            end

              if system_text && !system_text.empty?
                event = {
                  event_name: 'gen_ai.system.message',
                  attributes: { 'gen_ai.provider.name' => 'anthropic' },
                  body: { content: system_text }
                }
                log_structured_event(event)
              end
            end

            # Log messages
            if body[:messages].is_a?(Array)
              body[:messages].each do |message|
                event = message_to_log_event(message, capture_content: true)
                log_structured_event(event)
              end
            end

            # Log prompt for legacy completions API
            return unless body[:prompt]

            event = {
              event_name: 'gen_ai.user.message',
              attributes: { 'gen_ai.provider.name' => 'anthropic' },
              body: { content: body[:prompt].to_s }
            }
            log_structured_event(event)
          end

          # Handle different response types and extract telemetry data
          def handle_response(span, result, _req)
            return unless span.recording?

            response_attributes = {
              'gen_ai.response.model' => result.respond_to?(:model) ? result.model : nil,
              'gen_ai.response.id' => result.respond_to?(:id) ? result.id : nil
            }.compact
            span.add_attributes(response_attributes)

            # Handle usage/token information
            set_usage_attributes(span, result.usage) if result.respond_to?(:usage) && result.usage

            # Handle stop reason
            if result.respond_to?(:stop_reason) && result.stop_reason
              span.set_attribute('gen_ai.response.finish_reasons', [result.stop_reason.to_s])
            end

            # Log response content if capture_content is enabled
            return unless config[:capture_content]

            if result.respond_to?(:content) && result.content
              event = response_to_log_event(result, capture_content: true)
              log_structured_event(event)
            elsif result.respond_to?(:completion)
              # Legacy completions API
              event = {
                event_name: 'gen_ai.assistant.message',
                attributes: { 'gen_ai.provider.name' => 'anthropic' },
                body: { content: result.completion.to_s }
              }
              log_structured_event(event)
            end
          end

          # Set token usage attributes
          def set_usage_attributes(span, usage)
            usage_attributes = {
              'gen_ai.usage.input_tokens' => usage.respond_to?(:input_tokens) ? usage.input_tokens : nil,
              'gen_ai.usage.output_tokens' => usage.respond_to?(:output_tokens) ? usage.output_tokens : nil
            }.compact

            span.add_attributes(usage_attributes)
          end

          # Handle span exception
          def handle_span_exception(span, error)
            span.set_attribute('error.type', error.class.name)
            span.record_exception(error)
            span.status = OpenTelemetry::Trace::Status.error(error.message)
            span.finish
          end
        end
        # rubocop:enable  Metrics/ModuleLength
      end
    end
  end
end
