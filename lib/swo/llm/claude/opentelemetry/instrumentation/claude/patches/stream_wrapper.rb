# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require_relative 'utils'

module OpenTelemetry
  module Instrumentation
    module Claude
      module Patches
        # Stream wrapper for Anthropic Claude message streaming
        # Wraps Anthropic::Internal::Stream or Anthropic::Streaming::MessageStream
        class StreamWrapper
          include Enumerable
          include Utils

          attr_reader :stream, :span, :capture_content

          def initialize(stream, span, capture_content)
            @stream = stream
            @span = span
            @capture_content = capture_content
            @response_id = nil
            @response_model = nil
            @stop_reason = nil
            @input_tokens = 0
            @output_tokens = 0
            @content_buffers = []
            @span_started = true
          end

          def each(&)
            @stream.each do |event|
              process_event(event)
              yield(event) if block_given?
            end
          rescue StandardError => e
            handle_error(e)
            raise
          ensure
            cleanup
          end

          private

          # Process different event types from Anthropic streaming
          # Event types: message_start, content_block_start, content_block_delta,
          #              content_block_stop, message_delta, message_stop
          def process_event(event)
            event_type = get_event_type(event)

            case event_type
            when 'message_start'
              process_message_start(event)
            when 'content_block_start'
              process_content_block_start(event)
            when 'content_block_delta'
              process_content_block_delta(event)
            when 'content_block_stop'
              process_content_block_stop(event)
            when 'message_delta'
              process_message_delta(event)
            when 'message_stop'
              process_message_stop(event)
            end
          end

          def get_event_type(event)
            if event.respond_to?(:type)
              event.type.to_s
            elsif event.is_a?(Hash)
              (event[:type] || event['type']).to_s
            else
              ''
            end
          end

          def process_message_start(event)
            message = get_property_value(event, :message)
            return unless message

            @response_id ||= get_property_value(message, :id)
            @response_model ||= get_property_value(message, :model)

            usage = get_property_value(message, :usage)
            return unless usage

            @input_tokens = get_property_value(usage, :input_tokens) || 0
          end

          def process_content_block_start(event)
            index = get_property_value(event, :index) || @content_buffers.size
            content_block = get_property_value(event, :content_block)

            @content_buffers << ContentBlockBuffer.new(index) while @content_buffers.size <= index

            buffer = @content_buffers[index]
            return unless content_block

            buffer.type = get_property_value(content_block, :type)&.to_s
            buffer.id = get_property_value(content_block, :id)
            buffer.name = get_property_value(content_block, :name)
          end

          def process_content_block_delta(event)
            index = get_property_value(event, :index) || 0
            delta = get_property_value(event, :delta)
            return unless delta

            @content_buffers << ContentBlockBuffer.new(@content_buffers.size) while @content_buffers.size <= index

            buffer = @content_buffers[index]
            delta_type = get_property_value(delta, :type)&.to_s

            case delta_type
            when 'text_delta'
              text = get_property_value(delta, :text)
              buffer.append_text(text) if text
            when 'input_json_delta'
              partial_json = get_property_value(delta, :partial_json)
              buffer.append_input(partial_json) if partial_json
            end
          end

          def process_content_block_stop(event)
            # Content block is complete, nothing special needed
            # The buffer already has accumulated content
          end

          def process_message_delta(event)
            delta = get_property_value(event, :delta)
            if delta
              @stop_reason ||= get_property_value(delta, :stop_reason)&.to_s
            end

            usage = get_property_value(event, :usage)
            return unless usage

            @output_tokens = get_property_value(usage, :output_tokens) || 0
          end

          def process_message_stop(_event)
            # Message is complete
          end

          def cleanup
            return unless @span_started

            if @span.recording?
              attributes = {
                'gen_ai.response.model' => @response_model,
                'gen_ai.response.id' => @response_id,
                'gen_ai.usage.input_tokens' => @input_tokens.positive? ? @input_tokens : nil,
                'gen_ai.usage.output_tokens' => @output_tokens.positive? ? @output_tokens : nil,
                'gen_ai.response.finish_reasons' => @stop_reason ? [@stop_reason] : nil
              }.compact
              @span.add_attributes(attributes)
            end

            # Emit structured log events for content blocks
            if @capture_content
              @content_buffers.each do |buffer|
                event = buffer.to_log_event
                log_structured_event(event)
              end
            end
          ensure
            @span.finish
            @span_started = false
          end

          def handle_error(error)
            @span.set_attribute('error.type', error.class.name)
            @span.record_exception(error)
            @span.status = OpenTelemetry::Trace::Status.error(error.message)
          end

          # Buffer for accumulating streaming content block data
          class ContentBlockBuffer
            attr_accessor :type, :id, :name
            attr_reader :index, :text_content, :input_content

            def initialize(index)
              @index = index
              @type = nil
              @id = nil
              @name = nil
              @text_content = []
              @input_content = []
            end

            def append_text(text)
              @text_content << text if text
            end

            def append_input(input)
              @input_content << input if input
            end

            def to_log_event
              body = {
                index: @index,
                type: @type || 'text'
              }

              case @type
              when 'text'
                body[:text] = @text_content.join if @text_content.any?
              when 'tool_use'
                body[:id] = @id if @id
                body[:name] = @name if @name
                body[:input] = @input_content.join if @input_content.any?
              end

              {
                event_name: 'gen_ai.content_block',
                attributes: {
                  'gen_ai.provider.name' => 'anthropic'
                },
                body: body
              }
            end
          end
        end
      end
    end
  end
end
