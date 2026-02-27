defmodule Jido.Agent.Strategy.BehaviorTreeSignalTest do
  use ExUnit.Case, async: false

  alias Jido.BehaviorTree.Blackboard
  alias Jido.BehaviorTree.Test.Nodes.SimpleNode
  alias Jido.BehaviorTree.Tree

  defmodule SignalStrategyAgent do
    use Jido.Agent,
      name: "bt_signal_strategy_agent",
      schema: [],
      strategy: {Jido.Agent.Strategy.BehaviorTree, tree: Tree.new(SimpleNode.new("signal")), blackboard: %{seed: 1}}
  end

  test "AgentServer routes behavior-tree control signals through strategy routes" do
    id = "bt-signal-#{System.unique_integer([:positive])}"
    registry = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    {:ok, _registry_pid} = Registry.start_link(keys: :unique, name: registry)

    {:ok, pid} =
      Jido.AgentServer.start_link(
        agent: SignalStrategyAgent,
        id: id,
        registry: registry,
        register_global: false
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    put_signal = Jido.Signal.new!("jido.bt.blackboard.put", %{key: :foo, value: "bar"}, source: "/test")
    assert {:ok, _agent} = Jido.AgentServer.call(pid, put_signal)

    {:ok, state_after_put} = Jido.AgentServer.state(pid)
    bb_after_put = state_after_put.agent.state.__strategy__.bt.blackboard
    assert "bar" == Blackboard.get(bb_after_put, :foo)

    tick_signal = Jido.Signal.new!("jido.bt.tick", %{}, source: "/test")
    assert {:ok, _agent} = Jido.AgentServer.call(pid, tick_signal)

    {:ok, status} = Jido.AgentServer.status(pid)
    assert status.snapshot.status == :success
    assert status.snapshot.done?
  end
end
