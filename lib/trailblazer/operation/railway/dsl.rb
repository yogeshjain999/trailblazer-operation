module Trailblazer
  module Operation::Railway
    # WARNING: The API here is still in a state of flux since we want to provide a simple yet flexible solution.
    # This is code executed at compile-time and can be slow.
    # @note `__sequence__` is a private concept, your custom DSL code should not rely on it.


    # DRAFT
    #  direction: "(output) signal"

    # document ## Outputs
    #   task/acti has outputs, role_to_target says which task output goes to what next task in the composing acti.

    module DSL
      def pass(proc, options={}); add_step!(:pass, proc, options, default_task_outputs: default_task_outputs(options) ); end
      def fail(proc, options={}); add_step!(:fail, proc, options, default_task_outputs: default_task_outputs(options) ); end
      def step(proc, options={}); add_step!(:step, proc, options, default_task_outputs: default_task_outputs(options) ); end
      alias_method :success, :pass
      alias_method :failure, :fail

      private

      def role_to_target_for_pass(task, options)
        {
          :success => "End.success",
          :failure => "End.success"
        }
      end

      def role_to_target_for_fail(task, options)
        {
          :success => "End.failure",
          :failure => "End.failure"
        }
      end

      def role_to_target_for_step(task, options)
        {
          :success => "End.success",
          :failure => "End.failure"
        }
      end

      def insert_before_for_pass(task, options)
        "End.success"
      end

      def insert_before_for_fail(task, options)
        "End.failure"
      end

      def insert_before_for_step(task, options)
        "End.success"
      end

      # An unaware step task usually has two outputs, one end event for success and one for failure.
      # Note that macros have to define their outputs when inserted and don't need a default config.
      def default_task_outputs(options)
        { Circuit::Right => { role: :success }, Circuit::Left => { role: :failure }}
      end

      # insert_before: "End.success",
      # outputs:       { Circuit::Right => { role: :success }, Circuit::Left => { role: :failure } }, # any outputs and their polarization, generic.
      # mappings:      { success: "End.success", failure: "End.myend" } # where do my task's outputs go?
      # always adds task on a track edge.
      # @return ElementWiring
      def task(task, insert_before:raise, outputs:{}, connect_to:{}, task_meta_data:raise)
        wirings = []

        wirings << [:insert_before!, insert_before, incoming: ->(edge) { edge[:type] == :railway }, node: [ task, task_meta_data ] ]

        # FIXME: don't mark pass_fast with :railway
        wirings += Wirings.task_outputs_to(outputs, connect_to, task_meta_data[:id], type: :railway) # connect! for task outputs

        ElementWiring.new(wirings, task_meta_data) # embraces all alterations for one "step".
      end

      # |-- compile initial act from alterations
      # |-- add step alterations
      def add_step!(type, proc, user_options, task_builder:TaskBuilder, default_task_outputs:raise)
        heritage.record(type, proc, user_options)

        # build the task.
        #   runner_options #=>{:alteration=>#<Proc:0x00000001dcbb20@test/task_wrap_test.rb:15 (lambda)>}
        task, options_from_macro, runner_options, task_outputs = if proc.is_a?(Array)
          build_task_for_macro( task_builder: task_builder, step: proc, task_outputs: default_task_outputs )
        else
          build_task_for_step( task_builder: task_builder, step: proc, task_outputs: default_task_outputs )
        end

        # normalize options generically, such as :name, :override, etc.
        options, id = process_options( options_from_macro, user_options, name: proc )


        task_meta_data  = { id: id, created_by: type } # this is where we can add meta-data like "is a subprocess", "boundary events", etc.

        role_to_target    = send("role_to_target_for_#{type}",  task, options) #=> { :success => [ "End.success" ] }
        insert_before  = send("insert_before_for_#{type}", task, options) #=> "End.success"

        wirings         = task(task, insert_before: insert_before, outputs: task_outputs, connect_to: role_to_target, task_meta_data: task_meta_data)

        self["__activity__"] = recompile_activity_for_wirings!(wirings, options) # options is :before,:after etc for Seq.insert!

        {
          activity:  self["__activity__"],

          # also return all computed data for this step:
          task:           task,
          options:        options,
          runner_options: runner_options,
          task_outputs:   task_outputs, # we don't need them outside.
        }
      end

      ElementWiring = Struct.new(:instructions, :data)

      # @private
      def recompile_activity_for_wirings!(wirings, options)
        sequence = self["__sequence__"]

        # Insert {Step} into {Sequence} while respecting :append, :replace, before, etc.
        sequence.insert!(wirings, options) # The sequence is now an up-to-date representation of our operation's steps.

        # This op's graph are the initial wirings (different ends, etc) + the steps we added.
        activity = recompile_activity( self["__wirings__"] + sequence.to_a )
      end

      # @private
      # 1. Processes the step API's options (such as `:override` of `:before`).
      # 2. Uses `Sequence.alter!` to maintain a linear array representation of the circuit's tasks.
      #    This is then transformed into a circuit/Activity. (We could save this step with some graph magic)
      # 3. Returns a new Activity instance.
      #
      # This is called per "step"/task insertion.
      def recompile_activity(wirings)
        Trailblazer::Activity.from_wirings(wirings)
      end

      private

      def build_task_for_step(step:raise, task_outputs:raise, task_builder: Operation::Railway::TaskBuilder)
        task = task_builder.(step, Circuit::Right, Circuit::Left)

        [ task, {}, {}, task_outputs ]
      end

      def build_task_for_macro(step:raise, task_outputs:raise, **o)
        task, options_from_macro, runner_options, _task_outputs = *step

        # defaultize, DISCUSS whether or not macros should do this.
        _task_outputs  = task_outputs if _task_outputs.nil? # FIXME: macros must always return their endings.
        runner_options = {} if runner_options.nil?

        [ task, options_from_macro, runner_options, _task_outputs ]
      end

      # Normalizes :override and :name options.
      def process_options(macro_options, user_options, default_options)
        options = macro_options.merge(user_options)
        options = default_options.merge(options)
        options = options.merge(replace: options[:name]) if options[:override] # :override
        options[:id] = options[:name]

        return options, options[:id]
      end

      # @private
      class Wirings # TODO: move to acti.
      #- connect! statements for outputs.
      # @param known_targets Hash {  }
        def self.task_outputs_to(task_outputs, known_targets, id, edge_options)
          # task_outputs is what the task has
          # known_targets are ends this activity/operation provides.
          task_outputs.collect do |signal, role:raise|
            target = known_targets[ role ]
            # TODO: add more options to edge like role: :success or role: pass_fast.

            [:connect!, source: id, edge: [signal, edge_options], target: target ] # e.g. "Left --> End.failure"
          end
        end
      end # Wiring
    end # DSL
  end
end
