# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'logger'

module OpenTelemetry
  module Instrumentation
    module Claude
      module Patches
        # Utils module provides helper methods for extracting and processing
        # data from Anthropic Claude API requests and responses
        module Utils
          def get_property_value(obj, property_name)
            if obj.is_a?(Hash)
              obj[property_name] || obj[property_name.to_s] || obj[property_name.to_sym]
            else
              obj.respond_to?(property_name) ? obj.public_send(property_name) : nil
            end
          end

          def extract_tool_use(item, capture_content)
            tool_use_blocks = []

            content = get_property_value(item, :content)
            return nil unless content.is_a?(Array)

            content.each do |block|
              block_type = get_property_value(block, :type)
              next unless block_type.to_s == 'tool_use'

              tool_use_dict = {}

              tool_id = get_property_value(block, :id)
              tool_use_dict[:id] = tool_id if tool_id

              tool_use_dict[:type] = 'tool_use'

              tool_name = get_property_value(block, :name)
              tool_use_dict[:name] = tool_name if tool_name

              if capture_content
                tool_input = get_property_value(block, :input)
                if tool_input
                  tool_use_dict[:input] = tool_input.is_a?(String) ? tool_input : tool_input.to_json
                end
              end

              tool_use_blocks << tool_use_dict
            end

            tool_use_blocks.any? ? tool_use_blocks : nil
          end

          def message_to_log_event(message, capture_content: true)
            role = get_property_value(message, :role)&.to_s

            body = {}

            # Handle content - can be string or array of content blocks
            content = get_property_value(message, :content)
            if content
              if content.is_a?(String)
                body[:content] = content if capture_content
              elsif content.is_a?(Array)
                text_parts = []
                content.each do |block|
                  block_type = get_property_value(block, :type)
                  if block_type.to_s == 'text'
                    text = get_property_value(block, :text)
                    text_parts << text if text
                  end
                end
                body[:content] = text_parts.join if capture_content && text_parts.any?
              end
            end

            if role == 'assistant'
              tool_use = extract_tool_use(message, capture_content)
              body[:tool_use] = tool_use if tool_use
            elsif role == 'user'
              # Check for tool_result in user messages
              if content.is_a?(Array)
                content.each do |block|
                  block_type = get_property_value(block, :type)
                  if block_type.to_s == 'tool_result'
                    tool_use_id = get_property_value(block, :tool_use_id)
                    body[:tool_use_id] = tool_use_id if tool_use_id
                  end
                end
              end
            end

            {
              event_name: "gen_ai.#{role}.message",
              attributes: {
                'gen_ai.provider.name' => 'anthropic'
              },
              body: body.empty? ? nil : body
            }
          end

          def content_block_to_log_event(content_block, index, capture_content: true)
            block_type = get_property_value(content_block, :type)&.to_s

            body = {
              index: index,
              type: block_type
            }

            case block_type
            when 'text'
              text = get_property_value(content_block, :text)
              body[:text] = text if capture_content && text
            when 'tool_use'
              body[:id] = get_property_value(content_block, :id)
              body[:name] = get_property_value(content_block, :name)
              if capture_content
                input = get_property_value(content_block, :input)
                body[:input] = input.is_a?(String) ? input : input.to_json if input
              end
            end

            {
              event_name: 'gen_ai.content_block',
              attributes: {
                'gen_ai.provider.name' => 'anthropic'
              },
              body: body
            }
          end

          def response_to_log_event(response, capture_content: true)
            stop_reason = get_property_value(response, :stop_reason)&.to_s

            body = {
              stop_reason: stop_reason || 'error',
              role: 'assistant'
            }

            content = get_property_value(response, :content)
            if content.is_a?(Array) && capture_content
              text_parts = []
              tool_uses = []

              content.each_with_index do |block, _index|
                block_type = get_property_value(block, :type)
                case block_type.to_s
                when 'text'
                  text = get_property_value(block, :text)
                  text_parts << text if text
                when 'tool_use'
                  tool_use = {
                    id: get_property_value(block, :id),
                    name: get_property_value(block, :name),
                    input: get_property_value(block, :input)
                  }.compact
                  tool_uses << tool_use
                end
              end

              body[:content] = text_parts.join if text_parts.any?
              body[:tool_use] = tool_uses if tool_uses.any?
            end

            {
              event_name: 'gen_ai.assistant.message',
              attributes: {
                'gen_ai.provider.name' => 'anthropic'
              },
              body: body
            }
          end

          def log_structured_event(event)
            log_message = {
              event: event[:event_name],
              attributes: event[:attributes],
              body: event[:body]
            }.compact

            OpenTelemetry.logger.info(log_message.to_json)
          end
        end
      end
    end
  end
end
