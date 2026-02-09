# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'

require_relative '../../../../lib/swo/llm/claude/opentelemetry/instrumentation'

describe OpenTelemetry::Instrumentation::Claude do
  let(:instrumentation) { OpenTelemetry::Instrumentation::Claude::Instrumentation.instance }

  it 'has #name' do
    _(instrumentation.name).must_equal 'OpenTelemetry::Instrumentation::Claude'
  end

  it 'has #version' do
    _(instrumentation.version).wont_be_nil
    _(instrumentation.version).wont_be_empty
  end

  describe '#install' do
    it 'accepts argument' do
      # Skip if Anthropic gem is not available
      skip 'Anthropic gem not available' unless defined?(::Anthropic)

      _(instrumentation.install({})).must_equal(true)
      instrumentation.instance_variable_set(:@installed, false)
    end
  end

  describe 'configuration options' do
    it 'has capture_content option defaulting to false' do
      _(instrumentation.config[:capture_content]).must_equal false
    end

    it 'has allowed_operation option with default values' do
      _(instrumentation.config[:allowed_operation]).must_include 'messages'
      _(instrumentation.config[:allowed_operation]).must_include 'completions'
    end
  end
end
