require "statesman/version"
require "statesman/exceptions"
require "statesman/guard"
require "statesman/callback"
require "statesman/transition"

module Statesman
  # The main module, that should be `extend`ed in to state machine classes.
  module Machine
    def self.included(base)
      base.extend(ClassMethods)
      base.send(:attr_reader, :object)
    end

    module ClassMethods
      attr_reader :initial_state

      def states
        @states ||= []
      end

      def state(name, initial: false)
        name = name.to_s
        if initial
          validate_initial_state(name)
          @initial_state = name
        end
        states << name
      end

      def successors
        @successors ||= {}
      end

      def before_callbacks
        @before_callbacks ||= []
      end

      def after_callbacks
        @after_callbacks ||= []
      end

      def guards
        @guards ||= []
      end

      def transition(from: nil, to: nil)
        from = to_s_or_nil(from)
        to   = to_s_or_nil(to)

        successors[from] ||= []
        to = Array(to)

        ([from] + to).each { |state| validate_state(state) }

        successors[from] += to
      end

      def before_transition(from: nil, to: nil, &block)
        from = to_s_or_nil(from)
        to   = to_s_or_nil(to)

        validate_callback_condition(from: from, to: to)
        before_callbacks << Callback.new(from: from, to: to, callback: block)
      end

      def after_transition(from: nil, to: nil, &block)
        from = to_s_or_nil(from)
        to   = to_s_or_nil(to)

        validate_callback_condition(from: from, to: to)
        after_callbacks << Callback.new(from: from, to: to, callback: block)
      end

      def guard_transition(from: nil, to: nil, &block)
        from = to_s_or_nil(from)
        to   = to_s_or_nil(to)

        validate_callback_condition(from: from, to: to)
        guards << Guard.new(from: from, to: to, callback: block)
      end

      def validate_callback_condition(from: nil, to: nil)
        from = to_s_or_nil(from)
        to   = to_s_or_nil(to)

        [from, to].compact.each { |state| validate_state(state) }
        return if from.nil? && to.nil?

        validate_not_from_terminal_state(from)
        validate_not_to_initial_state(to)

        return if from.nil? || to.nil?

        validate_from_and_to_state(from, to)
      end

      # Check that the 'from' state is not terminal
      def validate_not_from_terminal_state(from)
        unless from.nil? || successors.keys.include?(from)
          raise InvalidTransitionError,
                "Cannont transition away from terminal state '#{from}'"
        end
      end

      # Check that the 'to' state is not initial
      def validate_not_to_initial_state(to)
        unless to.nil? || successors.values.flatten.include?(to)
          raise InvalidTransitionError,
                "Cannont transition to initial state '#{to}'"
        end
      end

      # Check that the transition is valid when 'from' and 'to' are given
      def validate_from_and_to_state(from, to)
        unless successors.fetch(from, []).include?(to)
          raise InvalidTransitionError,
                "Cannot transition from '#{from}' to '#{to}'"
        end
      end

      private

      def validate_state(state)
        unless states.include?(state.to_s)
          raise InvalidStateError, "Invalid state '#{state}'"
        end
      end

      def validate_initial_state(state)
        unless initial_state.nil?
          raise InvalidStateError, "Cannot set initial state to '#{state}', " +
                                   "already defined as #{initial_state}."
        end
      end

      def to_s_or_nil(input)
        input.nil? ? input : input.to_s
      end
    end

    def initialize(object, transition_class: Statesman::Transition)
      @object = object
      @storage_adapter = Statesman.storage_adapter.new(transition_class,
                                                       object)
    end

    def current_state
      last_action = @storage_adapter.last
      last_action ? last_action.to_state : self.class.initial_state
    end

    def can_transition_to?(new_state)
      validate_transition(from: current_state, to: new_state)
      true
    rescue InvalidTransitionError, GuardFailedError
      false
    end

    def history
      @storage_adapter.history
    end

    def transition_to!(new_state, metadata = nil)
      initial_state = current_state
      new_state = new_state.to_s

      validate_transition(from: initial_state, to: new_state)

      before_callbacks_for(from: initial_state, to: new_state).each do |cb|
        cb.call(@object)
      end

      @storage_adapter.create(new_state, metadata)

      after_callbacks_for(from: initial_state, to: new_state).each do |cb|
        cb.call(@object)
      end

      current_state
    end

    def transition_to(new_state, metadata = nil)
      self.transition_to!(new_state, metadata)
    rescue
      false
    end

    def guards_for(from: nil, to: nil)
      select_callbacks_for(self.class.guards, from: from, to: to)
    end

    def before_callbacks_for(from: nil, to: nil)
      select_callbacks_for(self.class.before_callbacks, from: from, to: to)
    end

    def after_callbacks_for(from: nil, to: nil)
      select_callbacks_for(self.class.after_callbacks, from: from, to: to)
    end

    private

    def select_callbacks_for(callbacks, from: nil, to: nil)
      from = to_s_or_nil(from)
      to   = to_s_or_nil(to)
      callbacks.select { |callback| callback.applies_to?(from: from, to: to) }
    end

    def validate_transition(from: nil, to: nil)
      from = to_s_or_nil(from)
      to   = to_s_or_nil(to)

      # Call all guards, they raise exceptions if they fail
      guards_for(from: from, to: to).each { |guard| guard.call(@object) }

      successors = self.class.successors[from] || []
      unless successors.include?(to)
        raise InvalidTransitionError,
              "Cannot transition from '#{from}' to '#{to}'"
      end
    end

    def to_s_or_nil(input)
      input.nil? ? input : input.to_s
    end
  end
end
