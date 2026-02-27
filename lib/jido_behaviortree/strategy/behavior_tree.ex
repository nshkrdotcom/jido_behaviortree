defmodule Jido.Agent.Strategy.BehaviorTree do
  @moduledoc """
  Behavior tree execution strategy for Jido agents.

  This strategy allows agents to use behavior trees for decision-making.
  Each `cmd/3` call executes exactly one behavior tree tick, making execution
  bounded and predictable.

  ## Configuration

  Configure via strategy options when defining an agent:

      defmodule MyAgent do
        use Jido.Agent,
          name: "bt_agent",
          strategy: {Jido.Agent.Strategy.BehaviorTree,
            tree: my_tree(),
            blackboard: %{initial: "data"}
          }
      end

  ## Options

  - `:tree` - A `Jido.BehaviorTree.Tree.t()` (required unless `:tree_builder` provided)
  - `:tree_builder` - `{mod, fun, args}` to build tree dynamically per agent
  - `:blackboard` - Initial blackboard data map (default: `%{}`)
  - `:reset_on_completion` - Reset tree when status is `:success` or `:failure` (default: `false`)

  ## Execution Model

  1. `init/2` - Creates tree and blackboard from options, stores in `__strategy__`
  2. `cmd/3` - Injects instructions into blackboard, runs one tree tick, returns directives
  3. `snapshot/2` - Maps tree status to `Strategy.Snapshot`

  ## Status Mapping

  - Tree `:success` → Snapshot `:success`
  - Tree `:failure` → Snapshot `:failure`
  - Tree `:running` → Snapshot `:running`
  - Before first tick → Snapshot `:idle`
  """

  use Jido.Agent.Strategy

  alias Jido.Agent
  alias Jido.Agent.Directive, as: AgentDirective
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.BehaviorTree.{Blackboard, Tick, Tree}
  alias Jido.Error
  alias Jido.Instruction
  alias Jido.Observe

  @tick_action :bt_tick
  @put_action :bt_blackboard_put
  @merge_action :bt_blackboard_merge
  @halt_action :bt_halt
  @reset_action :bt_reset

  @action_specs %{
    @tick_action => %{
      schema:
        Zoi.object(%{
          instructions: Zoi.list(Zoi.any(), description: "Additional instructions to inject") |> Zoi.optional()
        }),
      doc: "Execute a single behavior tree tick",
      name: "jido.bt.tick"
    },
    @put_action => %{
      schema:
        Zoi.object(%{
          key: Zoi.any(description: "Blackboard key to set"),
          value: Zoi.any(description: "Value to store")
        }),
      doc: "Set one key/value on the behavior tree blackboard",
      name: "jido.bt.blackboard.put"
    },
    @merge_action => %{
      schema:
        Zoi.object(%{
          data: Zoi.map(description: "Map of blackboard values to merge")
        }),
      doc: "Merge map values into the behavior tree blackboard",
      name: "jido.bt.blackboard.merge"
    },
    @halt_action => %{
      schema: Zoi.object(%{}),
      doc: "Halt the behavior tree without ticking",
      name: "jido.bt.halt"
    },
    @reset_action => %{
      schema: Zoi.object(%{}),
      doc: "Reset the behavior tree to initial blackboard and idle status",
      name: "jido.bt.reset"
    }
  }

  defmodule State do
    @moduledoc """
    Internal state for the BehaviorTree strategy.

    Stored in `agent.state.__strategy__.bt`.
    """

    @schema Zoi.struct(
              __MODULE__,
              %{
                tree: Zoi.any(description: "The behavior tree"),
                blackboard: Zoi.any(description: "Shared blackboard state"),
                initial_blackboard: Zoi.any(description: "Initial blackboard snapshot"),
                status:
                  Zoi.atom(description: "Current execution status")
                  |> Zoi.default(:idle),
                tick_count:
                  Zoi.integer(description: "Number of ticks executed")
                  |> Zoi.min(0)
                  |> Zoi.default(0),
                last_result: Zoi.any(description: "Result from last tick") |> Zoi.optional(),
                error: Zoi.any(description: "Last error if any") |> Zoi.optional()
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))
    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @doc "Returns the Zoi schema for this module"
    def schema, do: @schema

    @doc "Creates a new State with the given tree and blackboard"
    @spec new(Tree.t(), Blackboard.t()) :: t()
    def new(tree, blackboard) do
      %__MODULE__{
        tree: tree,
        blackboard: blackboard,
        initial_blackboard: blackboard,
        status: :idle,
        tick_count: 0,
        last_result: nil,
        error: nil
      }
    end
  end

  @impl true
  def action_spec(action), do: Map.get(@action_specs, action)

  @impl true
  def signal_routes(_ctx) do
    [
      {"jido.bt.tick", {:strategy_tick}},
      {"jido.bt.blackboard.put", {:strategy_cmd, @put_action}},
      {"jido.bt.blackboard.merge", {:strategy_cmd, @merge_action}},
      {"jido.bt.halt", {:strategy_cmd, @halt_action}},
      {"jido.bt.reset", {:strategy_cmd, @reset_action}}
    ]
  end

  @impl true
  def init(%Agent{} = agent, ctx) do
    Observe.with_span([:jido, :agent, :strategy, :init], strategy_metadata(agent), fn ->
      opts = ctx[:strategy_opts] || []

      tree = resolve_tree(opts, agent)
      blackboard = Blackboard.new(Keyword.get(opts, :blackboard, %{}))
      bt_state = State.new(tree, blackboard)

      agent =
        StratState.put(agent, %{
          bt: bt_state,
          module: __MODULE__,
          reset_on_completion: Keyword.get(opts, :reset_on_completion, false)
        })

      {agent, []}
    end)
  end

  @impl true
  def cmd(%Agent{} = agent, instructions, ctx) when is_list(instructions) do
    Observe.with_span([:jido, :agent, :strategy, :cmd], strategy_metadata(agent), fn ->
      strat_state = StratState.get(agent, %{})
      %State{} = bt = Map.fetch!(strat_state, :bt)
      reset_on_completion? = Map.get(strat_state, :reset_on_completion, false)

      {prepared_bt, pending_instructions, force_tick?} = prepare_commands(bt, instructions)
      should_tick? = force_tick? or pending_instructions != [] or instructions == []

      {updated_agent, updated_bt, directives} =
        if should_tick? do
          run_tree_tick(agent, prepared_bt, pending_instructions, ctx, reset_on_completion?)
        else
          {agent, prepared_bt, []}
        end

      updated_agent = StratState.put(updated_agent, %{strat_state | bt: updated_bt})
      {updated_agent, directives}
    end)
  rescue
    e ->
      error = Error.execution_error("BehaviorTree tick failed", %{reason: Exception.message(e)})
      {agent, [AgentDirective.error(error, :bt_tick)]}
  end

  @impl true
  def tick(%Agent{} = agent, ctx) do
    cmd(agent, [], ctx)
  end

  @impl true
  def snapshot(agent, _ctx) do
    strat_state = StratState.get(agent, %{})
    bt = Map.get(strat_state, :bt)

    case bt do
      %State{} = state ->
        status = normalize_snapshot_status(state.status)

        %Jido.Agent.Strategy.Snapshot{
          status: status,
          done?: status in [:success, :failure],
          result: state.last_result,
          details: %{
            tick_count: state.tick_count || 0,
            error: state.error,
            tree_depth: safe_tree_depth(state.tree)
          }
        }

      _ ->
        %Jido.Agent.Strategy.Snapshot{
          status: :idle,
          done?: false,
          result: nil,
          details: %{tick_count: 0, error: nil, tree_depth: 0}
        }
    end
  end

  defp prepare_commands(bt, instructions) do
    Enum.reduce(instructions, {bt, [], false}, fn instruction, {acc_bt, pending, force_tick?} ->
      case instruction do
        %Instruction{action: @tick_action, params: params} ->
          appended = pending ++ List.wrap(Map.get(params, :instructions, []))
          {acc_bt, appended, true}

        %Instruction{action: @put_action, params: %{key: key, value: value}} ->
          updated_bb = Blackboard.put(acc_bt.blackboard, key, value)
          {%{acc_bt | blackboard: updated_bb}, pending, force_tick?}

        %Instruction{action: @merge_action, params: %{data: data}} when is_map(data) ->
          updated_bb = Blackboard.merge(acc_bt.blackboard, data)
          {%{acc_bt | blackboard: updated_bb}, pending, force_tick?}

        %Instruction{action: @halt_action} ->
          halted_tree = Tree.halt(acc_bt.tree)
          {%{acc_bt | tree: halted_tree, status: :idle, error: nil}, pending, force_tick?}

        %Instruction{action: @reset_action} ->
          reset_tree = Tree.halt(acc_bt.tree)

          {%{
             acc_bt
             | tree: reset_tree,
               blackboard: acc_bt.initial_blackboard,
               status: :idle,
               last_result: nil,
               error: nil
           }, pending, force_tick?}

        %Instruction{} = unhandled ->
          {acc_bt, pending ++ [unhandled], true}

        _ ->
          {acc_bt, pending, force_tick?}
      end
    end)
  end

  defp run_tree_tick(agent, %State{} = bt, instructions, ctx, reset_on_completion?) do
    blackboard =
      bt.blackboard
      |> Blackboard.put(:instructions, instructions)
      |> Blackboard.put(:agent_state, agent.state)

    tick_context =
      Map.merge(ctx, %{
        agent_id: agent.id,
        agent_module: agent.agent_module || agent.__struct__,
        strategy: __MODULE__
      })

    tick = Tick.new_with_context(blackboard, agent, [], tick_context)
    tick = %{tick | sequence: bt.tick_count}
    {status, tree, tick} = Tree.tick_with_context(bt.tree, tick)

    updated_agent = tick.agent || agent
    directives = tick.directives
    last_result = Blackboard.get(tick.blackboard, :last_result)
    tick_error = Blackboard.get(tick.blackboard, :error)
    {snapshot_status, error} = normalize_status(status, tick_error)

    tree =
      if reset_on_completion? and snapshot_status in [:success, :failure] do
        Tree.halt(tree)
      else
        tree
      end

    updated_bt = %State{
      bt
      | tree: tree,
        blackboard: tick.blackboard,
        status: snapshot_status,
        tick_count: bt.tick_count + 1,
        last_result: last_result,
        error: error
    }

    {updated_agent, updated_bt, directives}
  end

  defp resolve_tree(opts, agent) do
    case Keyword.get(opts, :tree) do
      %Tree{} = t ->
        t

      nil ->
        case Keyword.get(opts, :tree_builder) do
          {mod, fun, extra_args} ->
            apply(mod, fun, [agent | List.wrap(extra_args)])

          nil ->
            raise ArgumentError, "BehaviorTree strategy requires :tree or :tree_builder option"
        end

      other ->
        raise ArgumentError,
              "BehaviorTree strategy :tree must be a Tree struct, got: #{inspect(other)}"
    end
  end

  defp safe_tree_depth(nil), do: 0

  defp safe_tree_depth(%Tree{} = tree) do
    Tree.depth(tree)
  rescue
    _ -> 0
  end

  defp safe_tree_depth(_), do: 0

  defp strategy_metadata(%Agent{} = agent) do
    %{
      agent_id: agent.id,
      strategy: __MODULE__
    }
  end

  defp normalize_status(:success, error), do: {:success, error}
  defp normalize_status(:running, error), do: {:running, error}
  defp normalize_status(:failure, error), do: {:failure, error}
  defp normalize_status({:error, reason}, nil), do: {:failure, reason}
  defp normalize_status({:error, _reason}, error), do: {:failure, error}

  defp normalize_snapshot_status(status) when status in [:idle, :running, :waiting, :success, :failure], do: status
  defp normalize_snapshot_status(_status), do: :failure
end
