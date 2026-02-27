# Migration Guide

This guide covers behavior and compatibility changes introduced while hardening
`jido_behaviortree` for production use.

## Runtime and Dependency Baseline

- Minimum Elixir version is now `1.18`.
- Core runtime dependencies now target stable Jido `2.0.x` releases.

## Behavior Changes

### `Skill.run/3` failure semantics

`Skill.run/3` now treats tree `:failure` as an execution failure.

- Previous behavior: `:failure` returned `{:ok, blackboard}`.
- New behavior: `:failure` returns `{:error, reason}`.

Timeouts and execution errors are also consistently returned as `{:error, reason}`.

### Auto mode execution

Auto mode no longer sleeps for the full timeout window unconditionally.
It now polls for terminal status and exits early on `:success` or `:failure`.

### Blackboard propagation from `SetBlackboard`

`SetBlackboard` updates are now threaded through context-aware ticking and persist
in `Agent` blackboard state.

### Action error semantics in context mode

`Action.tick_with_context/2` now returns error statuses consistent with `tick/2`.
It no longer silently downgrades action errors to `:failure`.

### Strategy snapshot status normalization

`Jido.Agent.Strategy.BehaviorTree` now normalizes non-atom tree error statuses
to snapshot-compatible `:failure`, while preserving detailed error data in
`snapshot.details.error`.

## Telemetry Namespace

Telemetry events are under the `[:jido, :bt, ...]` namespace, including agent tick events.

## Recommended Upgrade Checklist

1. Update any call sites that assumed `Skill.run/3` returns `{:ok, ...}` on tree failure.
2. Verify monitors/alerts consuming telemetry event names use `[:jido, :bt, ...]`.
3. Re-run integration tests around action failure handling and blackboard persistence.
