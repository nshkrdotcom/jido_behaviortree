defmodule Jido.BehaviorTree.Nodes.ActionTest do
  use ExUnit.Case, async: true

  alias Jido.BehaviorTree.Nodes.Action
  alias Jido.BehaviorTree.{Tick, Blackboard}

  # Define a simple test action
  defmodule SuccessAction do
    use Jido.Action,
      name: "success_action",
      description: "An action that always succeeds",
      schema: [
        input: [type: :string, required: false]
      ]

    @impl true
    def run(params, _context) do
      {:ok, %{result: "success", input: params[:input]}}
    end
  end

  defmodule FailureAction do
    use Jido.Action,
      name: "failure_action",
      description: "An action that always fails",
      schema: []

    @impl true
    def run(_params, _context) do
      {:error, "action failed"}
    end
  end

  defmodule NonMapSuccessAction do
    use Jido.Action,
      name: "non_map_success_action",
      description: "Returns a non-map success payload",
      schema: []

    @impl true
    def run(_params, _context) do
      {:ok, "done"}
    end
  end

  defmodule NonMapEffectAction do
    use Jido.Action,
      name: "non_map_effect_action",
      description: "Returns a non-map payload with state effects",
      schema: []

    @impl true
    def run(_params, _context) do
      {:ok, "done", [Jido.Agent.StateOp.set_state(%{status: :effect_applied})]}
    end
  end

  defmodule ContextAgent do
    use Jido.Agent,
      name: "bt_action_context_agent",
      schema: [status: [type: :atom, default: :idle]]
  end

  describe "new/3" do
    test "creates an action node with module" do
      action = Action.new(SuccessAction)

      assert %Action{action_module: SuccessAction, params: %{}, context: %{}} = action
    end

    test "creates an action node with params" do
      action = Action.new(SuccessAction, %{input: "test"})

      assert action.params == %{input: "test"}
    end

    test "creates an action node with context" do
      action = Action.new(SuccessAction, %{}, %{user_id: 123})

      assert action.context == %{user_id: 123}
    end
  end

  describe "tick/2" do
    test "returns success when action succeeds" do
      action = Action.new(SuccessAction, %{input: "hello"})
      tick = Tick.new(Blackboard.new())

      {status, updated} = Action.tick(action, tick)

      assert status == :success
      assert updated.result == %{result: "success", input: "hello"}
    end

    test "returns error when action fails" do
      action = Action.new(FailureAction)
      tick = Tick.new(Blackboard.new())

      {status, _updated} = Action.tick(action, tick)

      assert {:error, _reason} = status
    end

    test "resolves blackboard values in params" do
      action = Action.new(SuccessAction, %{input: {:from_blackboard, :user_input}})
      blackboard = Blackboard.new(%{user_input: "from blackboard"})
      tick = Tick.new(blackboard)

      {status, updated} = Action.tick(action, tick)

      assert status == :success
      assert updated.result.input == "from blackboard"
    end
  end

  describe "tick_with_context/2" do
    test "returns success and updates tick when action succeeds" do
      action = Action.new(SuccessAction, %{input: "hello"})
      tick = Tick.new_with_context(Blackboard.new(), nil, [], %{})

      {status, updated_node, updated_tick} = Action.tick_with_context(action, tick)

      assert status == :success
      assert updated_node.result == %{result: "success", input: "hello"}
      assert Tick.get(updated_tick, :last_result) == %{result: "success", input: "hello"}
    end

    test "returns error status and stores reason in tick when action fails" do
      action = Action.new(FailureAction)
      tick = Tick.new_with_context(Blackboard.new(), nil, [], %{})

      {status, _updated_node, updated_tick} = Action.tick_with_context(action, tick)

      assert {:error, reason} = status
      assert Tick.get(updated_tick, :error) == reason
    end

    test "uses same status class as tick/2 for failing actions" do
      action = Action.new(FailureAction)
      tick = Tick.new(Blackboard.new())

      {tick_status, _} = Action.tick(action, tick)
      {context_status, _, _} = Action.tick_with_context(action, Tick.new_with_context(Blackboard.new(), nil, [], %{}))

      assert match?({:error, _}, tick_status)
      assert match?({:error, _}, context_status)
    end

    test "treats non-map action outputs as errors in agent context mode" do
      action = Action.new(NonMapSuccessAction)
      agent = ContextAgent.new()
      tick = Tick.new_with_context(Blackboard.new(), agent, [], %{})

      {status, updated_node, updated_tick} = Action.tick_with_context(action, tick)

      assert {:error, reason} = status
      assert updated_node.result == nil
      assert Tick.get(updated_tick, :error) == reason
      assert %Jido.Agent{} = updated_tick.agent
    end

    test "keeps error class parity for non-map outputs in both tick modes" do
      action = Action.new(NonMapEffectAction)
      agent = ContextAgent.new()
      bb = Blackboard.new()

      {tick_status, _} = Action.tick(action, Tick.new(bb))

      {context_status, _updated_node, updated_tick} =
        Action.tick_with_context(action, Tick.new_with_context(bb, agent, [], %{}))

      assert match?({:error, _}, tick_status)
      assert match?({:error, _}, context_status)
      assert Tick.get(updated_tick, :error) != nil
    end
  end

  describe "halt/1" do
    test "clears the result" do
      action = %Action{
        action_module: SuccessAction,
        params: %{},
        context: %{},
        result: %{some: "result"}
      }

      halted = Action.halt(action)
      assert halted.result == nil
    end
  end

  describe "schema/0" do
    test "returns the Zoi schema" do
      schema = Action.schema()
      assert is_struct(schema, Zoi.Types.Struct)
    end
  end
end
