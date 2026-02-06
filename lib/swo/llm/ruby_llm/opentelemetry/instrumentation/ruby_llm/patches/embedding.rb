# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require_relative 'utils'

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        # Embedding Patch - instruments RubyLLM::Embedding.embed class method
        module Embedding
          include Utils

          def embed(text, model: nil, provider: nil, assume_model_exists: false, context: nil, dimensions: nil)
            return super unless config[:allowed_operation].include?('embeddings')

            resolved_config = context&.config || ::RubyLLM.config
            resolved_model = model || resolved_config.default_embedding_model

            span_name = "embeddings #{resolved_model}"

            attributes = {
              'gen_ai.operation.name' => 'embeddings',
              'gen_ai.provider.name' => 'ruby_llm',
              'gen_ai.request.model' => resolved_model.to_s,
              'gen_ai.output.type' => 'embedding'
            }

            if dimensions
              attributes['gen_ai.request.dimensions'] = dimensions
            end

            tracer.in_span(span_name, attributes: attributes.compact, kind: :client) do |span|
              # Log input if capture_content enabled
              if config[:capture_content]
                input_text = text.is_a?(Array) ? text.join(', ') : text.to_s
                event = {
                  event_name: 'gen_ai.user.message',
                  attributes: { 'gen_ai.provider.name' => 'ruby_llm' },
                  body: { content: input_text }
                }
                log_structured_event(event)
              end

              result = super

              handle_response(span, result)

              result
            rescue StandardError => e
              handle_span_exception(span, e)
              raise
            end
          end

          private

          def tracer
            RubyLLM::Instrumentation.instance.tracer
          end

          def config
            RubyLLM::Instrumentation.instance.config
          end

          def handle_response(span, result)
            return unless span.recording? && result

            # Extract model from result
            model = get_property_value(result, :model)
            span.set_attribute('gen_ai.response.model', model) if model

            # Extract token usage
            input_tokens = get_property_value(result, :input_tokens)
            span.set_attribute('gen_ai.usage.input_tokens', input_tokens) if input_tokens

            # Extract embedding dimensions
            vectors = get_property_value(result, :vectors)
            if vectors.is_a?(Array) && vectors.first.is_a?(Array)
              span.set_attribute('gen_ai.embeddings.dimension.count', vectors.first.size)
            elsif vectors.is_a?(Array)
              span.set_attribute('gen_ai.embeddings.dimension.count', vectors.size)
            end
          end

          def handle_span_exception(span, error)
            span.set_attribute('error.type', error.class.name)
            span.record_exception(error)
            span.status = OpenTelemetry::Trace::Status.error(error.message)
            span.finish
          end
        end
      end
    end
  end
end
