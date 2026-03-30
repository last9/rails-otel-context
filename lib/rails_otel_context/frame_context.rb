# frozen_string_literal: true

module RailsOtelContext
  # Thread-local storage for explicitly pushed call-frame context.
  #
  # The default code.namespace / code.function attributes are extracted by
  # walking the Ruby call stack on every span start. That works, but costs
  # O(stack depth) object allocations per span. FrameContext eliminates the
  # walk by letting call sites push their class+method once at entry:
  #
  #   RailsOtelContext::FrameContext.with_frame(class_name: 'OrdersController',
  #                                             method_name: 'create') do
  #     # every span created inside here reads the pushed frame — no stack walk
  #   end
  #
  # The Railtie automatically installs an around_action that pushes the
  # controller frame for all controller actions. For jobs, service objects, or
  # any other code that creates spans, use +with_frame+ directly or include
  # +RailsOtelContext::Frameable+.
  #
  # The pushed frame is a fallback for the span processor: the stack walk
  # still runs when no frame is pushed, so existing behavior is preserved.
  module FrameContext
    FRAME_KEY = :_rails_otel_ctx_frame
    private_constant :FRAME_KEY

    class << self
      # Pushes +class_name+/+method_name+ for the duration of the block,
      # restoring whatever was pushed before (supports nesting).
      def with_frame(class_name:, method_name:)
        prev = Thread.current[FRAME_KEY]
        Thread.current[FRAME_KEY] = { class_name: class_name, method_name: method_name }.freeze
        yield
      ensure
        Thread.current[FRAME_KEY] = prev
      end

      # Manual push without a block. Caller must call +pop+ in an ensure.
      def push(class_name:, method_name:)
        Thread.current[FRAME_KEY] = { class_name: class_name, method_name: method_name }.freeze
      end

      # Clears the pushed frame. Pair with +push+ in an ensure block.
      def pop
        Thread.current[FRAME_KEY] = nil
      end

      # Returns the currently pushed frame hash, or nil.
      def current
        Thread.current[FRAME_KEY]
      end

      alias clear! pop
    end
  end

  # Include in any class to get a +with_otel_frame+ convenience wrapper that
  # pushes self.class.name + the calling method name automatically.
  #
  #   class InvoiceService
  #     include RailsOtelContext::Frameable
  #
  #     def call
  #       with_otel_frame { do_work }
  #     end
  #   end
  module Frameable
    def with_otel_frame(method_name = nil, &)
      name = method_name || caller_locations(1, 1).first&.label || '<unknown>'
      FrameContext.with_frame(class_name: self.class.name, method_name: name, &)
    end
  end
end
