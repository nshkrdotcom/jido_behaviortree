defmodule Jido.Agent.Strategy.BehaviorTreeTest do
  use ExUnit.Case, async: true

  alias Jido.BehaviorTree.{Blackboard, Tree}
  alias Jido.BehaviorTree.Nodes.Action
  alias Jido.BehaviorTree.Test.Nodes.{ErrorNode, FailureNode, RunningNode, SimpleNode}

  defmodule SuccessStateAction do
    use Jido.Action,
      name: "success_state",
      description: "Sets status in agent state"

    @impl true
    def run(_params, _context) do
      {:ok, %{status: :processed}}
    end
  end

  def build_tree(_agent), do: Tree.new(SimpleNode.new("built"))

  defmodule FailureStateAction do
    use Jido.Action,
      name: "failure_state",
      description: "Always errors"

    @impl true
    def run(_params, _context) do
      {:error, :action_failure}
    end
  end

  defmodule EffectStateAction do
    use Jido.Action,
      name: "effect_state",
      description: "Returns result with state effects"

    @impl true
    def run(_params, _context) do
      {:ok, %{status: :result_state}, [Jido.Agent.StateOp.set_state(%{status: :effect_state})]}
    end
  end

  defmodule SuccessStrategyAgent do
    use Jido.Agent,
      name: "bt_success_strategy_agent",
      schema: [],
      strategy: {Jido.Agent.Strategy.BehaviorTree, tree: Tree.new(SimpleNode.new("ok"))}
  end

  defmodule RunningStrategyAgent do
    use Jido.Agent,
      name: "bt_running_strategy_agent",
      schema: [],
      strategy: {Jido.Agent.Strategy.BehaviorTree, tree: Tree.new(RunningNode.new(2))}
  end

  defmodule ErrorStrategyAgent do
    use Jido.Agent,
      name: "bt_error_strategy_agent",
      schema: [],
      strategy: {Jido.Agent.Strategy.BehaviorTree, tree: Tree.new(ErrorNode.new("boom"))}
  end

  defmodule ActionSuccessStrategyAgent do
    use Jido.Agent,
      name: "bt_action_success_strategy_agent",
      schema: [status: [type: :atom, default: :idle]],
      strategy: {Jido.Agent.Strategy.BehaviorTree, tree: Tree.new(Action.new(SuccessStateAction))}
  end

  defmodule ActionFailureStrategyAgent do
    use Jido.Agent,
      name: "bt_action_failure_strategy_agent",
      schema: [],
      strategy: {Jido.Agent.Strategy.BehaviorTree, tree: Tree.new(Action.new(FailureStateAction))}
  end

  defmodule ActionEffectStrategyAgent do
    use Jido.Agent,
      name: "bt_action_effect_strategy_agent",
      schema: [status: [type: :atom, default: :idle]],
      strategy: {Jido.Agent.Strategy.BehaviorTree, tree: Tree.new(Action.new(EffectStateAction))}
  end

  defmodule ControlStrategyAgent do
    use Jido.Agent,
      name: "bt_control_strategy_agent",
      schema: [],
      strategy: {Jido.Agent.Strategy.BehaviorTree, tree: Tree.new(SimpleNode.new("control")), blackboard: %{seed: 1}}
  end

  defmodule ResetOnCompletionAgent do
    use Jido.Agent,
      name: "bt_reset_on_completion_strategy_agent",
      schema: [],
      strategy: {Jido.Agent.Strategy.BehaviorTree, tree: Tree.new(SimpleNode.new("reset")), reset_on_completion: true}
  end

  defmodule FailureStatusStrategyAgent do
    use Jido.Agent,
      name: "bt_failure_status_strategy_agent",
      schema: [],
      strategy: {Jido.Agent.Strategy.BehaviorTree, tree: Tree.new(FailureNode.new("failure"))}
  end

  test "snapshot reports success for successful tree execution" do
    agent = SuccessStrategyAgent.new()
    {agent, _directives} = SuccessStrategyAgent.cmd(agent, [])
    snapshot = SuccessStrategyAgent.strategy_snapshot(agent)

    assert snapshot.status == :success
    assert snapshot.done?
    assert is_map(snapshot.details)
  end

  test "snapshot reports running while tree is still executing" do
    agent = RunningStrategyAgent.new()
    {agent, _directives} = RunningStrategyAgent.cmd(agent, [])
    snapshot = RunningStrategyAgent.strategy_snapshot(agent)

    assert snapshot.status == :running
    refute snapshot.done?
  end

  test "error status from node is normalized to failure with error details" do
    agent = ErrorStrategyAgent.new()
    {agent, directives} = ErrorStrategyAgent.cmd(agent, [])
    snapshot = ErrorStrategyAgent.strategy_snapshot(agent)

    assert directives == []
    assert snapshot.status == :failure
    assert snapshot.done?
    assert snapshot.details.error == "boom"
  end

  test "action node in strategy context updates agent state on success" do
    agent = ActionSuccessStrategyAgent.new()
    {agent, directives} = ActionSuccessStrategyAgent.cmd(agent, [])
    snapshot = ActionSuccessStrategyAgent.strategy_snapshot(agent)

    assert directives == []
    assert agent.state.status == :processed
    assert snapshot.status == :success
    assert snapshot.done?
  end

  test "action node errors become snapshot failure with error details" do
    agent = ActionFailureStrategyAgent.new()
    {agent, directives} = ActionFailureStrategyAgent.cmd(agent, [])
    snapshot = ActionFailureStrategyAgent.strategy_snapshot(agent)

    assert directives == []
    assert snapshot.status == :failure
    assert snapshot.done?
    assert match?(%Jido.Action.Error.ExecutionFailureError{}, snapshot.details.error)
  end

  test "action node applies state operation effects in strategy context" do
    agent = ActionEffectStrategyAgent.new()
    {agent, directives} = ActionEffectStrategyAgent.cmd(agent, [])
    snapshot = ActionEffectStrategyAgent.strategy_snapshot(agent)

    assert directives == []
    assert agent.state.status == :effect_state
    assert snapshot.status == :success
    assert snapshot.result == %{status: :result_state}
  end

  test "snapshot defaults to idle when strategy state is missing" do
    agent = %{SuccessStrategyAgent.new() | state: %{}}
    snapshot = Jido.Agent.Strategy.BehaviorTree.snapshot(agent, %{})

    assert snapshot.status == :idle
    refute snapshot.done?
  end

  test "action_spec/1 exposes schemas for built-in strategy commands" do
    assert is_map(Jido.Agent.Strategy.BehaviorTree.action_spec(:bt_blackboard_put))
    assert is_map(Jido.Agent.Strategy.BehaviorTree.action_spec(:bt_blackboard_merge))
    assert is_map(Jido.Agent.Strategy.BehaviorTree.action_spec(:bt_halt))
    assert is_map(Jido.Agent.Strategy.BehaviorTree.action_spec(:bt_reset))
    assert is_map(Jido.Agent.Strategy.BehaviorTree.action_spec(:bt_tick))
    assert is_nil(Jido.Agent.Strategy.BehaviorTree.action_spec(:unknown))
  end

  test "signal_routes/1 exposes strategy command and tick routes" do
    routes = Jido.Agent.Strategy.BehaviorTree.signal_routes(%{})

    assert {"jido.bt.tick", {:strategy_tick}} in routes
    assert {"jido.bt.blackboard.put", {:strategy_cmd, :bt_blackboard_put}} in routes
    assert {"jido.bt.blackboard.merge", {:strategy_cmd, :bt_blackboard_merge}} in routes
    assert {"jido.bt.halt", {:strategy_cmd, :bt_halt}} in routes
    assert {"jido.bt.reset", {:strategy_cmd, :bt_reset}} in routes
  end

  test "control commands mutate blackboard and reset strategy state" do
    agent = ControlStrategyAgent.new()

    {agent, []} = ControlStrategyAgent.cmd(agent, {:bt_blackboard_put, %{key: :foo, value: "bar"}})
    bb = agent.state.__strategy__.bt.blackboard

    assert :idle == ControlStrategyAgent.strategy_snapshot(agent).status
    assert "bar" == Blackboard.get(bb, :foo)

    {agent, []} = ControlStrategyAgent.cmd(agent, {:bt_blackboard_merge, %{data: %{count: 3}}})
    bb = agent.state.__strategy__.bt.blackboard
    assert 3 == Blackboard.get(bb, :count)

    {agent, _} = ControlStrategyAgent.cmd(agent, [])
    assert :success == ControlStrategyAgent.strategy_snapshot(agent).status

    {agent, []} = ControlStrategyAgent.cmd(agent, {:bt_reset, %{}})
    snapshot = ControlStrategyAgent.strategy_snapshot(agent)
    bb = agent.state.__strategy__.bt.blackboard

    assert :idle == snapshot.status
    assert 1 == Blackboard.get(bb, :seed)
    assert nil == Blackboard.get(bb, :foo)
  end

  test "strategy tick/2 executes one behavior tree tick" do
    agent = SuccessStrategyAgent.new()
    {agent, directives} = Jido.Agent.Strategy.BehaviorTree.tick(agent, %{})
    snapshot = SuccessStrategyAgent.strategy_snapshot(agent)

    assert directives == []
    assert snapshot.status == :success
    assert snapshot.done?
  end

  test "bt_tick command can inject additional instructions into blackboard before ticking" do
    agent = ControlStrategyAgent.new()
    payload = [%{kind: :synthetic}]

    {agent, []} = ControlStrategyAgent.cmd(agent, {:bt_tick, %{instructions: payload}})
    blackboard = agent.state.__strategy__.bt.blackboard

    assert payload == Blackboard.get(blackboard, :instructions)
    assert :success == ControlStrategyAgent.strategy_snapshot(agent).status
  end

  test "halt command sets strategy status to idle without running a tick" do
    agent = ControlStrategyAgent.new()
    {agent, _} = ControlStrategyAgent.cmd(agent, [])
    assert :success == ControlStrategyAgent.strategy_snapshot(agent).status

    {agent, []} = ControlStrategyAgent.cmd(agent, {:bt_halt, %{}})
    assert :idle == ControlStrategyAgent.strategy_snapshot(agent).status
  end

  test "reset_on_completion halts tree after terminal tick" do
    agent = ResetOnCompletionAgent.new()
    {agent, []} = ResetOnCompletionAgent.cmd(agent, [])
    assert :success == ResetOnCompletionAgent.strategy_snapshot(agent).status
  end

  test "failure status remains atom failure and preserves nil error payload" do
    agent = FailureStatusStrategyAgent.new()
    {agent, []} = FailureStatusStrategyAgent.cmd(agent, [])
    snapshot = FailureStatusStrategyAgent.strategy_snapshot(agent)

    assert snapshot.status == :failure
    assert snapshot.done?
    assert snapshot.details.error == nil
  end

  test "snapshot normalizes unknown internal status values to failure" do
    agent = SuccessStrategyAgent.new()

    weird_state = %Jido.Agent.Strategy.BehaviorTree.State{
      tree: nil,
      blackboard: Blackboard.new(),
      initial_blackboard: Blackboard.new(),
      status: :unknown_status,
      tick_count: 0,
      last_result: nil,
      error: nil
    }

    agent = put_in(agent.state, %{__strategy__: %{bt: weird_state}})
    snapshot = Jido.Agent.Strategy.BehaviorTree.snapshot(agent, %{})

    assert snapshot.status == :failure
    assert snapshot.details.tree_depth == 0
  end

  test "cmd/3 safely ignores non-instruction items when called directly" do
    agent = SuccessStrategyAgent.new()
    {agent, directives} = Jido.Agent.Strategy.BehaviorTree.cmd(agent, [:bad_input], %{})

    assert directives == []
    assert :idle == SuccessStrategyAgent.strategy_snapshot(agent).status
  end

  test "init/2 supports tree_builder strategy option" do
    agent = SuccessStrategyAgent.new()

    {initialized_agent, directives} =
      Jido.Agent.Strategy.BehaviorTree.init(agent, %{
        strategy_opts: [tree_builder: {__MODULE__, :build_tree, []}]
      })

    snapshot = Jido.Agent.Strategy.BehaviorTree.snapshot(initialized_agent, %{})

    assert directives == []
    assert snapshot.status == :idle
    assert snapshot.details.tree_depth == 1
  end

  test "init/2 raises when strategy tree option is invalid" do
    agent = SuccessStrategyAgent.new()

    assert_raise ArgumentError, fn ->
      Jido.Agent.Strategy.BehaviorTree.init(agent, %{strategy_opts: [tree: :invalid]})
    end
  end

  test "snapshot handles non-tree values in strategy state details safely" do
    agent = SuccessStrategyAgent.new()

    bad_state = %Jido.Agent.Strategy.BehaviorTree.State{
      tree: :not_a_tree,
      blackboard: %{},
      initial_blackboard: %{},
      status: :idle,
      tick_count: 0,
      last_result: nil,
      error: nil
    }

    agent = put_in(agent.state, %{__strategy__: %{bt: bad_state}})
    snapshot = Jido.Agent.Strategy.BehaviorTree.snapshot(agent, %{})

    assert snapshot.status == :idle
    assert snapshot.details.tree_depth == 0
  end
end
