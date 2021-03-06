module React
  class StateWrapper < BasicObject
    def initialize(native, from)
      @state_hash = Hash.new(`#{native}.state`)
      @from = from
    end

    def [](state)
      @state_hash[state]
    end

    def []=(state, new_value)
      @state_hash[state] = new_value
    end

    def method_missing(method, *args)
      if match = method.match(/^(.+)\!$/)
        if args.count > 0
          current_value = State.get_state(@from, match[1])
          State.set_state(@from, $1, args[0])
          current_value
        else
          current_state = State.get_state(@from, match[1])
          State.set_state(@from, $1, current_state)
          Observable.new(current_state) do |update|
            State.set_state(@from, $1, update)
          end
        end
      else
        State.get_state(@from, method)
      end
    end
  end

  class State
    class << self
      attr_reader :current_observer

      def initialize_states(object, initial_values)
        # initialize objects' name/value pairs
        states[object].merge!(initial_values || {})
      end

      def get_state(object, name, current_observer = @current_observer)
        # get current value of name for object, remember that the current object
        # depends on this state, current observer can be overriden with last
        # param
        new_observers[current_observer][object] << name if current_observer &&
          !new_observers[current_observer][object].include?(name)
        states[object][name]
      end

      def set_state2(object, name, value)
        # set object's name state to value, tell all observers it has changed.
        # Observers must implement update_react_js_state
        object_needs_notification = object.respond_to? :update_react_js_state
        observers_by_name[object][name].dup.each do |observer|
          observer.update_react_js_state(object, name, value)
          object_needs_notification = false if object == observer
        end
        object.update_react_js_state(nil, name, value) if object_needs_notification
      end

      def set_state(object, name, value, delay=nil)
        states[object][name] = value
        if delay
          @delayed_updates ||= []
          @delayed_updates << [object, name, value]
          @delayed_updater ||= after(0.001) do
            delayed_updates = @delayed_updates
            @delayed_updates = []
            @delayed_updater = nil
            delayed_updates.each do |object, name, value|
              set_state2(object, name, value)
            end
          end
        else
          set_state2(object, name, value)
        end
        value
      end

      def will_be_observing?(object, name, current_observer)
        current_observer && new_observers[current_observer][object].include?(name)
      end

      def is_observing?(object, name, current_observer)
        current_observer && observers_by_name[object][name].include?(current_observer)
      end

      # should be called after the last after_render callback, currently called
      # after components render method
      def update_states_to_observe(current_observer = @current_observer)
        raise "update_states_to_observer called outside of watch block" unless current_observer
        current_observers[current_observer].each do |object, names|
          names.each do |name|
            observers_by_name[object][name].delete(current_observer)
          end
        end
        observers = current_observers[current_observer] = new_observers[current_observer]
        new_observers.delete(current_observer)
        observers.each do |object, names|
          names.each do |name|
            observers_by_name[object][name] << current_observer
          end
        end
      end

      def remove # call after component is unmounted
        raise "remove called outside of watch block" unless @current_observer
        current_observers[@current_observer].each do |object, names|
          names.each do |name|
            observers_by_name[object][name].delete(@current_observer)
          end
        end
        current_observers.delete(@current_observer)
      end

      # wrap all execution that may set or get states in a block so we know
      # which observer is executing
      def set_state_context_to(observer)
        if `typeof window.reactive_ruby_timing !== 'undefined'`
          @nesting_level = (@nesting_level || 0) + 1
          start_time = Time.now.to_f
          observer_name = (observer.class.respond_to?(:name) ? observer.class.name : observer.to_s) rescue "object:#{observer.object_id}"
        end
        saved_current_observer = @current_observer
        @current_observer = observer
        return_value = yield
        return_value
      ensure
        @current_observer = saved_current_observer
        if `typeof window.reactive_ruby_timing !== 'undefined'`
          @nesting_level = [0, @nesting_level - 1].max
        end
        return_value
      end

      def states
        @states ||= Hash.new { |h, k| h[k] = {} }
      end

      [:new_observers, :current_observers, :observers_by_name].each do |method_name|
        define_method(method_name) do
          instance_variable_get("@#{method_name}") or
          instance_variable_set("@#{method_name}", Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = [] } })
        end
      end
    end
  end
end
