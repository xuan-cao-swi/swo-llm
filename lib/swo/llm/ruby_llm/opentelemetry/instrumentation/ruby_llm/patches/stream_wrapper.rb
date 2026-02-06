# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require_relative 'utils'

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        # Stream wrapper for RubyLLM streaming responses
        # Wraps the streaming block to capture telemetry data
        class StreamWrapper
          include Utils

          attr_reader :span, :capture_content, :provider_name

          def initialize(span, capture_content, provider_name)
            @span = span
            @capture_content = capture_content
            @provider_name = provider_name
            @content_buffer = []
            @tool_call_buffers = {}
            @input_tokens = 0
            @output_tokens = 0
            @model = nil
            @response_id = nil
            @finish_reason = nil
          end

          # Wrap the user's streaming block to capture chunks
          def wrap_block(&user_block)
            proc do |chunk|
              process_chunk(chunk)
              user_block.call(chunk) if user_block
            end
          end

          def process_chunk(chunk)
            return unless chunk

            # RubyLLM chunks are typically Message objects or similar
            @model ||= get_property_value(chunk, :model_id) || get_property_value(chunk, :model)
            @response_id ||= get_property_value(chunk, :id)

            # Capture content from chunk
            content = get_property_value(chunk, :content)
            @content_buffer << extract_content_text(content) if content && @capture_content

            # Capture tool calls if present
            tool_calls = get_property_value(chunk, :tool_calls)
            process_tool_calls(tool_calls) if tool_calls.is_a?(Hash)

            # Capture usage if available
            input_tokens = get_property_value(chunk, :input_tokens)
            output_tokens = get_property_value(chunk, :output_tokens)
            @input_tokens = input_tokens if input_tokens
            @output_tokens = output_tokens if output_tokens
          end

          def process_tool_calls(tool_calls)
            tool_calls.each do |id, tool_call|
              @tool_call_buffers[id] ||= { name: nil, arguments: [] }

              name = get_property_value(tool_call, :name)
              @tool_call_buffers[id][:name] ||= name

              arguments = get_property_value(tool_call, :arguments)
              @tool_call_buffers[id][:arguments] << arguments.to_s if arguments
            end
          end

          def finalize(response = nil)
            return unless @span.recording?

            # Extract final data from response if available
            if response
              @model ||= get_property_value(response, :model_id) || get_property_value(response, :model)
              @response_id ||= get_property_value(response, :id)
              @input_tokens ||= get_property_value(response, :input_tokens) || 0
              @output_tokens ||= get_property_value(response, :output_tokens) || 0

              # Check for tool calls in final response
              if response.respond_to?(:tool_call?) && response.tool_call?
                @finish_reason = 'tool_use'
              else
                @finish_reason = 'stop'
              end
            end

            attributes = {
              'gen_ai.response.model' => @model,
              'gen_ai.response.id' => @response_id,
              'gen_ai.usage.input_tokens' => @input_tokens.positive? ? @input_tokens : nil,
              'gen_ai.usage.output_tokens' => @output_tokens.positive? ? @output_tokens : nil,
              'gen_ai.response.finish_reasons' => @finish_reason ? [@finish_reason] : nil
            }.compact
            @span.add_attributes(attributes)

            # Log content if capture enabled
            return unless @capture_content

            if @content_buffer.any?
              event = {
                event_name: 'gen_ai.assistant.message',
                attributes: { 'gen_ai.provider.name' => @provider_name },
                body: { content: @content_buffer.join, role: 'assistant' }
              }
              log_structured_event(event)
            end

            return unless @tool_call_buffers.any?

            tool_calls = @tool_call_buffers.map do |id, buffer|
              {
                id: id.to_s,
                name: buffer[:name],
                arguments: buffer[:arguments].join
              }
            end

            event = {
              event_name: 'gen_ai.assistant.message',
              attributes: { 'gen_ai.provider.name' => @provider_name },
              body: { tool_calls: tool_calls, role: 'assistant' }
            }
            log_structured_event(event)
          end

          def handle_error(error)
            @span.set_attribute('error.type', error.class.name)
            @span.record_exception(error)
            @span.status = OpenTelemetry::Trace::Status.error(error.message)
          end

          def finish_span
            @span.finish
          end
        end
      end
    end
  end
end
