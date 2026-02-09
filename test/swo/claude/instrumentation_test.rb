# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'

require_relative '../../../lib/swo/llm/claude/opentelemetry/instrumentation'

# Mock Anthropic module for testing install()
module Anthropic
  VERSION = '1.0.0'

  class Client
    def request(req)
      {}
    end
  end
end

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
      _(instrumentation.install({})).must_equal(true)
      instrumentation.instance_variable_set(:@installed, false)
    end
  end

  describe 'configuration options' do
    before do
      # Reset the instrumentation singleton's config to defaults
      # This ensures tests don't depend on execution order
      instrumentation.instance_variable_set(:@config, nil)
      instrumentation.instance_variable_set(:@installed, false)
    end

    it 'has capture_content option defaulting to false' do
      # Install to populate config with defaults
      instrumentation.install({})
      _(instrumentation.config[:capture_content]).must_equal false
    end

    it 'has allowed_operation option with default values' do
      # Install to populate config with defaults
      instrumentation.install({})
      _(instrumentation.config[:allowed_operation]).must_include 'messages'
      _(instrumentation.config[:allowed_operation]).must_include 'completions'
    end
  end
end
