# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'logger'

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        # Utils module provides helper methods for extracting and processing
        # data from RubyLLM requests and responses
        module Utils
          def get_property_value(obj, property_name)
            if obj.is_a?(Hash)
              obj[property_name] || obj[property_name.to_s] || obj[property_name.to_sym]
            else
              obj.respond_to?(property_name) ? obj.public_send(property_name) : nil
            end
          end

          def extract_tool_calls(message, capture_content)
            tool_calls = get_property_value(message, :tool_calls)
            return nil unless tool_calls.is_a?(Hash) && tool_calls.any?

            calls = []
            tool_calls.each do |id, tool_call|
              tool_call_dict = { id: id.to_s }

              name = get_property_value(tool_call, :name)
              tool_call_dict[:name] = name.to_s if name

              if capture_content
                arguments = get_property_value(tool_call, :arguments)
                if arguments
                  tool_call_dict[:arguments] = arguments.is_a?(String) ? arguments : arguments.to_json
                end
              end

              calls << tool_call_dict
            end
            calls.any? ? calls : nil
          end

          def message_to_log_event(message, capture_content: true)
            role = get_property_value(message, :role)&.to_s

            body = {}

            content = get_property_value(message, :content)
            if content && capture_content
              content_text = extract_content_text(content)
              body[:content] = content_text if content_text && !content_text.empty?
            end

            if role == 'assistant'
              tool_calls = extract_tool_calls(message, capture_content)
              body[:tool_calls] = tool_calls if tool_calls
            elsif role == 'tool'
              tool_call_id = get_property_value(message, :tool_call_id)
              body[:tool_call_id] = tool_call_id if tool_call_id
            end

            {
              event_name: "gen_ai.#{role}.message",
              attributes: {
                'gen_ai.provider.name' => 'ruby_llm'
              },
              body: body.empty? ? nil : body
            }
          end

          def extract_content_text(content)
            case content
            when String
              content
            when ::RubyLLM::Content
              # RubyLLM::Content has text and attachments
              get_property_value(content, :text)&.to_s
            when Hash
              content[:text] || content['text']
            else
              content.to_s
            end
          rescue StandardError
            content.to_s
          end

          def response_to_log_event(response, capture_content: true)
            role = get_property_value(response, :role)&.to_s || 'assistant'

            body = {
              role: role
            }

            content = get_property_value(response, :content)
            if content && capture_content
              content_text = extract_content_text(content)
              body[:content] = content_text if content_text && !content_text.empty?
            end

            tool_calls = extract_tool_calls(response, capture_content)
            body[:tool_calls] = tool_calls if tool_calls

            {
              event_name: 'gen_ai.assistant.message',
              attributes: {
                'gen_ai.provider.name' => 'ruby_llm'
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

          def extract_provider_name(provider)
            return 'unknown' unless provider

            if provider.respond_to?(:slug)
              provider.slug.to_s
            elsif provider.respond_to?(:name)
              provider.name.to_s.downcase
            else
              provider.class.name.to_s.split('::').last.downcase
            end
          rescue StandardError
            'unknown'
          end
        end
      end
    end
  end
end
