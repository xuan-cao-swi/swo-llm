# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require_relative 'utils'
require_relative 'stream_wrapper'

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        # Chat Patch - instruments RubyLLM::Chat#complete
        # rubocop:disable Metrics/ModuleLength
        module Chat
          include Utils

          def complete(&block)
            return super unless config[:allowed_operation].include?('chat')

            model_id = @model.respond_to?(:id) ? @model.id : @model.to_s
            provider_name = extract_provider_name(@provider)
            span_name = "chat #{model_id}"

            attributes = extract_request_attributes(model_id, provider_name)

            # For streaming, we need special handling
            if block_given?
              span = tracer.start_span(span_name, attributes: attributes, kind: :client)
              log_request_content(span) if config[:capture_content]

              stream_wrapper = StreamWrapper.new(span, config[:capture_content], provider_name)

              begin
                response = super(&stream_wrapper.wrap_block(&block))
                stream_wrapper.finalize(response)
                response
              rescue StandardError => e
                stream_wrapper.handle_error(e)
                raise
              ensure
                stream_wrapper.finish_span
              end
            else
              # Non-streaming path
              tracer.in_span(span_name, attributes: attributes, kind: :client) do |span|
                log_request_content(span) if config[:capture_content]

                response = super
                handle_response(span, response, provider_name)

                response
              rescue StandardError => e
                handle_span_exception(span, e)
                raise
              end
            end
          end

          private

          def tracer
            RubyLLM::Instrumentation.instance.tracer
          end

          def config
            RubyLLM::Instrumentation.instance.config
          end

          def extract_request_attributes(model_id, provider_name)
            attributes = {
              'gen_ai.operation.name' => 'chat',
              'gen_ai.provider.name' => provider_name,
              'gen_ai.request.model' => model_id,
              'gen_ai.output.type' => 'text'
            }

            # Add temperature if set
            if @temperature
              attributes['gen_ai.request.temperature'] = @temperature
            end

            # Add tool names if tools are configured
            if @tools.any?
              attributes['gen_ai.request.tools'] = @tools.keys.map(&:to_s)
            end

            attributes.compact
          end

          def log_request_content(span)
            # Log system message (instructions)
            system_messages = @messages.select { |m| m.role.to_s == 'system' }
            system_messages.each do |msg|
              content_text = extract_content_text(msg.content)
              next unless content_text && !content_text.empty?

              event = {
                event_name: 'gen_ai.system.message',
                attributes: { 'gen_ai.provider.name' => extract_provider_name(@provider) },
                body: { content: content_text }
              }
              log_structured_event(event)
            end

            # Log user and assistant messages
            @messages.each do |msg|
              next if msg.role.to_s == 'system'

              event = message_to_log_event(msg, capture_content: true)
              log_structured_event(event)
            end
          end

          def handle_response(span, response, provider_name)
            return unless span.recording?

            # Extract model information
            model_id = get_property_value(response, :model_id) || get_property_value(response, :model)
            response_id = get_property_value(response, :id)

            response_attributes = {
              'gen_ai.response.model' => model_id,
              'gen_ai.response.id' => response_id
            }.compact
            span.add_attributes(response_attributes)

            # Handle token usage
            set_usage_attributes(span, response)

            # Handle finish reason
            if response.respond_to?(:tool_call?) && response.tool_call?
              span.set_attribute('gen_ai.response.finish_reasons', ['tool_use'])
            else
              span.set_attribute('gen_ai.response.finish_reasons', ['stop'])
            end

            # Log response content
            return unless config[:capture_content]

            event = response_to_log_event(response, capture_content: true)
            event[:attributes]['gen_ai.provider.name'] = provider_name
            log_structured_event(event)
          end

          def set_usage_attributes(span, response)
            input_tokens = get_property_value(response, :input_tokens)
            output_tokens = get_property_value(response, :output_tokens)

            usage_attributes = {
              'gen_ai.usage.input_tokens' => input_tokens,
              'gen_ai.usage.output_tokens' => output_tokens
            }.compact

            span.add_attributes(usage_attributes)
          end

          def handle_span_exception(span, error)
            span.set_attribute('error.type', error.class.name)
            span.record_exception(error)
            span.status = OpenTelemetry::Trace::Status.error(error.message)
            span.finish
          end
        end
        # rubocop:enable Metrics/ModuleLength
      end
    end
  end
end
